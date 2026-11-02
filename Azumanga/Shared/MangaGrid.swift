import AppKit
import SwiftUI

/// A responsive grid of manga cards with pagination and context actions.
struct MangaGrid: View {
    let items: [Manga]
    var favoriteIds: Set<String> = []
    var progressLabel: (Manga) -> String? = { _ in nil }
    var isLoadingMore: Bool = false
    var showsCoverShadow: Bool = false
    var columnSpacing: CGFloat = 16
    var onReachEnd: (() -> Void)?
    /// Opens the card's detail view. Supplying this also installs the Force Touch
    /// overlay, which takes over pointer clicks so it can tell a force click apart
    /// from a regular one.
    var onOpen: ((Manga) -> Void)?
    /// Called on a Force Touch click. Returning `true` means the force click was
    /// handled; returning `false` lets the regular click open the detail view.
    var onForceTouch: ((Manga) -> Bool)?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: columnSpacing)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(items) { manga in
                NavigationLink(value: manga) {
                    MangaCard(
                        manga: manga,
                        isFavorite: favoriteIds.contains(manga.id),
                        progressLabel: progressLabel(manga),
                        showsCoverShadow: showsCoverShadow
                    )
                }
                .buttonStyle(.plain)
                .overlay {
                    if let onOpen, let onForceTouch {
                        MangaForceTouchOverlay(
                            onClick: { onOpen(manga) },
                            onForceClick: { onForceTouch(manga) }
                        )
                    }
                }
                .onAppear {
                    if manga.id == items.last?.id {
                        onReachEnd?()
                    }
                }
            }
        }
        .padding(20)
        // The window has to opt in to pressure events as well; without it the
        // trackpad configuration only comes alive after the cursor re-enters.
        .background(MangaGridPressureWindow())

        if isLoadingMore {
            ProgressView()
                .controlSize(.small)
                .padding(.bottom, 20)
        }
    }
}

/// A transparent AppKit view laid over a card.
///
/// Force clicks only reach a view that owns a pressure configuration, and a local
/// event monitor does not see them while a control is tracking the mouse. This view
/// therefore receives the press itself: a pressure event that reaches stage two is a
/// Force Touch click. Ordinary clicks are forwarded through `onClick`, so the card
/// still opens normally when no force click was handled.
private struct MangaForceTouchOverlay: NSViewRepresentable {
    let onClick: () -> Void
    let onForceClick: () -> Bool

    func makeNSView(context: Context) -> ForceTouchView {
        let view = ForceTouchView()
        view.onClick = onClick
        view.onForceClick = onForceClick
        return view
    }

    func updateNSView(_ nsView: ForceTouchView, context: Context) {
        nsView.onClick = onClick
        nsView.onForceClick = onForceClick
    }

    final class ForceTouchView: NSView {
        var onClick: (() -> Void)?
        var onForceClick: (() -> Bool)?

        private var isPressed = false
        private var forceHandled = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func mouseDown(with event: NSEvent) {
            isPressed = true
            forceHandled = false
        }

        override func pressureChange(with event: NSEvent) {
            guard isPressed, event.stage == 2, !forceHandled else { return }
            forceHandled = onForceClick?() ?? false
        }

        override func mouseUp(with event: NSEvent) {
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            let handledByForce = forceHandled
            isPressed = false
            forceHandled = false

            if inside, !handledByForce {
                onClick?()
            }
        }
    }
}

/// Opts the hosting window into pressure events. Doing this at the window level is
/// what makes Force Touch work as soon as the pointer enters the window, instead of
/// only after it has left and come back.
private struct MangaGridPressureWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowView()
        Task { @MainActor in view.configure() }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowView)?.configure()
    }

    final class WindowView: NSView {
        private var keyObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
            Task { @MainActor [weak self] in self?.configure() }
        }

        func configure() {
            guard let window else { return }
            window.contentView?.pressureConfiguration =
                NSPressureConfiguration(pressureBehavior: .primaryDeepClick)

            if keyObserver == nil {
                keyObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.configure()
                }
            }
        }

        deinit {
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
        }
    }
}
