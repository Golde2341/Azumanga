import AppKit
import SwiftUI

/// Hosts the reader: builds its model from the session and environment.
struct ReaderContainerView: View {
    let session: ReaderSession

    @Environment(Services.self) private var services
    @Environment(SettingsStore.self) private var settings

    @State private var model: ReaderModel?

    var body: some View {
        Group {
            if let model {
                ReaderView(model: model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard model == nil else { return }
            let model = ReaderModel(
                manga: session.manga,
                chapters: session.chapters,
                startChapterId: session.chapterId,
                startPageIndex: session.startPageIndex,
                services: services,
                settings: settings
            )
            self.model = model
            await model.load()
        }
    }
}

/// The reading surface: vertical continuous or horizontal paged, with zoom,
/// keyboard shortcuts, chapter navigation and automatic progress saving.
struct ReaderView: View {
    @Bindable var model: ReaderModel

    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var showChapterPicker = false

    var body: some View {
        ZStack {
            settings.backgroundColor
                .ignoresSafeArea()

            content

            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
            }

            pageIndicator
        }
        .navigationTitle(model.chapterLabel)
        .toolbar { toolbar }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { model.previousPage(); return .handled }
        .onKeyPress(.rightArrow) { model.nextPage(); return .handled }
        .onKeyPress(.upArrow) { model.previousPage(); return .handled }
        .onKeyPress(.downArrow) { model.nextPage(); return .handled }
        .onKeyPress(.space) { model.nextPage(); return .handled }
        .onKeyPress(.pageUp) { model.previousPage(); return .handled }
        .onKeyPress(.pageDown) { model.nextPage(); return .handled }
        .onKeyPress("+") { model.zoomIn(); return .handled }
        .onKeyPress("=") { model.zoomIn(); return .handled }
        .onKeyPress("-") { model.zoomOut(); return .handled }
        .onKeyPress("0") { model.resetZoom(); return .handled }
        .onKeyPress("[") { Task { await model.goToChapter(index: model.currentChapterIndex - 1) }; return .handled }
        .onKeyPress("]") { Task { await model.goToChapter(index: model.currentChapterIndex + 1) }; return .handled }
        .onKeyPress("b") { model.toggleBookmark(); return .handled }
        .onKeyPress("f") { toggleFullScreen(); return .handled }
        .onKeyPress("m") { model.markCurrentChapterRead(); return .handled }
        .sheet(isPresented: $showChapterPicker) {
            ChapterPickerSheet(model: model, isPresented: $showChapterPicker)
        }
        .onDisappear {
            model.flushProgress()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let errorMessage = model.errorMessage {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(errorMessage)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack {
                    if let externalURL = model.chapter.externalURL {
                        Link("Open on Source Site", destination: externalURL)
                            .buttonStyle(.borderedProminent)
                    }
                    if model.hasPreviousChapter {
                        Button("Previous Chapter") {
                            Task { await model.goToChapter(index: model.currentChapterIndex - 1) }
                        }
                    }
                    if model.hasNextChapter {
                        Button("Next Chapter") {
                            Task { await model.goToChapter(index: model.currentChapterIndex + 1) }
                        }
                    }
                    Button("Retry") {
                        Task { await model.load() }
                    }
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch settings.layout {
            case .vertical:
                verticalReader
            case .horizontal:
                horizontalReader
            }
        }
    }

    private var verticalReader: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 0) {
                    ForEach(model.pages) { page in
                        AsyncPageImage(page: page, maxPixelSize: model.renderMaxPixelSize, contentMode: .fit)
                            .frame(width: geometry.size.width * model.zoom)
                            .id(page.index)
                    }
                }
                .frame(minWidth: geometry.size.width)
                .scrollTargetLayout()
            }
            .scrollPosition(id: positionBinding)
            .scrollIndicators(.never)
            .gesture(zoomGesture)
            .onTapGesture(count: 2) {
                model.zoom > 1 ? model.resetZoom() : model.setZoom(2)
            }
        }
    }

    private var horizontalReader: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(spreads, id: \.first?.index) { spread in
                        spreadView(spread, size: geometry.size)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .id(spread.first?.index ?? 0)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: positionBinding)
            .scrollIndicators(.never)
            .environment(\.layoutDirection, settings.direction == .rightToLeft ? .rightToLeft : .leftToRight)
            .onTapGesture(count: 2) {
                model.zoom > 1 ? model.resetZoom() : model.setZoom(2)
            }
        }
    }

    @ViewBuilder
    private func spreadView(_ pages: [Page], size: CGSize) -> some View {
        if pages.count == 1 {
            ZoomablePage(page: pages[0], zoom: $model.zoom, maxPixelSize: model.renderMaxPixelSize)
        } else {
            GeometryReader { inner in
                HStack(spacing: 0) {
                    ForEach(pages) { page in
                        AsyncPageImage(page: page, maxPixelSize: model.renderMaxPixelSize, contentMode: .fit)
                            .frame(width: inner.size.width / CGFloat(pages.count))
                    }
                }
            }
            .scaleEffect(model.zoom)
            .frame(width: size.width, height: size.height)
        }
    }

    /// Pages grouped into single or double spreads.
    private var spreads: [[Page]] {
        guard settings.pageMode == .double, model.pages.count > 1 else {
            return model.pages.map { [$0] }
        }
        var result: [[Page]] = []
        var index = 0
        if settings.doublePageFirstPageAlone {
            result.append([model.pages[0]])
            index = 1
        }
        while index < model.pages.count {
            let end = min(index + 2, model.pages.count)
            result.append(Array(model.pages[index..<end]))
            index = end
        }
        return result
    }

    private var positionBinding: Binding<Int?> {
        Binding(
            get: { model.currentIndex },
            set: { newValue in
                if let newValue { model.goToPage(newValue) }
            }
        )
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                model.setZoom(value.magnification)
            }
    }

    private var pageIndicator: some View {
        VStack {
            Spacer()
            if !model.pages.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        Task { await model.goToChapter(index: model.currentChapterIndex - 1) }
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(!model.hasPreviousChapter)
                    .buttonStyle(.plain)

                    Text("\(model.currentIndex + 1) / \(model.pages.count)")
                        .font(.caption.monospacedDigit())

                    Button {
                        Task { await model.goToChapter(index: model.currentChapterIndex + 1) }
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .disabled(!model.hasNextChapter)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 16)
            }
        }
        .allowsHitTesting(!model.pages.isEmpty)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.flushProgress()
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .keyboardShortcut(.escape, modifiers: [])
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(model.chapterLabel)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.manga.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 160)
        }

        ToolbarItemGroup(placement: .automatic) {
            Button {
                Task { await model.goToChapter(index: model.currentChapterIndex - 1) }
            } label: {
                Label("Previous Chapter", systemImage: "chevron.left")
            }
            .disabled(!model.hasPreviousChapter)

            Button {
                showChapterPicker = true
            } label: {
                Label("Chapters", systemImage: "list.bullet")
            }

            Button {
                Task { await model.goToChapter(index: model.currentChapterIndex + 1) }
            } label: {
                Label("Next Chapter", systemImage: "chevron.right")
            }
            .disabled(!model.hasNextChapter)

            Button {
                model.toggleBookmark()
            } label: {
                Label(
                    model.isCurrentPageBookmarked ? "Remove Bookmark" : "Bookmark Page",
                    systemImage: model.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark"
                )
            }
            .disabled(model.pages.isEmpty)

            Menu {
                Picker("Layout", selection: Binding(get: { settings.layout }, set: { settings.layout = $0 })) {
                    ForEach(ReaderLayoutKind.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Direction", selection: Binding(get: { settings.direction }, set: { settings.direction = $0 })) {
                    ForEach(ReadingDirection.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Pages", selection: Binding(get: { settings.pageMode }, set: { settings.pageMode = $0 })) {
                    ForEach(PageMode.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Fit", selection: Binding(get: { settings.fitMode }, set: { settings.fitMode = $0 })) {
                    ForEach(PageFitMode.allCases) { Text($0.displayName).tag($0) }
                }
                Divider()
                Button("Zoom In") { model.zoomIn() }
                Button("Zoom Out") { model.zoomOut() }
                Button("Actual Fit") { model.resetZoom() }
                Divider()
                Toggle("Mark Chapter as Read", isOn: Binding(
                    get: { false },
                    set: { if $0 { model.markCurrentChapterRead() } }
                ))
                Button("Mark Chapter as Unread") { model.markCurrentChapterUnread() }
            } label: {
                Label("Display", systemImage: "slider.horizontal.3")
            }

            Button {
                toggleFullScreen()
            } label: {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
    }

    private func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }
}

/// A single page that supports pinch/double-click zoom and panning while zoomed.
struct ZoomablePage: View {
    let page: Page
    @Binding var zoom: CGFloat
    let maxPixelSize: Int

    @State private var committedOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var zoomBase: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            AsyncPageImage(page: page, maxPixelSize: maxPixelSize, contentMode: .fit)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(zoom)
                .offset(
                    x: committedOffset.width + dragOffset.width,
                    y: committedOffset.height + dragOffset.height
                )
                .contentShape(Rectangle())
                .gesture(magnifyGesture)
                .gesture(panGesture, including: zoom > 1 ? .all : .subviews)
                .onChange(of: zoom) { _, newValue in
                    if newValue <= 1 {
                        committedOffset = .zero
                        dragOffset = .zero
                    }
                }
                .clipped()
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(max(1, zoomBase * value.magnification), 5)
            }
            .onEnded { _ in
                zoomBase = zoom
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in dragOffset = value.translation }
            .onEnded { value in
                committedOffset.width += value.translation.width
                committedOffset.height += value.translation.height
                dragOffset = .zero
            }
    }
}

/// Chapter list for jumping within the current manga.
private struct ChapterPickerSheet: View {
    let model: ReaderModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chapters")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            List {
                ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        Task {
                            await model.goToChapter(id: chapter.chapterId)
                            isPresented = false
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.displayName)
                                    .foregroundStyle(index == model.currentChapterIndex ? Color.accentColor : .primary)
                                Text(chapter.subtitleLine)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if index == model.currentChapterIndex {
                                Image(systemName: "book.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 420, height: 500)
    }
}
