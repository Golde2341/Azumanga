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
            VStack(alignment: .leading, spacing: 18) {
                header
                presets
                viewSection
                backgroundSection
                warmthSection
                sessionSection
                chapterSection
                Divider()
                resetButton
            }
            .padding(16)
        }
        .frame(width: 340)
        .frame(maxHeight: 620)
    }

    private struct OptionSectionHeader: View {
        let title: String
        let systemImage: String
        var tint: Color = .secondary

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
    }

    private struct ViewOptionRow<Control: View>: View {
        let title: String
        let systemImage: String
        private let control: Control

        init(title: String, systemImage: String, @ViewBuilder control: () -> Control) {
            self.title = title
            self.systemImage = systemImage
            self.control = control()
        }

        var body: some View {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, alignment: .center)
                Text(title)
                    .font(.callout)
                Spacer(minLength: 6)
                control
            }
            .frame(minHeight: 22)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    }
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text("View Options")
                        .font(.headline)
                    Text(mangaTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(mangaTitle)
                }
                Spacer(minLength: 0)
                Text(options.usesCustomOptions ? "Custom" : "Using defaults")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(options.usesCustomOptions ? Color.white : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background {
                        Capsule()
                            .fill(
                                options.usesCustomOptions
                                    ? Color.accentColor
                                    : Color.secondary.opacity(0.16)
                            )
                    }
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                options.usesCustomOptions
                                    ? Color.white.opacity(0.25)
                                    : Color.secondary.opacity(0.3),
                                lineWidth: 1
                            )
                    }
            }

            Text("Changes here apply only to this manga.")
                .font(.caption)
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
                        .font(.system(size: 12, weight: .medium))
                    Text(preset.displayName)
                        .font(.subheadline.weight(.semibold))
                }
                Text(preset.layout == .vertical ? "Vertical · Single page" : "Horizontal · Facing pairs")
                    .font(.caption)
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

    private var viewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            OptionSectionHeader(title: "View", systemImage: "eye")

            ViewOptionRow(title: "Layout", systemImage: "rectangle.split.2x1") {
                Picker("Layout", selection: $options.layout) {
                    ForEach(ReaderLayoutKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            ViewOptionRow(title: "Direction", systemImage: "arrow.left.arrow.right") {
                Picker("Direction", selection: $options.direction) {
                    ForEach(ReadingDirection.allCases) { direction in
                        Text(direction.displayName).tag(direction)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            ViewOptionRow(title: "Pages", systemImage: "rectangle.on.rectangle") {
                Picker("Pages", selection: $options.pageMode) {
                    ForEach(PageMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            ViewOptionRow(title: "Fit", systemImage: "aspectratio") {
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

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            OptionSectionHeader(title: "Background", systemImage: "paintpalette")
            BackgroundSwatches(selection: $options.background)
        }
    }

    private var warmthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OptionSectionHeader(title: "Warmth", systemImage: "sun.max", tint: .orange)
                Spacer()
                Text(options.warmth > 0.001 ? "\(Int((options.warmth * 100).rounded()))%" : "Off")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $options.warmth, in: 0...1) {
                Text("Warmth")
            }
            .labelsHidden()
            .tint(.orange)
            .accessibilityValue(
                options.warmth > 0.001
                    ? "\(Int((options.warmth * 100).rounded())) percent"
                    : "Off"
            )
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            OptionSectionHeader(title: "Session", systemImage: "magnifyingglass")

            HStack(spacing: 8) {
                actionButton("Zoom In", systemImage: "plus.magnifyingglass", action: onZoomIn)
                actionButton("Zoom Out", systemImage: "minus.magnifyingglass", action: onZoomOut)
                actionButton("Reset", systemImage: "arrow.counterclockwise", action: onResetZoom)
            }
            .disabled(options.layout != .vertical)

            if options.layout != .vertical {
                Text("Zoom is available in Webtoon mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            OptionSectionHeader(title: "Chapter", systemImage: "bookmark")

            HStack(spacing: 8) {
                actionButton("Mark Read", systemImage: "checkmark.circle", action: onMarkRead)
                actionButton("Mark Unread", systemImage: "circle", action: onMarkUnread)
            }
        }
    }

    private var resetButton: some View {
        Button(role: .destructive) {
            options.resetToDefaults()
        } label: {
            Label("Reset to Default View", systemImage: "arrow.counterclockwise")
                .font(.callout)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!options.usesCustomOptions)
    }
}
