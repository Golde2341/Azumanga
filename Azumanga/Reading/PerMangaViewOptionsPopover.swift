import SwiftUI

/// The reader's display popover. Everything under "View" applies to this manga
/// only; the main Settings window holds the defaults for manga without an override.
struct PerMangaViewOptionsPopover: View {
    @Bindable var options: ReaderViewOptions
    let mangaTitle: String
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onResetZoom: () -> Void
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                presets
                Divider()
                viewOptions
                Divider()
                backgroundOptions
                Divider()
                warmthOptions
                Divider()
                sessionActions
                Divider()
                chapterActions
                resetButton
            }
            .padding(16)
        }
        .frame(width: 340)
        .frame(maxHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Per Manga View Options")
                    .font(.headline)
                Spacer(minLength: 0)
                Text(options.usesCustomOptions ? "Custom" : "Using defaults")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(options.usesCustomOptions ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        (options.usesCustomOptions ? Color.accentColor : Color.secondary)
                            .opacity(0.12),
                        in: Capsule()
                    )
            }

            Text(mangaTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("Changes here apply only to this manga.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var presets: some View {
        HStack(spacing: 8) {
            ForEach(ReaderPreset.allCases) { preset in
                presetCard(preset)
            }
        }
    }

    private func presetCard(_ preset: ReaderPreset) -> some View {
        let isCurrent = options.layout == preset.layout && options.pageMode == preset.pageMode

        return Button {
            options.apply(preset)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: preset.layout == .vertical ? "rectangle.portrait" : "book")
                        .font(.caption)
                    Text(preset.displayName)
                        .font(.subheadline.weight(.semibold))
                }
                Text(preset.layout == .vertical ? "Vertical · Single page" : "Horizontal · Facing pairs")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                isCurrent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isCurrent ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isCurrent ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var viewOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("View")
                .font(.subheadline.weight(.semibold))

            LabeledContent("Layout") {
                Picker("Layout", selection: $options.layout) {
                    ForEach(ReaderLayoutKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            LabeledContent("Direction") {
                Picker("Direction", selection: $options.direction) {
                    ForEach(ReadingDirection.allCases) { direction in
                        Text(direction.displayName).tag(direction)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            LabeledContent("Pages") {
                Picker("Pages", selection: $options.pageMode) {
                    ForEach(PageMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            LabeledContent("Fit") {
                Picker("Fit", selection: $options.fitMode) {
                    ForEach(PageFitMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var backgroundOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Background")
                .font(.subheadline.weight(.semibold))

            BackgroundSwatches(selection: $options.background)
        }
    }

    private var warmthOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Warmth")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 0)

                Text(options.warmth > 0.001 ? "\(Int((options.warmth * 100).rounded()))%" : "Off")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $options.warmth, in: 0...1) {
                Text("Warmth")
            }
            .labelsHidden()
            .accessibilityValue(
                options.warmth > 0.001
                    ? "\(Int((options.warmth * 100).rounded())) percent"
                    : "Off"
            )
        }
    }

    private var sessionActions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Session")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                Button("Zoom In", action: onZoomIn)
                Button("Zoom Out", action: onZoomOut)
                Button("Reset Zoom", action: onResetZoom)
            }
            .controlSize(.small)
            .disabled(options.layout != .vertical)

            if options.layout != .vertical {
                Text("Zoom is available in Webtoon mode.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chapterActions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Chapter")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                Button("Mark Read", action: onMarkRead)
                Button("Mark Unread", action: onMarkUnread)
            }
            .controlSize(.small)
        }
    }

    private var resetButton: some View {
        Button("Reset to Default View", role: .destructive) {
            options.resetToDefaults()
        }
        .controlSize(.small)
        .disabled(!options.usesCustomOptions)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
