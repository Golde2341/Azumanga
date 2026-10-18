import AppKit
import ObjectiveC
import SwiftUI

/// Hosts the reader: builds its model from the session and environment.
struct ReaderContainerView: View {
    let session: ReaderSession

    @Environment(Services.self) private var services
    @Environment(SettingsStore.self) private var settings
    @Environment(MangaViewOptionsStore.self) private var mangaViewOptions

    @State private var model: ReaderModel?
    @State private var viewOptions: ReaderViewOptions?

    var body: some View {
        Group {
            if let model, let viewOptions {
                ReaderView(model: model, viewOptions: viewOptions)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard model == nil, viewOptions == nil else { return }
            let viewOptions = ReaderViewOptions(
                manga: session.manga,
                defaults: settings,
                store: mangaViewOptions
            )
            let model = ReaderModel(
                manga: session.manga,
                chapters: session.chapters,
                startChapterId: session.chapterId,
                startPageIndex: session.startPageIndex,
                services: services,
                settings: settings,
                viewOptions: viewOptions
            )
            self.viewOptions = viewOptions
            self.model = model
            await model.load()
        }
    }
}

/// The reading surface: a continuous vertical or horizontal stream, with zoom,
/// keyboard shortcuts, chapter navigation and automatic progress saving.
///
/// The window itself is managed by the scene (`.windowStyle(.hiddenTitleBar)` in
/// `AzumangaApp.swift`). Full screen is available two ways: AppKit's native full screen
/// (green button, View menu) and the reader's own screen-filling mode (`F`), which does
/// not use the native transition at all. Window chrome (traffic lights, page shape) is
/// only applied from `reconcileWindow`.
struct ReaderView: View {
    @Bindable var model: ReaderModel
    @Bindable var viewOptions: ReaderViewOptions

    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.imagePipeline) private var images

    @State private var showChapterPicker = false
    /// The window hosting the reader, used to drive full screen and measure traffic lights.
    @State private var window: NSWindow?
    /// Keeps native window-edge resizing on the current page/spread aspect.
    @State private var windowResizeDelegate = ReaderWindowResizeDelegate()
    /// Whether the reader is filling the screen in its own windowed mode. The reader
    /// keeps this alongside AppKit's native full screen; the two never overlap.
    @State private var isReaderFullScreen = false
    /// True while the custom full-screen window is animating between its windowed
    /// frame and the screen frame. Further full-screen toggles wait for it to settle.
    @State private var isFullScreenAnimating = false
    /// Invalidates a custom full-screen animation if native full screen takes over.
    @State private var fullScreenState = ReaderFullScreenState()
    /// Whether AppKit's own full screen is active.
    @State private var isNativeFullScreen = false
    /// Whether AppKit is mid-transition into or out of native full screen. Window chrome
    /// is left alone for the whole transition.
    @State private var isNativeFullScreenTransition = false
    /// Ignore horizontal page-position callbacks while a full-screen frame change is
    /// still settling. Re-laying out a lazy horizontal stream at a new window size can
    /// move it by a page; that movement must not advance the reader's model.
    @State private var pageSyncSuppressedUntil: Date = .distantPast
    /// Counts native full screen transitions, so a settle that finishes late cannot
    /// clear the flag for a transition that has started since.
    @State private var nativeFullScreenGeneration = 0
    /// The window's frame from before it filled the screen, restored when leaving.
    @State private var windowedFrame: NSRect?
    /// The window's size limits from before it filled the screen. While filling the
    /// screen they are pinned so edge drags cannot shrink the page.
    @State private var windowedSizeLimits: (min: NSSize, max: NSSize)?
    /// The app's presentation options from before full screen, restored when leaving.
    @State private var savedPresentationOptions: NSApplication.PresentationOptions = []
    /// The window's level from before the reader filled the screen itself. The custom
    /// mode sits above the menu bar so the page reaches the display's top edge and the
    /// camera housing no longer leaves a reserved strip.
    @State private var windowedLevel: NSWindow.Level?
    private static let readerFullScreenLevel = NSWindow.Level(
        rawValue: NSWindow.Level.mainMenu.rawValue + 2
    )
    /// The spread (or chapter break) on screen. Two-way bound to the horizontal scroll
    /// view, so a gesture reports where it landed and a keyboard turn can drive it back.
    @State private var spreadPosition: ReaderStreamItemID?
    /// Vertical reader page tracking, kept out of observable state so scrolling never
    /// re-renders or moves the view.
    @State private var verticalScrollTracker = ReaderVerticalScrollTracker()
    /// Chapters currently in the reader, in reading order. The first is the chapter
    /// the model opened; following ones are loaded before they are reached.
    @State private var sections: [ReaderSection] = []
    /// The chapter id currently being fetched for the end of the stream.
    @State private var loadingSectionID: String?
    /// A chapter at the end of the stream that could not be loaded, so the break can
    /// offer a retry instead of asking again on every scroll pause.
    @State private var failedSectionID: String?
    /// A page the reader should scroll to because the model moved for a reason other
    /// than scrolling: initial restore, chapter jump, or keyboard.
    @State private var pendingScrollPageID: ReaderPageID?
    /// The scroll view's live offset, which the paging behavior reads when a gesture ends.
    @State private var scrollOffset = ReaderScrollOffset()
    /// Whether the reader's own controls are on screen. They stay out of the way while
    /// reading and come back when the pointer arrives or the page is clicked.
    @State private var controlsVisible = true
    /// Bumped every time the controls are called for. Drives the countdown that puts them
    /// away again, so SwiftUI owns the timing rather than a task held in state.
    @State private var revealTick = 0
    /// Whether the display popover is open.
    @State private var showsDisplayOptions = false
    /// Where along the progress bar a drag has reached, while it is being dragged.
    @State private var isScrubbing = false
    /// The scroll view backing the vertical reader, used for native magnification.
    @State private var verticalScrollView: NSScrollView?
    /// The content position at the viewport's top edge when a live window resize
    /// begins. Recomputing its offset as the page widths change keeps the same
    /// reading spot under the viewport edge.
    @State private var resizeAnchor: ReaderZoomAnchor?
    @State private var resizePinTask: Task<Void, Never>?
    @State private var resizeSettleTask: Task<Void, Never>?
    /// Whether a pinch is in flight. While the pages change size under the scroll
    /// view, its intermediate positions must not be treated as page turns.
    @State private var isMagnifying = false
    /// The zoom the current pinch started from, so repeated pinches accumulate.
    @State private var zoomGestureBase: CGFloat = 1
    /// The content position at the top of the viewport when a pinch starts. Keeping
    /// it fixed is what prevents a layout zoom from scrolling the webtoon.
    @State private var zoomAnchor: ReaderZoomAnchor?
    /// Re-applies the zoom anchor after SwiftUI commits the new page heights.
    @State private var zoomApplyTask: Task<Void, Never>?
    /// The document offset a zoom change should land on. Applied as soon as the
    /// scroll view reports the matching content height, so size and position change
    /// together instead of the content sliding first.
    @State private var pendingZoomTargetY: CGFloat?
    /// Repeats that adjustment while a pinch is live. Layout and scroll updates can
    /// arrive in either order, so pinning the target for the duration is what makes
    /// the stream hold still instead of sliding under the gesture.
    @State private var zoomPinTask: Task<Void, Never>?
    /// Keeps page tracking from reading the transient positions produced while a
    /// pinch is changing every page's height.
    @State private var isZoomSettling = false
    @State private var zoomSettleTask: Task<Void, Never>?
    /// Whether the corner grip is driving the window size. The controls must stay
    /// visible while it is.
    @State private var isResizingWindow = false
    @State private var scrubFraction: CGFloat = 0
    /// A page's width over its height, once one of them has loaded and can be measured.
    @State private var pageAspect: CGFloat?
    /// The same proportion, but fixed for the vertical reader's layout. Every page
    /// reserves a slot of this shape before its image arrives, so an image finishing
    /// its load can never reflow the stack and move the viewport.
    @State private var verticalPageAspect: CGFloat?
    /// The stable page proportion for this episode, decided once from a sample and
    /// then kept for every spread in it.
    @State private var episodePageAspect: CGFloat?
    @State private var episodeAspectChapterId: String?
    @State private var episodeAspectLocked = false
    @State private var episodeShapeTask: Task<Void, Never>?
    /// The shape last put on to the window, so it is only resized when it actually changes.
    @State private var appliedAspectRatio: CGFloat = 0
    /// Distance from the window's top edge down to the traffic lights' centre line, so the
    /// control bar can put its own centre on the same line instead of guessing.
    @State private var trafficLightCentre: CGFloat?
    /// How much room the traffic lights take up along the top, so the controls clear them.
    /// Zero in full screen, where there are none.
    @State private var trafficLightSpan: CGFloat = 64
    /// The control bar's own height, measured for that same calculation.
    @State private var controlBarHeight: CGFloat = 0
    /// Plays the cover-to-pages opening once, when the reader is first shown.
    @State private var hasFinishedIntro = false
    /// Keeps the cover on screen until the reveal has played and it can be removed.
    @State private var showIntroCover = true

