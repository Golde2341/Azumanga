import SwiftUI

/// Offline downloads: the queue, what is available offline, and storage use.
struct DownloadsView: View {
    @Environment(DownloadsModel.self) private var model

    var body: some View {
        Group {
            if model.records.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Download chapters from a manga's page to read them offline.")
                )
            } else {
                List {
                    if !model.activeRecords.isEmpty {
                        Section("In Progress") {
                            ForEach(model.activeRecords) { record in
                                DownloadRow(record: record, progress: model.progress(for: record))
                                    .contextMenu {
                                        Button("Pause") { model.pause(record) }
                                        Button("Cancel", role: .destructive) { model.cancel(record) }
                                    }
                            }
                        }
                    }

                    if !model.failedOrPausedRecords.isEmpty {
                        Section("Paused or Failed") {
                            ForEach(model.failedOrPausedRecords) { record in
                                DownloadRow(record: record, progress: model.progress(for: record))
                                    .contextMenu {
                                        Button("Resume") { model.resume(record) }
                                        Button("Delete", role: .destructive) { model.delete(record) }
                                    }
                            }
                        }
                    }

                    if !model.completedRecords.isEmpty {
                        Section("Available Offline") {
                            ForEach(model.completedRecords) { record in
                                NavigationLink(value: session(for: record)) {
                                    DownloadRow(record: record, progress: model.progress(for: record))
                                }
                                .contextMenu {
                                    Button("Delete Download", role: .destructive) { model.delete(record) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .navigationDestination(for: ReaderSession.self) { session in
                    ReaderContainerView(session: session)
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    model.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(role: .destructive) {
                    model.deleteAll()
                } label: {
                    Label("Delete All", systemImage: "trash")
                }
                .disabled(model.records.isEmpty)
            }
        }
        .alert("Download Problem", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { model.reload() }
    }

    private func session(for record: DownloadRecord) -> ReaderSession {
        // Opening with no chapter list keeps this fully offline: the reader
        // serves the downloaded pages without contacting the source.
        ReaderSession(
            manga: Manga(
                sourceId: record.sourceId,
                mangaId: record.mangaId,
                title: record.mangaTitle
            ),
            chapters: [],
            chapterId: record.chapterId
        )
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord
    let progress: DownloadProgress?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.chapterTitle ?? "Chapter \(record.chapterNumber.map(Chapter.format) ?? "?")")
                    .lineLimit(1)
                Text("\(record.mangaTitle) · \(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let progress, record.state == .downloading || record.state == .queued {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: progress.fraction)
                        .frame(width: 120)
                    Text("\(progress.completedPages)/\(progress.totalPages)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(record.state.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let message = record.errorMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch record.state {
        case .completed: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle"
        case .queued: "clock"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch record.state {
        case .completed: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

extension DownloadState {
    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .completed: "Available offline"
        case .failed: "Failed"
        }
    }
}
