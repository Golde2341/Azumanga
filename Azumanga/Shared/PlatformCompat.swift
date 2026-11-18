import AppKit
import SwiftUI

/// The scroll phases the reader reacts to.
///
/// SwiftUI only exposes `ScrollPhase` from macOS 15, so the reader carries its own
/// copy; the compat modifiers translate whichever OS supplied the phase.
enum ReaderScrollPhase: Equatable {
    case idle
    case tracking
    case interacting
    case decelerating
    case animating
}

extension View {
    /// Liquid Glass on macOS 26+, a material fill with a hairline edge before that.
    @ViewBuilder
    func compatGlass<S: InsettableShape>(interactive: Bool = false, in shape: S = Capsule()) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }
        }
    }

    /// macOS 15's `onScrollPhaseChange`.
    ///
    /// Before macOS 15 the phases come from the scroll view's own live-scroll
    /// notifications, so the scroll view has to be handed in: the modifier is applied
    /// to the scroll view itself, whose background is outside its content.
    @ViewBuilder
    func compatScrollPhaseChange(
        scrollView: Binding<NSScrollView?>? = nil,
        _ action: @escaping (ReaderScrollPhase, ReaderScrollPhase) -> Void
    ) -> some View {
        if #available(macOS 15.0, *) {
            self.onScrollPhaseChange { oldPhase, phase in
                action(ReaderScrollPhase(oldPhase), ReaderScrollPhase(phase))
            }
        } else if let scrollView {
            self.background(LegacyScrollObserver(scrollView: scrollView, onPhase: action))
        } else {
            self
        }
    }

    /// macOS 15's scroll-geometry observation, for a row whose clip origin is the
    /// page position. Before macOS 15 this reads the same origin from the scroll
    /// view's bounds-change notifications.
    @ViewBuilder
    func compatScrollOffsetChange(
        scrollView: Binding<NSScrollView?>? = nil,
        _ action: @escaping (CGFloat) -> Void
    ) -> some View {
        if #available(macOS 15.0, *) {
            self.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, offset in
                action(offset)
            }
        } else if let scrollView {
            self.background(LegacyScrollObserver(scrollView: scrollView, onOffset: action))
        } else {
            self
        }
    }

    /// macOS 15's `windowToolbarFullScreenVisibility(.onHover)`: the toolbar hides
    /// itself in full screen but comes back when the pointer reaches the top.
    @ViewBuilder
    func compatToolbarFullScreenVisibilityOnHover() -> some View {
        if #available(macOS 15.0, *) {
            self.windowToolbarFullScreenVisibility(.onHover)
        } else {
            self
        }
    }

    /// macOS 15's `onScrollTargetVisibilityChange`.
    ///
    /// Before macOS 15 nothing is reported: the reader falls back to its scroll
    /// position binding, which every supported version maintains.
    @ViewBuilder
    func compatTargetVisibilityChange(
        threshold: Double = 0.5,
        _ action: @escaping ([ReaderStreamItemID]) -> Void
    ) -> some View {
        if #available(macOS 15.0, *) {
            self.onScrollTargetVisibilityChange(
                idType: ReaderStreamItemID.self,
                threshold: threshold,
                action
            )
        } else {
            self
        }
    }
}

/// Groups controls onto shared glass on macOS 26+, plain layout before that.
struct CompatGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

@available(macOS 15.0, *)
extension ReaderScrollPhase {
    init(_ phase: ScrollPhase) {
        switch phase {
        case .idle: self = .idle
        case .tracking: self = .tracking
        case .interacting: self = .interacting
        case .decelerating: self = .decelerating
        case .animating: self = .animating
        }
    }
}

/// Reports a scroll view's clip origin and live-scroll phases on macOS 14, standing in
/// for the SwiftUI modifiers that only exist from macOS 15.
///
/// The notifications used here predate every version this app supports, so the reader's
/// gesture handling behaves the same on all of them.
private struct LegacyScrollObserver: NSViewRepresentable {
    let scrollView: Binding<NSScrollView?>
    var onOffset: ((CGFloat) -> Void)?
    var onPhase: ((ReaderScrollPhase, ReaderScrollPhase) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(
            scrollView.wrappedValue,
            onOffset: onOffset,
            onPhase: onPhase
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(
            scrollView.wrappedValue,
            onOffset: onOffset,
            onPhase: onPhase
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        private weak var scrollView: NSScrollView?
        private var onOffset: ((CGFloat) -> Void)?
        private var onPhase: ((ReaderScrollPhase, ReaderScrollPhase) -> Void)?
        private var phase: ReaderScrollPhase = .idle

        func attach(
            _ scrollView: NSScrollView?,
            onOffset: ((CGFloat) -> Void)?,
            onPhase: ((ReaderScrollPhase, ReaderScrollPhase) -> Void)?
        ) {
            self.onOffset = onOffset
            self.onPhase = onPhase
            guard let scrollView, scrollView !== self.scrollView else { return }

            stop()
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true

            let centre = NotificationCenter.default
            centre.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            centre.addObserver(
                self,
                selector: #selector(liveScrollWillStart(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            centre.addObserver(
                self,
                selector: #selector(liveScrollDidScroll(_:)),
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
            centre.addObserver(
                self,
                selector: #selector(liveScrollDidEnd(_:)),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
            onOffset?(scrollView.contentView.bounds.origin.x)
        }

        func stop() {
            NotificationCenter.default.removeObserver(self)
            scrollView = nil
            phase = .idle
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            guard let scrollView else { return }
            onOffset?(scrollView.contentView.bounds.origin.x)
        }

        @objc private func liveScrollWillStart(_ notification: Notification) {
            guard phase == .idle else { return }
            let previous = phase
            phase = .tracking
            onPhase?(previous, phase)
        }

        @objc private func liveScrollDidScroll(_ notification: Notification) {
            // Only the first frame turns tracking into interacting; the rest are the
            // same gesture and must not re-notify.
            guard phase == .tracking else { return }
            let previous = phase
            phase = .interacting
            onPhase?(previous, phase)
        }

        @objc private func liveScrollDidEnd(_ notification: Notification) {
            guard phase != .idle else { return }
            let previous = phase
            phase = .idle
            onPhase?(previous, phase)
        }
    }
}