    var body: some View {
        ZStack {
            viewOptions.background.color
                .ignoresSafeArea()

            content
                // The pages settle from slightly zoomed out while the cover lifts away.
                .scaleEffect(hasFinishedIntro ? 1 : 0.94)
                .opacity(hasFinishedIntro ? 1 : 0)
                // A click on the page also brings the controls back, for when the pointer
                // has not moved to do it.
                .simultaneousGesture(TapGesture().onEnded { revealControls() })

            if model.isLoading && !showIntroCover {
                ProgressView()
                    .controlSize(.large)
            }

            if showIntroCover {
                introCover
                    .transition(.opacity)
            }

            if controlsVisible && !showIntroCover {
                VStack {
                    controlBar
                    Spacer()
                }
                .transition(.opacity)
            }

            if controlsVisible && !showIntroCover {
                pageIndicator
                    .transition(.opacity)
            }

        }
        .animation(.easeInOut(duration: 0.18), value: controlsVisible)
        .animation(.easeInOut(duration: 0.3), value: showIntroCover)
        // The page runs to the very top edge. Without this the window keeps a strip the
        // height of a title bar above the content, which reads as a bar across the top even
        // though no title is drawn in it.
        .ignoresSafeArea(.container, edges: .top)
        // In native full screen the window's toolbar only exists for the traffic
        // lights' spacing, so keep it out of the way until the pointer asks for it.
        .windowToolbarFullScreenVisibility(.onHover)
        // The traffic lights follow the controls, so a reader with the controls put
        // away has nothing on screen but the page.
        .onChange(of: controlsVisible) { _, _ in
            guard let window else { return }
            reconcileWindow(window)
        }
        .onHover { isInside in
            // Only the pointer arriving counts. Movement inside the reader deliberately
            // does not push the clock back — otherwise a moving mouse would hold the
            // controls on screen forever and they would never go away. Clicking, or
            // leaving and coming back, calls for them again.
            if isInside {
                revealControls()
            }
        }
        .task(id: revealTick) {
            guard revealTick > 0 else { return }
            try? await Task.sleep(for: .seconds(3))
            // Never while something presented is open: the display popover and the chapter
            // sheet are anchored to controls, and hiding those would take them along. The
            // progress bar must also stay put while it is being dragged.
            guard !Task.isCancelled, !showsDisplayOptions, !showChapterPicker,
                  !isScrubbing, !isResizingWindow
            else { return }
            controlsVisible = false
        }
        .onAppear {
            revealControls()
            scheduleIntroIfNeeded()
            syncSectionsFromModel()
            beginEpisodeShapeSampling(force: true)
        }
        .onChange(of: model.pages) { _, _ in
            syncSectionsFromModel()
            beginEpisodeShapeSampling()
        }
        .onChange(of: model.chapter.chapterId) { _, _ in
            beginEpisodeShapeSampling(force: true)
        }
        .onChange(of: model.chapterCount) { _, _ in
            // A reader opened without a chapter list gets it in the background.
            // Once it arrives, the continuous stream can grow past the first chapter.
            syncSectionsFromModel()
        }
        // The window hosting the view, reported by AppKit rather than guessed from
        // whichever window happens to be key.
        .background(WindowAccessor(window: $window))
        .onChange(of: window) { _, newWindow in
            // One-time window setup: make the page run under the title bar and keep
            // AppKit's own full screen out of the reader's way.
            guard let newWindow else { return }
            makeBorderless(newWindow)
            windowResizeDelegate.attach(to: newWindow)
            updateWindowResizeLock()
            // The image task can finish before the window accessor has published the
            // window. Shape it as soon as both sides exist; pageAspect changes refine
            // the ratio when the current page's real proportions arrive.
            Task { @MainActor in
                reconcileWindow(newWindow, resizingWindowShape: true)
            }
        }
        .navigationTitle(model.chapterLabel)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { turnSpread(-1); return .handled }
        .onKeyPress(.rightArrow) { turnSpread(1); return .handled }
        .onKeyPress(.upArrow) { turnSpread(-1); return .handled }
        .onKeyPress(.downArrow) { turnSpread(1); return .handled }
        .onKeyPress(.space) { turnSpread(1); return .handled }
        .onKeyPress(.pageUp) { turnSpread(-1); return .handled }
        .onKeyPress(.pageDown) { turnSpread(1); return .handled }
        .onKeyPress("+") {
            guard viewOptions.layout == .vertical else { return .handled }
            model.zoomIn()
            return .handled
        }
        .onKeyPress("=") {
            guard viewOptions.layout == .vertical else { return .handled }
            model.zoomIn()
            return .handled
        }
        .onKeyPress("-") {
            guard viewOptions.layout == .vertical else { return .handled }
            model.zoomOut()
            return .handled
        }
        .onKeyPress("0") {
            guard viewOptions.layout == .vertical else { return .handled }
            model.resetZoom()
            return .handled
        }
        .onKeyPress("[") { goToAdjacentChapter(-1); return .handled }
        .onKeyPress("]") { goToAdjacentChapter(1); return .handled }
        .onKeyPress("b") { model.toggleBookmark(); return .handled }
        .onKeyPress("f") { toggleFullScreen(); return .handled }
        .onKeyPress(.escape) {
            // Escape leaves full screen first, the way it does in a native full
            // screen window; only an ordinary window closes the reader.
            if isReaderFullScreen || isNativeFullScreen {
                toggleFullScreen()
            } else {
                model.flushProgress()
                dismiss()
            }
            return .handled
        }
        .onKeyPress("m") { model.markCurrentChapterRead(); return .handled }
        .sheet(isPresented: $showChapterPicker) {
            ChapterPickerSheet(model: model, isPresented: $showChapterPicker)
        }
        .task(id: "\(model.chapter.chapterId):\(model.currentIndex)") {
            // Keep the vertical stack's fixed slot shape informed. The horizontal
            // window's shape is decided per episode by the sampler, not per page.
            for attempt in 0..<4 {
                await readPageAspect()
                if pageAspect != nil || attempt == 3 { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: episodePageAspect) { _, newAspect in
            updateWindowResizeLock()
            // One correction per episode, once the sample resolves.
            guard newAspect != nil, let window, !isResizingWindow else { return }
            reconcileWindow(window, resizingWindowShape: true)
        }
        .onChange(of: windowAspectRatio) { _, _ in
            updateWindowResizeLock()
        }
        .onChange(of: isReaderFullScreen) { _, _ in
            updateWindowResizeLock()
        }
        .onChange(of: isNativeFullScreen) { _, _ in
            updateWindowResizeLock()
        }
        .onChange(of: isNativeFullScreenTransition) { _, _ in
            updateWindowResizeLock()
        }
        .onChange(of: viewOptions.layout) { _, newLayout in
            if newLayout == .vertical {
                // Releasing the lock must not wait on full-screen bookkeeping; this
                // only clears the ratio and any stuck size limit, it never resizes.
                applyWindowShape()
                updateWindowResizeLock()
                syncSectionsFromModel()
                // The vertical scroll view is new; open it where the reader is.
                if let id = currentVerticalPageID {
                    verticalScrollTracker.topPageID = id
                    verticalScrollTracker.lastAppliedPageID = id
                    verticalScrollTracker.isRestoring = true
                    pendingScrollPageID = id
                }
            }
            if newLayout == .horizontal {
                model.resetZoom()
                beginEpisodeShapeSampling()
            }
            guard let window else { return }
            reconcileWindow(window, resizingWindowShape: true)
        }
        .onChange(of: viewOptions.pageMode) { _, _ in
            updateWindowResizeLock()
            guard let window else { return }
            reconcileWindow(window, resizingWindowShape: true)
        }
        .onChange(of: settings.doublePageFirstPageAlone) { _, _ in
            updateWindowResizeLock()
            guard let window else { return }
            reconcileWindow(window, resizingWindowShape: true)
        }
        .onChange(of: model.isLoading) { _, isLoading in
            if !isLoading { scheduleIntroIfNeeded() }
        }
        // Native full screen is tracked separately from the reader's own screen-filling
        // mode. Nothing is done to the window from `will…` until the transition has
        // unwound, except dropping any leftover exclusive-full-screen state: AppKit
        // cannot transition a window that still has the temporary subclass, high
        // level and pinned frame from that mode.
        .task(id: window) {
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSWindow.willEnterFullScreenNotification,
                object: window
            ) {
                abandonCustomFullScreenIfNeeded(window)
                beginNativeFullScreenTransition()
            }
        }
        .task(id: window) {
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSWindow.didEnterFullScreenNotification,
                object: window
            ) {
                settings.readerFullscreen = true
                isNativeFullScreen = true
                isNativeFullScreenTransition = false
            }
        }
        .task(id: window) {
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSWindow.willExitFullScreenNotification,
                object: window
            ) {
                beginNativeFullScreenTransition()
            }
        }
        .task(id: window) {
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSWindow.didExitFullScreenNotification,
                object: window
            ) {
                settings.readerFullscreen = false
                isNativeFullScreen = false
                // `didExit` is posted while AppKit is still putting the window back
                // together; the chrome is applied once the notification has unwound.
                let generation = nativeFullScreenGeneration
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard generation == nativeFullScreenGeneration else { return }
                    isNativeFullScreenTransition = false
                    reconcileWindow(window)
                    // Resizing into and out of native full screen can move a lazy
                    // horizontal scroll view by a page. Position callbacks are ignored
                    // during the transition, so put the scroll view back on the page
                    // the model actually has open.
                    syncHorizontalPosition(animated: false)
                    // The lazy stack can settle a beat after the window does. Repeat
                    // once more while page-position updates are still suppressed.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(200))
                        guard generation == nativeFullScreenGeneration else { return }
                        syncHorizontalPosition(animated: false)
                    }
                }
            }
        }
        // A live window resize changes every vertical page's height. Anchor the exact
        // page position at the viewport top and pin it while the width changes, so the
        // stream cannot slide and the same spot remains after the resize ends.
        .task(id: window) {
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSWindow.willStartLiveResizeNotification,
                object: window
            ) {
                guard viewOptions.layout == .vertical,
                      !isReaderFullScreen,
                      !isNativeFullScreen,
                      !isNativeFullScreenTransition,
                      !isFullScreenAnimating
                else { continue }

                resizeSettleTask?.cancel()
                resizeAnchor = captureZoomAnchor(zoom: model.zoom)
                resizePinTask?.cancel()
                resizePinTask = Task { @MainActor in
                    while !Task.isCancelled {
                        applyResizeAnchor()
                        try? await Task.sleep(for: .milliseconds(8))
                    }
                }
            }
        }
        .task(id: window) {
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSWindow.didEndLiveResizeNotification,
                object: window
            ) {
                guard resizeAnchor != nil else { continue }
                // Keep pinning through the last layout pass, then settle and release.
                resizeSettleTask?.cancel()
                resizeSettleTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled else { return }
                    applyResizeAnchor()
                    resizePinTask?.cancel()
                    resizePinTask = nil
                    resizeAnchor = nil
                }
            }
        }
        // A level above the menu bar is app-wide z-order, not just this space. Drop it
        // when the app is no longer frontmost so the reader does not float above other
        // applications; put it back when the reader becomes active again.
        .task(id: window) {
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didResignActiveNotification
            ) {
                guard isReaderFullScreen else { continue }
                window.level = windowedLevel ?? .normal
            }
        }
        .task(id: window) {
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification
            ) {
                guard isReaderFullScreen else { continue }
                window.level = Self.readerFullScreenLevel
                NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            }
        }
        .onDisappear {
            // Presentation options are app-wide, so full screen must not outlive the view.
            if isReaderFullScreen {
                if NSApp.isActive {
                    NSApp.presentationOptions = savedPresentationOptions
                }
                if let window {
                    ReaderFullScreenWindow.exit(window)
                    if let windowedLevel {
                        window.level = windowedLevel
                    }
                }
            }
            windowResizeDelegate.detach()
            episodeShapeTask?.cancel()
            verticalScrollTracker.applyTask?.cancel()
            zoomApplyTask?.cancel()
            zoomPinTask?.cancel()
            zoomSettleTask?.cancel()
            resizePinTask?.cancel()
            resizeSettleTask?.cancel()
            model.flushProgress()
        }
    }

    /// Ignores scroll-driven page updates while a full-screen frame transition and the
    /// layout it triggers are still settling.
    private var isPageSyncSuppressed: Bool {
        Date() < pageSyncSuppressedUntil
    }

    private func suppressPageSync(for interval: TimeInterval) {
        pageSyncSuppressedUntil = Date().addingTimeInterval(interval)
    }

    /// Marks AppKit's native full screen transition as in flight. Window chrome is left
    /// alone until the matching `did…` notification has unwound.
    private func beginNativeFullScreenTransition() {
        suppressPageSync(for: 1.2)
        nativeFullScreenGeneration += 1
        isNativeFullScreenTransition = true
        windowResizeDelegate.isEnabled = false
        windowResizeDelegate.aspectRatio = nil
    }

    /// Fills the screen with the reader without involving AppKit's full screen.
    ///
    /// The window stays an ordinary window the whole time: only its frame, its level
    /// and the system's presentation options change. There is no space transition and
    /// no title bar swap, which is what avoids the native full screen exit hang.
    private func enterReaderFullScreen(_ window: NSWindow) {
        guard !isReaderFullScreen,
              !isFullScreenAnimating,
              let screen = window.screen ?? NSScreen.main
        else { return }

        suppressPageSync(for: 0.8)
        isFullScreenAnimating = true
        fullScreenState.generation &+= 1
        let generation = fullScreenState.generation
        windowedFrame = window.frame
        windowedSizeLimits = (window.minSize, window.maxSize)
        windowedLevel = window.level
        ReaderFullScreenWindow.enter(window)
        savedPresentationOptions = NSApp.presentationOptions
        isReaderFullScreen = true
        settings.readerFullscreen = true

        // The page fills the screen; the grip that shapes the windowed reader is
        // not available there.
        appliedAspectRatio = 0
        windowResizeDelegate.isEnabled = false
        windowResizeDelegate.aspectRatio = nil

        // Native full screen is not available while the reader is filling the screen
        // itself; the green button zooms instead. It comes back on exit.
        window.collectionBehavior.insert(.fullScreenNone)
        window.collectionBehavior.remove(.fullScreenPrimary)

        // A screen-filling window should not slide around under the pointer.
        window.isMovable = false
        // At normal level the menu bar draws over the window, leaving the page short
        // of the display's top edge. Sitting just above the menu bar makes the custom
        // full screen truly screen-filling: the page runs under the menu bar area and
        // the camera housing.
        window.level = Self.readerFullScreenLevel

        // Hide the reader's own full-screen chrome immediately (the traffic lights
        // and resize grip). The menu bar and Dock stay put; the growing window covers
        // them, and they are put into their full-screen state once it has arrived.
        reconcileWindow(window)

        animateReaderWindow(window, to: screen.frame) {
            guard generation == fullScreenState.generation else { return }
            // Pin the limits only once the window has reached the screen size; while
            // it is growing, the windowed limits must not fight the animation.
            window.minSize = screen.frame.size
            window.maxSize = screen.frame.size
            // The window has covered the menu bar and Dock on its way up; put the
            // system chrome into its full-screen state now, not before the animation.
            if NSApp.isActive {
                NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            }
            isFullScreenAnimating = false
            reconcileWindow(window)
        }
    }

    /// Puts the window back where it was and hands the menu bar and Dock back.
    private func exitReaderFullScreen(_ window: NSWindow) {
        guard isReaderFullScreen, !isFullScreenAnimating else { return }
        suppressPageSync(for: 0.8)
        isFullScreenAnimating = true
        fullScreenState.generation &+= 1
        let generation = fullScreenState.generation

        // Let the chrome come back behind the window before it starts shrinking; the
        // window uncovers the menu bar and Dock as its top and bottom edges move in.
        if NSApp.isActive {
            NSApp.presentationOptions = savedPresentationOptions
        }

        // Let the frame reach the smaller windowed size while it animates.
        if let windowedSizeLimits {
            window.minSize = windowedSizeLimits.min
            window.maxSize = windowedSizeLimits.max
            self.windowedSizeLimits = nil
        }

        let destination = windowedFrame ?? window.frame
        animateReaderWindow(window, to: destination) {
            guard generation == fullScreenState.generation else { return }
            isReaderFullScreen = false
            settings.readerFullscreen = false
            isFullScreenAnimating = false

            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)

            window.isMovable = true

            ReaderFullScreenWindow.exit(window)
            if let windowedLevel {
                window.level = windowedLevel
                self.windowedLevel = nil
            }
            self.windowedFrame = nil
            updateWindowResizeLock()
            reconcileWindow(window)
            syncHorizontalPosition(animated: false)
        }
    }

    /// Drops the exclusive-full-screen state immediately when AppKit starts its own
    /// full-screen transition.
    ///
    /// Native full screen must not inherit the custom mode's high window level,
    /// pinned frame or presentation options: AppKit's transition can hang when it
    /// does. This is the safety net for a native transition started by a menu command
    /// or shortcut while the custom mode is active or still animating. Normal
    /// windowed entries are untouched.
    private func abandonCustomFullScreenIfNeeded(_ window: NSWindow) {
        let hasResidualLevel = window.level.rawValue > NSWindow.Level.mainMenu.rawValue

        guard isReaderFullScreen
                || isFullScreenAnimating
                || windowedLevel != nil
                || hasResidualLevel
        else { return }

        fullScreenState.generation &+= 1
        isFullScreenAnimating = false
        isReaderFullScreen = false
        settings.readerFullscreen = false

        if NSApp.isActive {
            NSApp.presentationOptions = savedPresentationOptions
        }
        if let limits = windowedSizeLimits {
            window.minSize = limits.min
            window.maxSize = limits.max
            windowedSizeLimits = nil
        }

        window.isMovable = true
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)

        ReaderFullScreenWindow.exit(window)

        if let originalLevel = windowedLevel {
            window.level = originalLevel
        } else if hasResidualLevel {
            window.level = .normal
        }
        windowedLevel = nil

        // Leave the frame alone. AppKit is starting its own transition and owns the
        // window now; whatever frame it captures is what native full screen restores.
        windowedFrame = nil
    }

    /// Animates the reader's window frame. Reduce Motion falls back to an immediate
    /// change; the completion still runs either way.
    private func animateReaderWindow(
        _ window: NSWindow,
        to frame: NSRect,
        completion: @escaping () -> Void
    ) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(frame, display: true)
            completion()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            completion()
        }
    }

    /// Shows the controls and restarts the countdown that puts them away again.
    private func revealControls() {
        controlsVisible = true
        revealTick += 1
    }

    /// Starts the opening reveal once the chapter has loaded. Waiting for the first
    /// page image keeps the cover from zooming away onto a placeholder; the timeout
    /// keeps a slow or failed image from leaving the cover up forever.
    private func scheduleIntroIfNeeded() {
        guard showIntroCover, !hasFinishedIntro, !model.isLoading else { return }

        guard let firstPage = model.pages.first else {
            finishIntro()
            return
        }

        let size = model.renderMaxPixelSize
        Task {
            // The first page is loaded for the reveal, so this is the earliest point
            // at which the chapter's proportions can be known. Fixing them here means
            // the vertical stack is already shaped correctly when the pages arrive.
            if let image = try? await images.image(for: firstPage, maxPixelSize: size),
               image.height > 0 {
                let aspect = CGFloat(image.width) / CGFloat(image.height)
                if verticalPageAspect == nil {
                    verticalPageAspect = aspect
                }
            }
            finishIntro()
        }
        Task {
            try? await Task.sleep(for: .milliseconds(1800))
            finishIntro()
        }
    }

    /// Zooms the cover away while the pages settle into place, then removes it.
    private func finishIntro() {
        guard !hasFinishedIntro else { return }
        withAnimation(.spring(response: 0.48, dampingFraction: 0.8)) {
            hasFinishedIntro = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(550))
            withAnimation(.easeInOut(duration: 0.28)) {
                showIntroCover = false
            }
            revealControls()
        }
    }

    /// The manga cover shown while the chapter loads: centred over a soft copy of
    /// itself, then zoomed, blurred and faded away as the pages arrive.
    private var introCover: some View {
        GeometryReader { geometry in
            let coverWidth = min(
                geometry.size.width * 0.32,
                geometry.size.height * 0.42,
                340
            )

            ZStack {
                if let coverURL = model.manga.coverURL {
                    CoverImage(url: coverURL)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: 70)
                        .opacity(0.32)
                }

                VStack(spacing: 22) {
                    CoverImage(url: model.manga.coverURL)
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .frame(width: coverWidth)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 30, x: 0, y: 18)

                    ProgressView()
                        .controlSize(.small)
                        .opacity(model.isLoading ? 1 : 0)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .scaleEffect(hasFinishedIntro ? 1.9 : 1)
        .opacity(hasFinishedIntro ? 0 : 1)
        .blur(radius: hasFinishedIntro ? 32 : 0)
        .allowsHitTesting(false)
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
            switch viewOptions.layout {
            case .vertical:
                verticalReader
            case .horizontal:
                horizontalReader
            }
        }
    }

    /// The vertical stream: every loaded chapter's pages, with a break between them.
    ///
    /// A page keeps the same fixed slot whether it is the first page of the chapter
    /// or the last, so appending the next episode below the stream cannot move the
    /// viewport. The model follows the scroll only when the gesture settles, and the
    /// view never binds its scroll position to the model.
    private var verticalReader: some View {
        GeometryReader { geometry in
            let pageWidth = geometry.size.width
            let zoom = model.zoom
            // Zoom changes the pages' real layout size, so the lazy stack knows
            // exactly what is on screen. Compared to scaling the scroll view, this
            // also keeps lazy page loading in step with the viewport.
            let contentWidth = max(pageWidth, pageWidth * zoom)
            // Every page gets the same reserved shape. The image is fitted inside it,
            // so going from placeholder to decoded page cannot change the stack's
            // height — the reflow that used to shove the scroll view into the previous
            // page is gone.
            let reservedAspect = min(max(verticalPageAspect ?? Self.typicalPageAspectRatio, 0.2), 5)
            let pageHeight = (pageWidth * zoom) / reservedAspect

            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        // Flattened deliberately: pages must be direct children of the
                        // lazy stack, not pages nested inside a lazy row, or the whole
                        // chapter is built (and its images loaded) at once.
                        ForEach(verticalItems) { item in
                            verticalItemView(
                                item,
                                pageWidth: pageWidth * zoom,
                                pageHeight: pageHeight
                            )
                        }
                    }
                    .frame(width: contentWidth)
                    // Inside the scroll content, so it is definitely the scroll view
                    // containing it that gets found.
                    .background(ScrollViewAccessor(scrollView: $verticalScrollView))
                }
                .coordinateSpace(.named("verticalReader"))
                // The page on screen is read from geometry. Binding the scroll
                // position to the model made SwiftUI re-anchor the page — and jump —
                // whenever scrolling updated the model.
                .onPreferenceChange(ReaderVerticalPageTopsKey.self) { tops in
                    trackVerticalPage(tops)
                }
                .onScrollPhaseChange { oldPhase, phase in
                    verticalScrollTracker.isUserScrolling = phase == .tracking
                        || phase == .interacting
                        || phase == .decelerating
                    // The model is only brought up to date when the gesture ends;
                    // nothing re-renders the reader while it is scrolling.
                    if oldPhase != .idle, phase == .idle {
                        applyTrackedVerticalPage()
                    }
                }
                // Only a model change that did not come from scrolling moves the
                // view: keyboard turns, the scrubber, restoring a page in a new
                // stream. Crossing a chapter while scrolling sets `lastApplied`
                // first, so it is recognised and leaves the scroll alone.
                .onChange(of: currentVerticalPageID) { _, newValue in
                    guard !verticalScrollTracker.isUserScrolling,
                          !verticalScrollTracker.isApplyingModelChange,
                          let newValue,
                          newValue != verticalScrollTracker.lastAppliedPageID
                    else { return }
                    verticalScrollTracker.topPageID = newValue
                    verticalScrollTracker.lastAppliedPageID = newValue
                    proxy.scrollTo(newValue, anchor: .top)
                }
                .onChange(of: pendingScrollPageID) { _, _ in
                    performPendingScroll(proxy)
                }
                // The document view grows or shrinks in one layout pass. Apply the
                // pending zoom offset at that exact moment, before the new size is
                // drawn, rather than waiting for a timer.
                .task(id: verticalScrollView.map { ObjectIdentifier($0) }) {
                    guard let scrollView = verticalScrollView,
                          let documentView = scrollView.documentView
                    else { return }

                    for await _ in NotificationCenter.default.notifications(
                        named: NSView.frameDidChangeNotification,
                        object: documentView
                    ) {
                        applyPendingZoomTarget()
                        applyResizeAnchor()
                    }
                }
                .onAppear {
                    // A freshly mounted scroll view is not mid-gesture. Clear any
                    // flags left behind if the reader was replaced during a scroll.
                    verticalScrollTracker.isUserScrolling = false
                    verticalScrollTracker.isApplyingModelChange = false
                    // The reader can be re-created (layout switch, recovering from a
                    // load error) while the stream state survives. Open at the page
                    // being read rather than at the top of the first loaded chapter.
                    if pendingScrollPageID == nil, let id = currentVerticalPageID {
                        pendingScrollPageID = id
                    }
                    performPendingScroll(proxy)
                }
                .scrollIndicators(.never)
                .gesture(verticalZoomGesture)
                .onTapGesture(count: 2) {
                    model.zoom > 1 ? model.resetZoom() : model.setZoom(2)
                }
            }
        }
    }

    /// Every loaded page followed by its chapter's break, as one flat list of lazy
    /// rows. Separators are fixed-height so loading the next episode never changes
    /// the height of the content above the viewport.
    private var verticalItems: [ReaderVerticalItem] {
        sections.flatMap { section in
            section.pages.map {
                ReaderVerticalItem.page(chapterId: section.chapterId, page: $0)
            } + [.chapterBreak(chapterId: section.chapterId)]
        }
    }

    @ViewBuilder
    private func verticalItemView(
        _ item: ReaderVerticalItem,
        pageWidth: CGFloat,
        pageHeight: CGFloat
    ) -> some View {
        switch item {
        case let .page(chapterId, page):
            let id = ReaderPageID(chapterId: chapterId, pageIndex: page.index)
            AsyncPageImage(page: page, maxPixelSize: model.renderMaxPixelSize, contentMode: .fit)
                .frame(width: pageWidth, height: pageHeight)
                .id(id)
                .background {
                    GeometryReader { pageGeometry in
                        Color.clear.preference(
                            key: ReaderVerticalPageTopsKey.self,
                            value: [
                                id: pageGeometry
                                    .frame(in: .named("verticalReader"))
                                    .minY
                            ]
                        )
                    }
                }
        case let .chapterBreak(chapterId):
            if let section = sections.first(where: { $0.chapterId == chapterId }) {
                chapterBreak(after: section)
            }
        }
    }

    /// The page whose top edge most recently crossed the viewport's top edge. Only
    /// bookkeeping changes here; the model follows after the scroll pauses.
    private func trackVerticalPage(_ tops: [ReaderPageID: CGFloat]) {
        guard !isMagnifying,
              !isZoomSettling,
              !verticalScrollTracker.isRestoring,
              !tops.isEmpty
        else { return }

        let visible = tops
            .filter { $0.value <= 1 }
            .max { $0.value < $1.value }
            ?? tops.min { $0.value < $1.value }

        guard let id = visible?.key, id != verticalScrollTracker.topPageID else { return }
        verticalScrollTracker.topPageID = id
        scheduleTrackedVerticalPageApply()
    }

    /// A fallback for scroll widgets that do not report phases: if the page under the
    /// top edge stops changing for a moment, the model catches up even without an
    /// `idle` event.
    private func scheduleTrackedVerticalPageApply() {
        verticalScrollTracker.applyTask?.cancel()
        verticalScrollTracker.applyTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            applyTrackedVerticalPage()
        }
    }

    private func applyTrackedVerticalPage() {
        verticalScrollTracker.applyTask?.cancel()
        verticalScrollTracker.applyTask = nil

        guard !verticalScrollTracker.isUserScrolling,
              !verticalScrollTracker.isRestoring,
              !isMagnifying,
              !isZoomSettling,
              let id = verticalScrollTracker.topPageID,
              let section = sections.first(where: { $0.chapterId == id.chapterId }),
              let pagePosition = section.pages.firstIndex(where: { $0.index == id.pageIndex }),
              let chapterIndex = model.chapters.firstIndex(where: { $0.chapterId == id.chapterId })
        else { return }

        if id.chapterId == sections.last?.chapterId {
            loadNextSectionIfNeeded()
        }

        guard id.chapterId != model.chapter.chapterId
                || pagePosition != model.currentIndex
        else { return }

        // Moving forward through a break finishes the episode being left, even when
        // the gesture crossed it too fast for an idle page update.
        if chapterIndex > model.currentChapterIndex {
            for index in model.currentChapterIndex..<chapterIndex {
                model.markChapterRead(at: index)
            }
        }

        verticalScrollTracker.lastAppliedPageID = id
        verticalScrollTracker.isApplyingModelChange = true
        model.enterChapter(
            index: chapterIndex,
            pages: section.pages,
            pageIndex: pagePosition
        )
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            verticalScrollTracker.isApplyingModelChange = false
        }
    }

    /// Scrolls once the new page ids are in the view tree. Used for restores and
    /// explicit jumps, never for a page the user scrolled to.
    private func performPendingScroll(_ proxy: ScrollViewProxy) {
        guard let id = pendingScrollPageID else { return }
        pendingScrollPageID = nil
        // Geometry writes while the view is being repositioned are not page turns.
        verticalScrollTracker.applyTask?.cancel()
        verticalScrollTracker.isRestoring = true

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            // If another action moved the model while this was waiting, follow the
            // latest page instead of snapping back to the old request.
            if !verticalScrollTracker.isUserScrolling {
                let target = currentVerticalPageID ?? id
                proxy.scrollTo(target, anchor: .top)
            }
            try? await Task.sleep(for: .milliseconds(80))
            verticalScrollTracker.isRestoring = false
            verticalScrollTracker.isApplyingModelChange = false
        }
    }

    private var currentVerticalPageID: ReaderPageID? {
        guard model.pages.indices.contains(model.currentIndex) else { return nil }
        return ReaderPageID(
            chapterId: model.chapter.chapterId,
            pageIndex: model.pages[model.currentIndex].index
        )
    }

    /// Brings the stream in line with the model.
    ///
    /// A chapter loaded from outside the stream (the picker, a chapter shortcut, a
    /// retry) starts a new stream. A chapter the model entered by scrolling is already
    /// in `sections`, so this leaves every loaded page — and the scroll position — in
    /// place.
    private func syncSectionsFromModel() {
        guard !model.pages.isEmpty else { return }

        let chapterId = model.chapter.chapterId
        if let existing = sections.first(where: { $0.chapterId == chapterId }),
           existing.pages == model.pages {
            if viewOptions.layout == .vertical,
               !verticalScrollTracker.isUserScrolling,
               !verticalScrollTracker.isApplyingModelChange,
               let id = currentVerticalPageID,
               id != verticalScrollTracker.lastAppliedPageID {
                verticalScrollTracker.topPageID = id
                verticalScrollTracker.lastAppliedPageID = id
                verticalScrollTracker.isRestoring = true
                pendingScrollPageID = id
            }
            // Only extend the stream when the reader is at its growing end. Doing
            // this on every chapter change would load a new episode each time the
            // reader scrolled back and forth.
            if chapterId == sections.last?.chapterId {
                loadNextSectionIfNeeded()
            }
            return
        }

        sections = [
            ReaderSection(chapterId: chapterId, pages: model.pages)
        ]
        verticalScrollTracker.streamGeneration &+= 1
        verticalScrollTracker.isApplyingModelChange = false
        loadingSectionID = nil
        failedSectionID = nil

        if viewOptions.layout == .vertical, let id = currentVerticalPageID {
            verticalScrollTracker.topPageID = id
            verticalScrollTracker.lastAppliedPageID = id
            verticalScrollTracker.isRestoring = true
            pendingScrollPageID = id
        }
        loadNextSectionIfNeeded()
    }

    /// Loads one episode after the end of the stream. It is fetched as soon as the
    /// current chapter is in place, so the pages are already there by the time the
    /// reader scrolls across the break. When the reader actually enters that episode,
    /// the one after it starts loading.
    private func loadNextSectionIfNeeded() {
        guard loadingSectionID == nil,
              let last = sections.last,
              let lastChapterIndex = model.chapters.firstIndex(where: {
                  $0.chapterId == last.chapterId
              }),
              model.chapters.indices.contains(lastChapterIndex + 1)
        else { return }

        let nextChapter = model.chapters[lastChapterIndex + 1]
        guard failedSectionID != nextChapter.chapterId else { return }

        // A late result from a stream that has since been replaced is discarded.
        let generation = verticalScrollTracker.streamGeneration
        loadingSectionID = nextChapter.chapterId

        Task { @MainActor in
            // Resolve by id, not by the index captured above: fetching the chapter
            // list can renumber the list while this request is in flight.
            let pages = await model.loadPages(forChapterId: nextChapter.chapterId)
            guard generation == verticalScrollTracker.streamGeneration else { return }
            guard sections.last?.chapterId == last.chapterId else {
                loadingSectionID = nil
                return
            }

            if let pages, !pages.isEmpty {
                sections.append(
                    ReaderSection(chapterId: nextChapter.chapterId, pages: pages)
                )
                model.prefetchFirstPages(of: pages)
            } else {
                failedSectionID = nextChapter.chapterId
            }
            loadingSectionID = nil
        }
    }

    /// The visible boundary between episodes. Its height is fixed so a spinner, an
    /// error or the next chapter's title cannot change the document's height while
    /// the reader is moving through it.
    @ViewBuilder
    private func chapterBreak(after section: ReaderSection) -> some View {
        let sectionChapter = model.chapters.first { $0.chapterId == section.chapterId }
        let sectionIndex = sectionChapter.flatMap { chapter in
            model.chapters.firstIndex { $0.chapterId == chapter.chapterId }
        }
        let nextChapter = sectionIndex.flatMap { index in
            model.chapters.indices.contains(index + 1) ? model.chapters[index + 1] : nil
        }
        let isLoading = nextChapter.map { loadingSectionID == $0.chapterId } ?? false
        let failed = nextChapter.map { failedSectionID == $0.chapterId } ?? false

        VStack(spacing: 12) {
            Rectangle()
                .fill(.secondary.opacity(0.25))
                .frame(width: 56, height: 1)

            Text("END OF CHAPTER")
                .font(.caption2.weight(.semibold))
                .tracking(1.8)
                .foregroundStyle(.tertiary)

            Text(sectionChapter?.displayName ?? "Chapter")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if let nextChapter {
                VStack(spacing: 5) {
                    Text("NEXT CHAPTER")
                        .font(.caption2)
                        .tracking(1.4)
                        .foregroundStyle(.tertiary)
                    Text(nextChapter.displayName)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 10)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let externalURL = nextChapter.externalURL {
                    Link("Open on Source Site", destination: externalURL)
                        .font(.caption)
                } else if failed {
                    Button("Try Loading Again") {
                        failedSectionID = nil
                        loadNextSectionIfNeeded()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                }
            } else {
                Text("You're all caught up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.verticalChapterBreakHeight)
        .padding(.horizontal, 24)
    }

    /// Horizontal paging is the platform's scroll view with one custom decision about
    /// where a gesture comes to rest.
    ///
    /// Every spread is a page in a scrolling row, so the pages track the fingers the way
    /// the desktop swipe does — across as many of them as the gesture covers.
    /// `ReaderPagingBehavior` then settles on whichever page the fingers were nearest to
    /// rather than following the momentum, so a fast swipe lands where it was aimed
    /// instead of sailing past pages that were never read. Loaded chapters are laid out
    /// in the same row with a full-window break between them.
    private var horizontalReader: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(horizontalItems) { item in
                        horizontalItemView(item, size: size)
                            .frame(width: size.width, height: size.height)
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(ReaderPagingBehavior(pageWidth: size.width, offset: scrollOffset))
            .scrollPosition(id: $spreadPosition, anchor: .center)
            .scrollIndicators(.never)
            // Right to left reverses the axis, which is exactly what manga wants.
            .environment(\.layoutDirection, viewOptions.direction == .rightToLeft ? .rightToLeft : .leftToRight)
            // Where the fingers let go is only knowable here, so it is passed to the
            // behavior rather than left to the momentum the scroll view would project.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, offset in
                scrollOffset.value = offset
            }
            .onScrollPhaseChange { oldPhase, phase in
                verticalScrollTracker.isHorizontalScrolling = phase == .tracking
                    || phase == .interacting
                    || phase == .decelerating
                // Settle the model on exactly where the gesture stopped. While the
                // gesture is live the binding drives the model; nothing here moves
                // the scroll view.
                if oldPhase != .idle, phase == .idle {
                    handleHorizontalPosition(spreadPosition)
                }
            }
            .onAppear {
                verticalScrollTracker.isHorizontalScrolling = false
                syncHorizontalPosition(animated: false)
            }
            .onChange(of: spreadPosition) { _, newValue in
                handleHorizontalPosition(newValue)
            }
            .onChange(of: currentHorizontalItemID) { _, _ in
                syncHorizontalPosition(animated: spreadPosition != nil)
            }
            .onChange(of: viewOptions.pageMode) { _, _ in
                syncHorizontalPosition(animated: true)
            }
        }
    }

    /// Every spread of every loaded chapter, with the chapter break as its own
    /// full-window page. A LazyHStack of these is the horizontal stream.
    private var horizontalItems: [ReaderHorizontalItem] {
        var items: [ReaderHorizontalItem] = []
        for section in sections {
            let grids = ReaderSpreads.group(
                section.pages,
                pageMode: viewOptions.pageMode,
                firstPageAlone: settings.doublePageFirstPageAlone
            )
            for grid in grids {
                guard let first = grid.first else { continue }
                items.append(
                    ReaderHorizontalItem(
                        id: .page(
                            ReaderPageID(
                                chapterId: section.chapterId,
                                pageIndex: first.index
                            )
                        ),
                        chapterId: section.chapterId,
                        pages: grid,
                        isBreak: false
                    )
                )
            }
            items.append(
                ReaderHorizontalItem(
                    id: .chapterBreak(section.chapterId),
                    chapterId: section.chapterId,
                    pages: [],
                    isBreak: true
                )
            )
        }
        return items
    }

    @ViewBuilder
    private func horizontalItemView(_ item: ReaderHorizontalItem, size: CGSize) -> some View {
        if item.isBreak {
            if let section = sections.first(where: { $0.chapterId == item.chapterId }) {
                chapterBreak(after: section)
            }
        } else {
            spreadView(item.pages, size: size)
        }
    }

    /// The spread containing the model's current page, as an item identity.
    private var currentHorizontalItemID: ReaderStreamItemID? {
        guard let section = sections.first(where: {
            $0.chapterId == model.chapter.chapterId
        }) else { return nil }

        let grids = ReaderSpreads.group(
            section.pages,
            pageMode: viewOptions.pageMode,
            firstPageAlone: settings.doublePageFirstPageAlone
        )
        guard let index = ReaderSpreads.spreadIndex(showing: model.currentIndex, in: grids),
              let first = grids[index].first
        else { return nil }

        return .page(
            ReaderPageID(chapterId: section.chapterId, pageIndex: first.index)
        )
    }

    private func syncHorizontalPosition(animated: Bool) {
        guard !verticalScrollTracker.isHorizontalScrolling,
              let id = currentHorizontalItemID,
              id != spreadPosition
        else { return }
        if animated {
            withAnimation(ReaderView.pageTurnAnimation) {
                spreadPosition = id
            }
        } else {
            spreadPosition = id
        }
    }

    /// A horizontal gesture landed on a spread or a break. Breaks only exist to get
    /// the next episode fetching; spreads move the model to the chapter they belong
    /// to without touching the loaded sections or the scroll position.
    private func handleHorizontalPosition(_ id: ReaderStreamItemID?) {
        guard !isNativeFullScreenTransition,
              !isFullScreenAnimating,
              !isPageSyncSuppressed
        else { return }
        guard let id else { return }

        switch id {
        case let .chapterBreak(chapterId):
            if sections.last?.chapterId == chapterId {
                loadNextSectionIfNeeded()
            }
        case let .page(pageID):
            // A double-page spread is addressed by its first page. If the model is
            // already showing this spread, keep the exact page inside it (the saved
            // page may be the right-hand one).
            guard id != currentHorizontalItemID,
                  let section = sections.first(where: { $0.chapterId == pageID.chapterId }),
                  let pagePosition = section.pages.firstIndex(where: {
                      $0.index == pageID.pageIndex
                  }),
                  let chapterIndex = model.chapters.firstIndex(where: {
                      $0.chapterId == pageID.chapterId
                  })
            else { return }

            if pageID.chapterId != model.chapter.chapterId
                || pagePosition != model.currentIndex {
                // Moving forward off the final spread finishes the chapter being
                // left. A chapter-control jump from the middle is not a read.
                if chapterIndex > model.currentChapterIndex,
                   isCurrentChapterOnLastSpread {
                    for index in model.currentChapterIndex..<chapterIndex {
                        model.markChapterRead(at: index)
                    }
                }
                model.enterChapter(
                    index: chapterIndex,
                    pages: section.pages,
                    pageIndex: pagePosition
                )
                // Horizontal paging has always returned to fit on a page turn.
                model.resetZoom()
            }
        }
    }

    /// Whether the model's current page is anywhere in the chapter's final spread.
    private var isCurrentChapterOnLastSpread: Bool {
        let grids = ReaderSpreads.group(
            model.pages,
            pageMode: viewOptions.pageMode,
            firstPageAlone: settings.doublePageFirstPageAlone
        )
        guard let last = grids.last else { return false }
        return last.contains { $0.index == model.currentIndex }
    }

    /// Deliberate page turn: one spread, which is one page in single-page mode and a
    /// facing pair in double-page mode.
    private func turnSpread(_ direction: Int) {
        guard !isNativeFullScreenTransition,
              !isFullScreenAnimating,
              !isPageSyncSuppressed
        else { return }
        guard viewOptions.layout == .horizontal else {
            turnVerticalPage(direction)
            return
        }

        // A reading-order step, which right to left reverses.
        let step = viewOptions.direction == .rightToLeft ? -direction : direction
        let items = horizontalItems
        let start = items.firstIndex { $0.id == spreadPosition }
            ?? items.firstIndex { $0.id == currentHorizontalItemID }
        guard let start else { return }

        var index = start + step
        while items.indices.contains(index) {
            if !items[index].isBreak {
                withAnimation(ReaderView.pageTurnAnimation) {
                    spreadPosition = items[index].id
                }
                return
            }
            index += step
        }

        // At the end of the loaded stream, load the adjacent chapter. The step
        // already accounts for right-to-left, so use it rather than the arrow.
        step > 0 ? model.nextPage() : model.previousPage()
    }

    /// A keyboard page turn in the vertical stream. Inside a chapter this is an
    /// ordinary page change. At a boundary it walks into the loaded episode rather
    /// than reloading the chapter and dropping the stream.
    private func turnVerticalPage(_ direction: Int) {
        if direction > 0 {
            if model.currentIndex + 1 < model.pages.count {
                model.goToPage(model.currentIndex + 1)
            } else if let next = adjacentSection(direction: 1) {
                enterContinuousSection(next, page: 0)
            } else {
                model.nextPage()
            }
        } else {
            if model.currentIndex > 0 {
                model.goToPage(model.currentIndex - 1)
            } else if let previous = adjacentSection(direction: -1) {
                enterContinuousSection(previous, page: max(0, previous.pages.count - 1))
            } else {
                model.previousPage()
            }
        }
    }

    /// The loaded section for the chapter immediately before or after the current
    /// one, if it has been fetched.
    private func adjacentSection(direction: Int) -> ReaderSection? {
        let targetIndex = model.currentChapterIndex + direction
        guard model.chapters.indices.contains(targetIndex) else { return nil }
        let chapterId = model.chapters[targetIndex].chapterId
        return sections.first { $0.chapterId == chapterId }
    }

    /// Moves the model to an already-loaded episode and scrolls its first (or last)
    /// page into view. The scroll request, not a re-anchored scroll position, is what
    /// moves the viewport.
    private func enterContinuousSection(_ section: ReaderSection, page: Int) {
        guard !section.pages.isEmpty,
              let chapterIndex = model.chapters.firstIndex(where: {
                  $0.chapterId == section.chapterId
              })
        else { return }

        let index = min(max(0, page), section.pages.count - 1)
        let id = ReaderPageID(
            chapterId: section.chapterId,
            pageIndex: section.pages[index].index
        )

        verticalScrollTracker.topPageID = id
        verticalScrollTracker.lastAppliedPageID = id
        verticalScrollTracker.isRestoring = true
        verticalScrollTracker.isApplyingModelChange = true
        model.enterChapter(
            index: chapterIndex,
            pages: section.pages,
            pageIndex: index
        )
        pendingScrollPageID = id

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            verticalScrollTracker.isApplyingModelChange = false
        }
    }

    /// A chapter step from the controls or `[`/`]`. If the episode is already in the
    /// stream, walk to it; otherwise load it as a fresh stream.
    private func goToAdjacentChapter(_ direction: Int) {
        let targetIndex = model.currentChapterIndex + direction
        guard model.chapters.indices.contains(targetIndex) else { return }
        let targetChapterId = model.chapters[targetIndex].chapterId

        if let section = sections.first(where: { $0.chapterId == targetChapterId }) {
            if viewOptions.layout == .vertical {
                enterContinuousSection(
                    section,
                    page: direction > 0 ? 0 : max(0, section.pages.count - 1)
                )
            } else {
                goToSectionInHorizontal(section, atStart: direction > 0)
            }
        } else {
            Task { await model.goToChapter(index: targetIndex) }
        }
    }

    /// Jumps the horizontal scroll view to the first or last spread of a loaded
    /// chapter. The binding's change handler brings the model along.
    private func goToSectionInHorizontal(_ section: ReaderSection, atStart: Bool) {
        let grids = ReaderSpreads.group(
            section.pages,
            pageMode: viewOptions.pageMode,
            firstPageAlone: settings.doublePageFirstPageAlone
        )
        guard let pages = (atStart ? grids.first : grids.last),
              let first = pages.first
        else { return }

        withAnimation(ReaderView.pageTurnAnimation) {
            spreadPosition = .page(
                ReaderPageID(chapterId: section.chapterId, pageIndex: first.index)
            )
        }
    }

    private static let pageTurnAnimation: Animation = .spring(response: 0.35, dampingFraction: 0.9)

    /// The spread being read. A page that shares a spread with its neighbour has no
    /// spread starting at it, so fall back to the spread that contains it.
    private var currentSpreadIndex: Int {
        ReaderSpreads.spreadIndex(showing: model.currentIndex, in: spreads) ?? 0
    }

    @ViewBuilder
    private func spreadView(_ pages: [Page], size: CGSize) -> some View {
        if pages.count == 1 {
            AsyncPageImage(page: pages[0], maxPixelSize: model.renderMaxPixelSize, contentMode: .fit)
                .frame(width: size.width, height: size.height)
        } else {
            GeometryReader { inner in
                HStack(spacing: 0) {
                    ForEach(pages) { page in
                        AsyncPageImage(page: page, maxPixelSize: model.renderMaxPixelSize, contentMode: .fit)
                            .frame(width: inner.size.width / CGFloat(pages.count))
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// Pages grouped into single or double spreads.
    private var spreads: [[Page]] {
        ReaderSpreads.group(
            model.pages,
            pageMode: viewOptions.pageMode,
            firstPageAlone: settings.doublePageFirstPageAlone
        )
    }

    /// The vertical reader's pinch. Layout zoom changes every page's height, so the
    /// scroll view has to be moved by exactly the same amount or the stream appears to
    /// scroll under the fingers. The anchor records the item at the viewport's top and
    /// the fraction through it, which is accurate even across a fixed-height chapter
    /// break.
    private var verticalZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                var anchor = zoomAnchor
                if !isMagnifying {
                    isMagnifying = true
                    isZoomSettling = true
                    pendingZoomTargetY = nil
                    zoomSettleTask?.cancel()
                    // Safety net: page tracking eventually resumes even if the gesture
                    // ends without delivering its final event.
                    zoomSettleTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(10))
                        guard !Task.isCancelled else { return }
                        zoomPinTask?.cancel()
                        isZoomSettling = false
                        pendingZoomTargetY = nil
                    }
                    zoomPinTask?.cancel()
                    zoomPinTask = Task { @MainActor in
                        while !Task.isCancelled {
                            applyPendingZoomTarget()
                            try? await Task.sleep(for: .milliseconds(8))
                        }
                    }
                    zoomGestureBase = model.zoom
                    anchor = captureZoomAnchor(zoom: model.zoom)
                    zoomAnchor = anchor
                }
                model.setZoom(zoomGestureBase * value.magnification)
                if let anchor {
                    applyZoomAnchor(anchor)
                }
            }
            .onEnded { _ in
                if let anchor = zoomAnchor {
                    applyZoomAnchor(anchor, final: true)
                }
                zoomGestureBase = model.zoom
                zoomAnchor = nil
                isMagnifying = false
                zoomSettleTask?.cancel()
                zoomSettleTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled else { return }
                    // One last correction, then stop pinning the clip view.
                    applyPendingZoomTarget()
                    zoomPinTask?.cancel()
                    zoomPinTask = nil
                    isZoomSettling = false
                    pendingZoomTargetY = nil
                }
            }
    }

    private func capturedPageHeight(zoom: CGFloat, width: CGFloat) -> CGFloat {
        let aspect = min(max(verticalPageAspect ?? Self.typicalPageAspectRatio, 0.2), 5)
        return (width * zoom) / aspect
    }

    /// Finds the page or chapter break crossing the viewport's top edge, and how far
    /// into it that edge is.
    private func captureZoomAnchor(zoom: CGFloat) -> ReaderZoomAnchor? {
        guard let scrollView = verticalScrollView, !sections.isEmpty else { return nil }

        let clip = scrollView.contentView
        let pageHeight = capturedPageHeight(zoom: zoom, width: clip.bounds.width)
        guard pageHeight > 0 else { return nil }

        let breakHeight = Self.verticalChapterBreakHeight
        var remaining = max(0, clip.bounds.origin.y)

        for section in sections {
            let pagesHeight = pageHeight * CGFloat(section.pages.count)
            if remaining < pagesHeight {
                let rawIndex = Int(remaining / pageHeight)
                let index = min(max(rawIndex, 0), max(section.pages.count - 1, 0))
                guard section.pages.indices.contains(index) else { return nil }
                let top = CGFloat(index) * pageHeight
                return ReaderZoomAnchor(
                    position: .page(
                        chapterId: section.chapterId,
                        pageIndex: section.pages[index].index,
                        fraction: (remaining - top) / pageHeight
                    ),
                    zoom: zoom
                )
            }
            remaining -= pagesHeight

            if remaining < breakHeight {
                return ReaderZoomAnchor(
                    position: .chapterBreak(
                        chapterId: section.chapterId,
                        fraction: remaining / breakHeight
                    ),
                    zoom: zoom
                )
            }
            remaining -= breakHeight
        }

        return nil
    }

    /// Reconstructs the same anchor's document offset at a new zoom. Page heights
    /// scale with zoom; chapter-break heights do not.
    private func zoomAnchorOffset(
        _ anchor: ReaderZoomAnchor,
        zoom: CGFloat,
        width: CGFloat
    ) -> CGFloat? {
        let pageHeight = capturedPageHeight(zoom: zoom, width: width)
        guard pageHeight > 0 else { return nil }

        let breakHeight = Self.verticalChapterBreakHeight
        var offset: CGFloat = 0

        for section in sections {
            switch anchor.position {
            case let .page(chapterId, pageIndex, fraction):
                if section.chapterId == chapterId {
                    guard let index = section.pages.firstIndex(where: { $0.index == pageIndex }) else {
                        return offset
                    }
                    return offset + CGFloat(index) * pageHeight + fraction * pageHeight
                }
            case let .chapterBreak(chapterId, fraction):
                if section.chapterId == chapterId {
                    return offset + CGFloat(section.pages.count) * pageHeight + fraction * breakHeight
                }
            }

            offset += CGFloat(section.pages.count) * pageHeight + breakHeight
        }

        return nil
    }

    /// Applies the pending offset as soon as the scroll view reports its new content
    /// height. Doing this in the frame-change notification keeps the size and position
    /// changes in the same layout pass instead of letting the content slide first.
    private func applyPendingZoomTarget() {
        guard let targetY = pendingZoomTargetY,
              let scrollView = verticalScrollView
        else { return }

        let clip = scrollView.contentView
        let maxY = max(0, clip.documentRect.height - clip.bounds.height)
        // A zoom-in's target can temporarily sit past the old content height. Setting
        // it now would clamp to the bottom; wait for the document to grow instead.
        guard targetY <= maxY + 0.5 else { return }
        let target = max(0, targetY)
        guard abs(clip.bounds.origin.y - target) > 0.25 else { return }
        clip.setBoundsOrigin(
            NSPoint(x: clip.bounds.origin.x, y: target)
        )
        scrollView.reflectScrolledClipView(clip)
    }

    /// Schedules the anchored position for a new zoom. The document-frame observer
    /// normally applies it in the same layout pass as the page-height change; the
    /// timer passes are a fallback for geometry the observer cannot see.
    private func applyZoomAnchor(_ anchor: ReaderZoomAnchor, final: Bool = false) {
        guard let scrollView = verticalScrollView else { return }
        let width = scrollView.contentView.bounds.width
        guard width > 0,
              let targetY = zoomAnchorOffset(anchor, zoom: model.zoom, width: width)
        else { return }

        pendingZoomTargetY = targetY
        zoomApplyTask?.cancel()
        zoomApplyTask = Task { @MainActor in
            let delays: [Int] = final ? [16, 80] : [8]
            for delay in delays {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                applyPendingZoomTarget()
            }
        }
    }

    private var pageIndicator: some View {
        VStack {
            Spacer()
            if !model.pages.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        goToAdjacentChapter(-1)
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(!model.hasPreviousChapter)
                    .buttonStyle(.plain)

                    VStack(spacing: 4) {
                        Text("\(scrubPage + 1) / \(model.pages.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        progressBar
                    }
                    .frame(width: 260)
                    .overlay {
                        // A real slider does the tracking, over the whole block: a
                        // click lands where it is aimed (including on the page count)
                        // and a drag keeps going even when the pointer leaves the thin
                        // bar. It is invisible; the artwork underneath is the bar.
                        GeometryReader { geometry in
                            Slider(value: $scrubFraction, in: 0...1) { editing in
                                if editing {
                                    // Keep the controls (and this bar) on screen for the
                                    // whole drag.
                                    revealControls()
                                    isScrubbing = true
                                } else {
                                    let target = ReaderScrubbing.page(
                                        atFraction: scrubFraction,
                                        pageCount: model.pages.count
                                    )
                                    isScrubbing = false
                                    model.goToPage(target)
                                }
                            }
                            .labelsHidden()
                            .focusable(false)
                            .opacity(0.001)
                            // Clicking the track jumps there even on control styles
                            // that do not move the knob to the click themselves.
                            .simultaneousGesture(
                                SpatialTapGesture()
                                    .onEnded { value in
                                        let width = geometry.size.width
                                        guard width > 0 else { return }
                                        let fraction = min(max(0, value.location.x / width), 1)
                                        scrubFraction = fraction
                                        isScrubbing = false
                                        model.goToPage(
                                            ReaderScrubbing.page(
                                                atFraction: fraction,
                                                pageCount: model.pages.count
                                            )
                                        )
                                    }
                            )
                        }
                    }

                    Button {
                        goToAdjacentChapter(1)
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
        .onAppear { syncScrubberToCurrentPage() }
        .onChange(of: model.currentIndex) { _, _ in syncScrubberToCurrentPage() }
        .onChange(of: model.pages.count) { _, _ in syncScrubberToCurrentPage() }
    }

    /// Keeps the invisible slider's thumb on the page being read, so grabbing the
    /// scrubbing track starts from where the reader actually is.
    private func syncScrubberToCurrentPage() {
        guard !isScrubbing else { return }
        scrubFraction = ReaderScrubbing.fraction(
            ofPage: model.currentIndex,
            pageCount: model.pages.count
        )
    }

    /// The page the bar is reporting: the one a drag has reached, or the one being read.
    private var scrubPage: Int {
        guard isScrubbing else { return model.currentIndex }
        return ReaderScrubbing.page(atFraction: scrubFraction, pageCount: model.pages.count)
    }

    /// Progress through the chapter, draggable to jump. The page itself is only changed
    /// when the drag ends — scrubbing across a long chapter would otherwise ask for every
    /// page it passes over.
    private var progressBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = ReaderScrubbing.fraction(ofPage: scrubPage, pageCount: model.pages.count)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)
                Capsule()
                    .fill(.tint)
                    .frame(width: width * fraction, height: 4)
                Circle()
                    .fill(.tint)
                    .frame(width: 10, height: 10)
                    .offset(x: min(max(0, width * fraction - 5), max(0, width - 10)))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 20)
        .help("Drag to jump to a page")
    }

    // MARK: - Controls

    /// The reader's controls, sitting in a bar across the top of the page.
    ///
    /// An overlay rather than the window's toolbar. A title bar occupies a strip of its
    /// own, so hiding and showing it pushed the page up and down underneath it; drawn over
    /// the page means the controls can come and go without the reading position moving.
    private var controlBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                glassGroup {
                    closeControl
                    Divider()
                        .frame(height: 20)
                    chapterControls
                }
                // The clearance for the traffic lights is applied inside this group's frame
                // rather than around the whole row, so both ends stay the same width and the
                // title stays centred on the window. Full screen has no title bar, so the
                // empty space is dropped there.
                .padding(.leading, controlBarLeadingInset)
                .frame(maxWidth: .infinity, alignment: .leading)

                titleControl

                glassGroup {
                    bookmarkControl
                    displayControl
                    fullScreenControl
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        // Measure the bar itself, before the top padding that positions it. Including
        // that padding here would feed its own offset back into the height calculation
        // and leave the bar a few pixels above the traffic-light centre line.
        .onGeometryChange(for: CGFloat.self) { bar in
            bar.size.height
        } action: { height in
            controlBarHeight = height
        }
        .padding(.top, controlBarTopPadding)
        // A soft shadow lifts the floating bar off the page while the controls are up;
        // it fades away with them.
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    }

    /// Puts the control bar's centre line on the traffic lights' centre line, so the lights
    /// read as part of the bar rather than floating above it. Full screen has no title bar
    /// to line up with, so the bar falls back to its own inset there.
    private var controlBarTopPadding: CGFloat {
        guard !isNativeFullScreen,
              let centre = trafficLightCentre,
              controlBarHeight > 0
        else { return 8 }
        return max(0, centre - controlBarHeight / 2)
    }

    /// How far the control bar steps in from the left edge to clear the traffic lights.
    /// Full screen has no title bar of its own, so there is nothing to clear there.
    private var controlBarLeadingInset: CGFloat {
        isReaderFullScreen || isNativeFullScreen ? 0 : trafficLightSpan
    }

    /// The height of the display's camera housing, or zero when the display has none.
    /// Only a notched Mac reserves space at the top of the screen, so its auxiliary
    /// areas being present is what distinguishes it from an ordinary display.
    private var notchInset: CGFloat {
        guard let screen = window?.screen,
              screen.auxiliaryTopLeftArea != nil
        else { return 0 }
        return screen.safeAreaInsets.top
    }

    /// Puts a run of controls on one piece of glass, the way a toolbar groups them.
    private func glassGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .font(.system(size: 18))
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .glassEffect()
    }

    private var closeControl: some View {
        Button {
            model.flushProgress()
            dismiss()
        } label: {
            Label("Close", systemImage: "xmark")
        }
        .help("Close")
    }

    @ViewBuilder
    private var chapterControls: some View {
        Button {
            goToAdjacentChapter(-1)
        } label: {
            Label("Previous Chapter", systemImage: "chevron.left")
        }
        .disabled(!model.hasPreviousChapter)
        .help("Previous chapter")

        Button {
            showChapterPicker = true
        } label: {
            Label("Chapters", systemImage: "list.bullet")
        }
        .help("Chapters")

        Button {
            goToAdjacentChapter(1)
        } label: {
            Label("Next Chapter", systemImage: "chevron.right")
        }
        .disabled(!model.hasNextChapter)
        .help("Next chapter")
    }

    private var titleControl: some View {
        VStack(spacing: 0) {
            Text(model.chapterLabel)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(model.manga.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassEffect()
        // The camera housing sits over the middle of the screen and only in full
        // screen, native or the reader's own; the rest of the bar is beside it, so the
        // title alone steps down out of the notch. Displays without one are left alone.
        .offset(y: (isReaderFullScreen || isNativeFullScreen) ? notchInset : 0)
    }

    private var bookmarkControl: some View {
        Button {
            model.toggleBookmark()
        } label: {
            Label(
                model.isCurrentPageBookmarked ? "Remove Bookmark" : "Bookmark Page",
                systemImage: model.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark"
            )
        }
        .disabled(model.pages.isEmpty)
        .help("Bookmark this page")
    }

    private var displayControl: some View {
        Button {
            showsDisplayOptions = true
        } label: {
            Label("Display", systemImage: "slider.horizontal.3")
        }
        .popover(isPresented: $showsDisplayOptions, arrowEdge: .top) {
            PerMangaViewOptionsPopover(
                options: viewOptions,
                mangaTitle: model.manga.title,
                onZoomIn: { model.zoomIn() },
                onZoomOut: { model.zoomOut() },
                onResetZoom: { model.resetZoom() },
                onMarkRead: { model.markCurrentChapterRead() },
                onMarkUnread: { model.markCurrentChapterUnread() }
            )
        }
        .help("Per manga view options")
    }

    private var fullScreenControl: some View {
        let isFullScreen = isReaderFullScreen || isNativeFullScreen

        return Button {
            toggleFullScreen()
        } label: {
            Label(
                isFullScreen ? "Exit Full Screen" : "Full Screen",
                systemImage: isFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            )
        }
        .help(
            isFullScreen
                ? "Exit full screen (F)"
                : "Full screen (F) — the green button uses native full screen"
        )
    }

    private func toggleFullScreen() {
        guard let window, !isNativeFullScreenTransition else { return }

        // In native full screen, F and the control-bar button leave it the same way
        // the green button does. AppKit owns this transition; the reader's own
        // screen-filling mode is only used from an ordinary window.
        if isNativeFullScreen || window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }

        guard !isFullScreenAnimating else { return }

        if isReaderFullScreen {
            exitReaderFullScreen(window)
        } else {
            enterReaderFullScreen(window)
        }
    }

    /// Makes the reader window borderless: no title bar of its own, and the page drawn from
    /// the very top edge with the traffic lights floating over it.
    ///
    /// `.windowStyle(.hiddenTitleBar)` hides the title but still reserves the title bar's
    /// height, which is what left a bar across the top of the window. `fullSizeContentView`
    /// is what lets the content into that space.
    private func makeBorderless(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none

        // Native full screen stays available: the green button and the View menu use it.
        // The reader leaves the transition entirely to AppKit — nothing here or in the
        // notification handlers touches the window until it is windowed again.
        window.collectionBehavior.insert(.fullScreenPrimary)

        // The reader is one window per chapter; never fold windows into tabs. A tab
        // bar would otherwise come down together with the title bar in native full
        // screen, where only the traffic lights should appear.
        window.tabbingMode = .disallowed

        // An empty unified toolbar is what gives the traffic lights their ordinary
        // spacing away from the top-left corner; a toolbar-less window tucks them into
        // the corner. Nothing is drawn in it — the title bar is transparent and the
        // separator is off — it only owns the lights' layout.
        if window.toolbar == nil {
            window.toolbarStyle = .unified
            window.toolbar = NSToolbar(identifier: "AzumangaReaderToolbar")
        }

        applyTrafficLightShadow(in: window)

        reconcileWindow(window)
    }

    /// Gives the traffic lights the same soft drop shadow as the floating controls.
    private func applyTrafficLightShadow(in window: NSWindow) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 5

        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            // The offset follows the button's own coordinate space; standard controls
            // are not flipped, so a negative height casts the shadow downwards.
            shadow.shadowOffset = NSSize(width: 0, height: button.isFlipped ? 2 : -2)
            button.wantsLayer = true
            button.shadow = shadow
        }
    }

    /// Records where the traffic lights sit, so the control bar can clear them and put its
    /// own centre line on theirs.
    private func measureTrafficLights(in window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }

        guard let close = buttons.first, let last = buttons.last else {
            trafficLightCentre = nil
            trafficLightSpan = 0
            return
        }

        // A screen-filling window has its title bar hidden with the rest of the system
        // chrome, so there is no centre line to line up with and no room to clear.
        guard !isReaderFullScreen else {
            trafficLightCentre = nil
            trafficLightSpan = 0
            return
        }

        trafficLightCentre = window.frame.height - close.convert(close.bounds, to: nil).midY
        trafficLightSpan = last.convert(last.bounds, to: nil).maxX + 10
    }

    /// The traffic lights go away with the rest of the controls, so a reader with the
    /// controls put away has nothing on screen but the page. Hidden rather than faded, so
    /// they cannot be clicked while they cannot be seen. They are always gone while the
    /// reader fills the screen, where they would otherwise float over the page.
    private func applyTrafficLightVisibility(in window: NSWindow) {
        let hidden = isReaderFullScreen || !controlsVisible
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = hidden
        }
        // Exclusive full screen disables the native green button even if the system
        // briefly reveals the toolbar; native full screen is not allowed to start on
        // top of the custom mode.
        window.standardWindowButton(.zoomButton)?.isEnabled = !isReaderFullScreen
    }

    /// Puts the window chrome back in step with the reader: the traffic lights, the room
    /// they take, and the window's shape. Every window mutation goes through here.
    private func reconcileWindow(_ window: NSWindow, resizingWindowShape: Bool = false) {
        guard !isNativeFullScreen, !isNativeFullScreenTransition else { return }
        measureTrafficLights(in: window)
        applyTrafficLightVisibility(in: window)
        applyWindowShape(resizing: resizingWindowShape)
    }

    /// The window's shape in the current reading mode, or `nil` when it is free.
    ///
    /// Vertical scrolling reads at any window width, so the window stays freely
    /// resizable. Horizontal reading is locked to exactly what it shows: one page, or
    /// two side by side. Without the single-page lock the window keeps its old shape
    /// and the page sits between bars.
    private var windowAspectRatio: CGFloat? {
        guard viewOptions.layout == .horizontal else { return nil }
        let page = episodePageAspect ?? Self.typicalPageAspectRatio
        return page * typicalSpreadPageCount
    }

    /// The page count of a normal spread in this episode. In double-page mode a lone
    /// first or last page must not flip the window back to a single-page shape, so the
    /// window follows the episode's usual spread rather than the current one.
    private var typicalSpreadPageCount: CGFloat {
        guard viewOptions.pageMode == .double else { return 1 }
        // Before the page list arrives, Classic is more likely to become a normal
        // two-page spread than a single-page chapter. Starting there avoids an extra
        // resize when the first spread loads; the sampler corrects one-page chapters.
        guard !spreads.isEmpty else { return 2 }
        return spreads.contains { $0.count > 1 } ? 2 : 1
    }

    /// Keeps the window delegate's native edge-resize lock in step with the mode and
    /// the spread currently on screen. Vertical mode and both full-screen modes leave
    /// the border free.
    private func updateWindowResizeLock() {
        let ratio = windowAspectRatio
        let enabled = ratio != nil
            && !isReaderFullScreen
            && !isNativeFullScreen
            && !isNativeFullScreenTransition
        windowResizeDelegate.aspectRatio = enabled ? ratio : nil
        windowResizeDelegate.isEnabled = enabled
    }

    /// Maps the resize anchor to the current page-width layout and moves the clip
    /// view there. While the live resize is in progress, the pin task repeats this
    /// so page-height changes and the scroll offset stay together.
    private func applyResizeAnchor() {
        guard viewOptions.layout == .vertical,
              let anchor = resizeAnchor,
              let scrollView = verticalScrollView
        else { return }

        let clip = scrollView.contentView
        let width = clip.bounds.width
        guard width > 0,
              let targetY = zoomAnchorOffset(anchor, zoom: model.zoom, width: width)
        else { return }

        let maxY = max(0, clip.documentRect.height - clip.bounds.height)
        guard targetY <= maxY + 0.5 else { return }

        let target = max(0, targetY)
        guard abs(clip.bounds.origin.y - target) > 0.25 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    /// A page's width over its height, read from a page of the current spread that has
    /// loaded. Proportions differ between series, so this is measured rather than assumed
    /// wherever one is available.
    private func readPageAspect() async {
        let grid = spreads
        guard grid.indices.contains(currentSpreadIndex) else {
            pageAspect = nil
            return
        }

        let maxPixelSize = model.renderMaxPixelSize
        for page in grid[currentSpreadIndex] {
            guard let image = await images.cachedImage(for: page.url, maxPixelSize: maxPixelSize),
                  image.height > 0
            else { continue }
            let aspect = CGFloat(image.width) / CGFloat(image.height)
            pageAspect = aspect
            // The vertical stack's slot shape is chosen once and then kept. Letting it
            // follow the current page would resize every page in the chapter mid-read.
            if verticalPageAspect == nil {
                verticalPageAspect = aspect
            }
            return
        }
        pageAspect = nil
    }

    /// Starts (or restarts) the one-time sample that decides the episode's page shape.
    /// The result is kept for the whole chapter; turning pages never reshapes the
    /// window again.
    private func beginEpisodeShapeSampling(force: Bool = false) {
        let chapterId = model.chapter.chapterId

        if force || episodeAspectChapterId != chapterId {
            episodeShapeTask?.cancel()
            episodeShapeTask = nil
            episodeAspectChapterId = chapterId
            episodePageAspect = nil
            episodeAspectLocked = false
        }

        guard viewOptions.layout == .horizontal,
              !episodeAspectLocked,
              !model.pages.isEmpty
        else { return }

        episodeShapeTask?.cancel()
        episodeShapeTask = Task { @MainActor in
            await sampleEpisodePageAspect(chapterId: chapterId)
        }
    }

    /// Waits briefly for a few pages to be decoded, then takes the median of their
    /// shapes. Waiting for cached images means this analysis costs no extra downloads.
    private func sampleEpisodePageAspect(chapterId: String) async {
        var samples: [Int: CGFloat] = [:]

        for _ in 0..<20 {
            // Let a chapter transition finish clearing the old page array before
            // measuring anything.
            try? await Task.sleep(for: .milliseconds(150))

            guard !Task.isCancelled,
                  episodeAspectChapterId == chapterId,
                  !episodeAspectLocked,
                  viewOptions.layout == .horizontal
            else { return }

            let pages = model.pages
            guard !pages.isEmpty else { continue }

            let indices = episodeSampleIndices(
                count: pages.count,
                current: model.currentIndex,
                limit: 5
            )
            for index in indices where samples[index] == nil {
                guard let image = await images.cachedImage(
                    for: pages[index].url,
                    maxPixelSize: model.renderMaxPixelSize
                ), image.height > 0 else { continue }
                samples[index] = CGFloat(image.width) / CGFloat(image.height)
            }

            if samples.count >= min(3, pages.count) {
                break
            }
        }

        guard !Task.isCancelled,
              episodeAspectChapterId == chapterId,
              !episodeAspectLocked,
              viewOptions.layout == .horizontal,
              !model.pages.isEmpty
        else { return }

        let pages = model.pages
        let required = min(3, pages.count)
        episodePageAspect = samples.count >= required
            ? Self.median(Array(samples.values))
            : nil
        episodeAspectLocked = true
        episodeShapeTask = nil

        if let window, !isResizingWindow {
            reconcileWindow(window, resizingWindowShape: true)
        }
        updateWindowResizeLock()
    }

    /// Up to `limit` distinct pages around the current one. Keeping the sample near
    /// the reader avoids pulling unrelated pages into memory just to measure them.
    private func episodeSampleIndices(count: Int, current: Int, limit: Int) -> [Int] {
        guard count > 0 else { return [] }
        var indices: [Int] = []
        func add(_ index: Int) {
            guard index >= 0, index < count, !indices.contains(index) else { return }
            indices.append(index)
        }

        add(current)
        var distance = 1
        while indices.count < limit, distance < count {
            add(current + distance)
            add(current - distance)
            distance += 1
        }
        return Array(indices.prefix(limit))
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Stand-in proportions, used until a page has loaded.
    private static let typicalPageAspectRatio: CGFloat = 2.0 / 3.0
    /// Fixed height of the separator between loaded chapters. The vertical zoom
    /// anchor needs the same value the layout uses.
    private static let verticalChapterBreakHeight: CGFloat = 230

    /// Shapes the window to the pages it is showing, so a spread or a single page fills
    /// it instead of being letterboxed inside it.
    ///
    /// AppKit's `contentAspectRatio` is deliberately not used: setting it — even back
    /// to zero to release it — makes window resizing produce NaN frames on macOS
    /// 26/27 and crashes on the next resize or window-centering action. The resize
    /// grip enforces the same ratio while the user drags it.
    ///
    /// `resizing` also resizes the window to take the shape on. That is only safe once the
    /// window is settled, so the full screen transitions never ask for it — resizing the
    /// window while it is coming out of full screen hangs it, and a ratio that changed while
    /// it was away is not a reason to do it then.
    private func applyWindowShape(resizing: Bool = false) {
        guard let window else { return }
        // The screen-filling window is not shaped to the page; the lock is dropped on
        // entry and re-applied when the window is back at its windowed size.
        guard !isReaderFullScreen, !window.styleMask.contains(.fullScreen) else { return }

        guard let ratio = windowAspectRatio else {
            appliedAspectRatio = 0
            releaseStuckSizeLimit(in: window)
            return
        }

        // Take the shape on when it is first applied or whenever the pages' proportions turn
        // out to be different, keeping the width.
        guard resizing, ratio != appliedAspectRatio else { return }
        appliedAspectRatio = ratio

        // The window content runs under the transparent titlebar and fills the frame,
        // which is also the rectangle the border-resize lock and the grip use.
        let frame = window.frame
        guard frame.width > 0 else { return }
        let height = (frame.width / ratio).rounded()
        window.setFrame(
            NSRect(
                x: frame.minX,
                y: frame.maxY - height,
                width: frame.width,
                height: height
            ),
            display: true
        )
    }

    /// A reader that is not filling the screen must always be resizable. If a
    /// screen-filling pass left the window's limits pinned to the display, put
    /// ordinary limits back.
    private func releaseStuckSizeLimit(in window: NSWindow) {
        guard let screenSize = (window.screen ?? NSScreen.main)?.frame.size,
              window.minSize == screenSize,
              window.maxSize == screenSize
        else { return }

        window.minSize = .zero
        window.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }
}

/// Mutable custom-full-screen bookkeeping. A reference keeps the animation completion
/// reading the current generation rather than a captured value.
private final class ReaderFullScreenState {
    var generation = 0
}

/// Temporarily raises the window above AppKit's normal frame constraint.
///
/// A titled `NSWindow` is clamped to the screen's visible frame, which stops it
/// below the menu bar and leaves the camera-housing strip uncovered. AppKit's
/// constrained method is replaced on the window's class — not the window's `isa` —
/// and only the active custom-full-screen window is allowed through. Changing a
/// window's class breaks the KVO registrations AppKit's titlebar uses, which made
/// the native full-screen transition throw and hang; a method-level replacement
/// leaves the window's identity and observers intact.
@MainActor
private enum ReaderFullScreenWindow {
    private static let selector = #selector(NSWindow.constrainFrameRect(_:to:))
    private static var swizzledClasses = Set<ObjectIdentifier>()
    private static let activeWindows = NSHashTable<NSWindow>.weakObjects()

    static func enter(_ window: NSWindow) {
        let windowClass: AnyClass = type(of: window)
        let key = ObjectIdentifier(windowClass)

        if !swizzledClasses.contains(key),
           let method = class_getInstanceMethod(windowClass, selector),
           let types = method_getTypeEncoding(method) {
            let originalImplementation = method_getImplementation(method)

            let block: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { window, frame, screen in
                let allowed = Thread.isMainThread
                    ? MainActor.assumeIsolated { activeWindows.contains(window) }
                    : false
                if allowed {
                    return frame
                }
                typealias ConstrainFunction = @convention(c) (NSWindow, Selector, NSRect, NSScreen?) -> NSRect
                let original = unsafeBitCast(originalImplementation, to: ConstrainFunction.self)
                return original(window, selector, frame, screen)
            }

            let implementation = imp_implementationWithBlock(block)
            class_replaceMethod(windowClass, selector, implementation, types)
            swizzledClasses.insert(key)
        }

        activeWindows.add(window)
    }

    static func exit(_ window: NSWindow) {
        activeWindows.remove(window)
    }
}

/// Enforces the current page/spread shape while the user drags any native window
/// border or corner. It sits in front of SwiftUI's own window delegate and forwards
/// every other delegate message there, so full screen, closing and chrome continue to
/// behave normally.
private final class ReaderWindowResizeDelegate: NSObject, NSWindowDelegate {
    private enum ResizeAxis {
        case horizontal
        case vertical
        case corner
    }

    private weak var window: NSWindow?
    private var originalDelegate: (any NSWindowDelegate)?
    private var liveResizeAxis: ResizeAxis = .corner
    var aspectRatio: CGFloat?
    var isEnabled = false

    func attach(to window: NSWindow) {
        if self.window === window, window.delegate === self { return }
        detach()
        self.window = window
        if window.delegate !== self {
            originalDelegate = window.delegate
            window.delegate = self
        }
    }

    func detach() {
        if let window, window.delegate === self {
            window.delegate = originalDelegate
        }
        window = nil
        originalDelegate = nil
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        if let originalDelegate,
           originalDelegate.responds(to: #selector(NSWindowDelegate.windowWillStartLiveResize(_:))) {
            originalDelegate.windowWillStartLiveResize?(notification)
        }

        guard let window else {
            liveResizeAxis = .corner
            return
        }

        // Decide once, from the edge the pointer grabbed. Re-deciding on every
        // resize event is what made a diagonal drag flip between the horizontal and
        // vertical result.
        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        let edge: CGFloat = 12
        let nearVerticalEdge = abs(mouse.x - frame.minX) <= edge
            || abs(mouse.x - frame.maxX) <= edge
        let nearHorizontalEdge = abs(mouse.y - frame.minY) <= edge
            || abs(mouse.y - frame.maxY) <= edge

        if nearVerticalEdge && nearHorizontalEdge {
            liveResizeAxis = .corner
        } else if nearVerticalEdge {
            liveResizeAxis = .horizontal
        } else if nearHorizontalEdge {
            liveResizeAxis = .vertical
        } else {
            liveResizeAxis = .corner
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        liveResizeAxis = .corner
        if let originalDelegate,
           originalDelegate.responds(to: #selector(NSWindowDelegate.windowDidEndLiveResize(_:))) {
            originalDelegate.windowDidEndLiveResize?(notification)
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard isEnabled,
              let aspectRatio,
              aspectRatio.isFinite,
              aspectRatio > 0,
              sender === window,
              !sender.styleMask.contains(.fullScreen)
        else { return frameSize }

        // Let SwiftUI's delegate have the first say if it implements this method.
        var proposed = frameSize
        if let originalDelegate,
           originalDelegate.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))),
           let original = originalDelegate.windowWillResize?(sender, to: proposed) {
            proposed = original
        }
        guard proposed.width > 0, proposed.height > 0 else { return proposed }

        let targetWidth: CGFloat
        let targetHeight: CGFloat
        switch liveResizeAxis {
        case .horizontal:
            targetWidth = proposed.width
            targetHeight = proposed.width / aspectRatio
        case .vertical:
            targetHeight = proposed.height
            targetWidth = proposed.height * aspectRatio
        case .corner:
            // Project the proposed corner onto the aspect-ratio line: average the
            // width implied by the horizontal movement and the width implied by the
            // vertical movement. The result follows the pointer's diagonal smoothly
            // instead of switching between the two axes.
            let widthFromHorizontal = proposed.width
            let widthFromVertical = proposed.height * aspectRatio
            targetWidth = (widthFromHorizontal + widthFromVertical) / 2
            targetHeight = targetWidth / aspectRatio
        }

        // Keep the reader usable at very small sizes without letting the minimum
        // clamp break the ratio.
        let scale = max(
            1,
            420 / targetWidth,
            260 / targetHeight
        )
        return NSSize(
            width: targetWidth * scale,
            height: targetHeight * scale
        )
    }

    /// Double-clicking the title bar (or pressing zoom) must not turn a page-shaped
    /// reader into the screen's shape. Give AppKit a zoom frame that already has the
    /// episode's aspect ratio.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard isEnabled,
              let aspectRatio,
              aspectRatio.isFinite,
              aspectRatio > 0
        else {
            if let originalDelegate,
               originalDelegate.responds(to: #selector(NSWindowDelegate.windowWillUseStandardFrame(_:defaultFrame:))) {
                return originalDelegate.windowWillUseStandardFrame?(window, defaultFrame: newFrame) ?? newFrame
            }
            return newFrame
        }

        var width = newFrame.width
        var height = width / aspectRatio
        if height > newFrame.height {
            height = newFrame.height
            width = height * aspectRatio
        }

        return NSRect(
            x: newFrame.midX - width / 2,
            y: newFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if originalDelegate?.responds(to: aSelector) == true { return originalDelegate }
        return super.forwardingTarget(for: aSelector)
    }
}

/// A corner grip that resizes the reader window.
///
/// The resize is driven straight from AppKit mouse events and screen coordinates.
/// A SwiftUI drag re-renders the view on every update, which makes the window lag
/// behind the pointer; AppKit tracking keeps the corner exactly under the cursor.
/// Locked reading modes keep their aspect ratio.
private struct ReaderResizeGrip: NSViewRepresentable {
    let window: NSWindow
    let aspectRatio: CGFloat?
    let onBegan: () -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: GripView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: GripView) {
        view.targetWindow = window
        view.aspectRatio = aspectRatio
        view.onBegan = onBegan
        view.onEnded = onEnded
    }

    final class GripView: NSView {
        var targetWindow: NSWindow?
        var aspectRatio: CGFloat?
        var onBegan: (() -> Void)?
        var onEnded: (() -> Void)?

        private var startFrame: NSRect?
        private var startMouse: NSPoint?
        private var didDrag = false
        private let symbolView = NSImageView()

        private static let minimumSize = NSSize(width: 420, height: 260)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.22).cgColor
            layer?.cornerRadius = 11

            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            symbolView.image = NSImage(
                systemSymbolName: "arrow.down.right",
                accessibilityDescription: "Resize"
            )?.withSymbolConfiguration(configuration)
            symbolView.contentTintColor = .secondaryLabelColor
            symbolView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(symbolView)
            NSLayoutConstraint.activate([
                symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
                symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func resetCursorRects() {
            addCursorRect(
                bounds,
                cursor: .frameResize(position: .bottomRight, directions: .all)
            )
        }

        override func mouseDown(with event: NSEvent) {
            startFrame = targetWindow?.frame
            startMouse = NSEvent.mouseLocation
            didDrag = false
            onBegan?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window = targetWindow,
                  let start = startFrame,
                  let anchor = startMouse
            else { return }

            didDrag = true
            let location = NSEvent.mouseLocation
            let dx = location.x - anchor.x
            let dy = location.y - anchor.y

            // Dragging right grows the window; dragging down grows it while the top
            // edge stays put (AppKit screen coordinates grow upwards).
            var width = start.width + dx
            var height = start.height - dy

            if let aspectRatio {
                let fromWidth = start.width + dx
                let fromHeight = (start.height - dy) * aspectRatio
                width = max(fromWidth, fromHeight)
                height = width / aspectRatio
            }

            width = max(width, Self.minimumSize.width)
            height = max(height, Self.minimumSize.height)
            if let aspectRatio {
                width = max(width, Self.minimumSize.height * aspectRatio)
                height = width / aspectRatio
            }

            window.setFrame(
                NSRect(
                    x: start.minX,
                    y: start.maxY - height,
                    width: width,
                    height: height
                ),
                display: false
            )
        }

        override func mouseUp(with event: NSEvent) {
            if didDrag, let window = targetWindow {
                window.setFrame(window.frame, display: true)
            }
            startFrame = nil
            startMouse = nil
            didDrag = false
            onEnded?()
        }
    }
}

/// Vertical reader page tracking that does not invalidate the view when it changes.
private final class ReaderVerticalScrollTracker {
    var topPageID: ReaderPageID?
    var lastAppliedPageID: ReaderPageID?
    var isUserScrolling = false
    /// True while the horizontal pager is tracking the user's fingers.
    var isHorizontalScrolling = false
    /// True while the model is being moved across a chapter boundary by scrolling,
    /// so the resulting page change is not mistaken for an explicit jump.
    var isApplyingModelChange = false
    /// True while the scroll view is being moved to a requested page by the reader,
    /// so the pages passing under the viewport are not mistaken for user scrolling.
    var isRestoring = false
    /// Identifies the current stream. A late page fetch from a stream that has been
    /// replaced is discarded rather than appended to the new one.
    var streamGeneration = 0
    var applyTask: Task<Void, Never>?
}

/// The top edge of every realized page in the vertical reader, in the scroll view's
/// coordinate space.
private struct ReaderVerticalPageTopsKey: PreferenceKey {
    static var defaultValue: [ReaderPageID: CGFloat] = [:]

    static func reduce(value: inout [ReaderPageID: CGFloat], nextValue: () -> [ReaderPageID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Identity of a page in the reading stream. Chapters are identified by their stable
/// id rather than their position in the chapter list, so a chapter list that arrives
/// after the reader opens can never renumber pages that are already on screen.
private struct ReaderPageID: Hashable {
    let chapterId: String
    let pageIndex: Int
}

/// Identity of any view in the stream: a page/spread or the break after a chapter.
/// Used by the horizontal scroll position as well as the vertical page tracking.
private enum ReaderStreamItemID: Hashable {
    case page(ReaderPageID)
    case chapterBreak(String)
}

/// One chapter loaded into the continuous stream.
private struct ReaderSection: Identifiable {
    let chapterId: String
    let pages: [Page]

    var id: String { chapterId }
}

/// A lazy row in the vertical stream: one page, or the break after a chapter.
private enum ReaderVerticalItem: Identifiable {
    case page(chapterId: String, page: Page)
    case chapterBreak(chapterId: String)

    var id: ReaderStreamItemID {
        switch self {
        case let .page(chapterId, page):
            .page(ReaderPageID(chapterId: chapterId, pageIndex: page.index))
        case let .chapterBreak(chapterId):
            .chapterBreak(chapterId)
        }
    }
}

/// One full-window item in the horizontal stream: a spread, or the break after a
/// chapter.
private struct ReaderHorizontalItem: Identifiable {
    let id: ReaderStreamItemID
    let chapterId: String
    let pages: [Page]
    let isBreak: Bool
}

/// The page or chapter break at the viewport's top edge when a webtoon pinch
/// began, plus the fraction through it and the zoom it was captured at. The page
/// layout is deterministic, so this can be mapped exactly to a new scroll offset
/// when the zoom changes.
private struct ReaderZoomAnchor {
    enum Position {
        case page(chapterId: String, pageIndex: Int, fraction: CGFloat)
        case chapterBreak(chapterId: String, fraction: CGFloat)
    }

    let position: Position
    let zoom: CGFloat
}

/// Reports the `NSScrollView` backing a SwiftUI `ScrollView`, so the reader can turn
/// on the platform's native magnification.
private struct ScrollViewAccessor: NSViewRepresentable {
    @Binding var scrollView: NSScrollView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor in scrollView = view.enclosingScrollView }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            if scrollView !== nsView.enclosingScrollView {
                scrollView = nsView.enclosingScrollView
            }
        }
    }
}

/// Reports the window hosting the view, so the reader controls its own window rather
/// than whichever one happens to be key.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor in window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            if window !== nsView.window { window = nsView.window }
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
