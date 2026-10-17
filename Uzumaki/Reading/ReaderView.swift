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
///
/// The window itself is managed by the scene (`.windowStyle(.hiddenTitleBar)` in
/// `UzumakiApp.swift`). Full screen is available two ways: AppKit's native full screen
/// (green button, View menu) and the reader's own screen-filling mode (`F`), which does
/// not use the native transition at all. Window chrome (traffic lights, page shape) is
/// only applied from `reconcileWindow`.
struct ReaderView: View {
    @Bindable var model: ReaderModel

    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.imagePipeline) private var images

    @State private var showChapterPicker = false
    /// The window hosting the reader, used to drive full screen and measure traffic lights.
    @State private var window: NSWindow?
    /// Whether the reader is filling the screen in its own windowed mode. The reader
    /// keeps this alongside AppKit's native full screen; the two never overlap.
    @State private var isReaderFullScreen = false
    /// Whether AppKit's own full screen is active.
    @State private var isNativeFullScreen = false
    /// Whether AppKit is mid-transition into or out of native full screen. Window chrome
    /// is left alone for the whole transition.
    @State private var isNativeFullScreenTransition = false
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
    /// The spread on screen, as the id of its first page. Two-way bound to the scroll
    /// view, so a gesture reports where it landed and a keyboard turn can drive it back.
    @State private var spreadPosition: Int?
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
    /// Whether a pinch is in flight. While the pages change size under the scroll
    /// view, its intermediate positions must not be treated as page turns.
    @State private var isMagnifying = false
    /// The zoom the current pinch started from, so repeated pinches accumulate.
    @State private var zoomGestureBase: CGFloat = 1
    /// The point under the pointer when a pinch starts, used to keep it there.
    @State private var zoomAnchor: ReaderZoomAnchor?
    /// Whether the corner grip is driving the window size. The controls must stay
    /// visible while it is.
    @State private var isResizingWindow = false
    @State private var scrubFraction: CGFloat = 0
    /// A page's width over its height, once one of them has loaded and can be measured.
    @State private var pageAspect: CGFloat?
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
            settings.backgroundColor
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

            if controlsVisible, let window, !isReaderFullScreen, !isNativeFullScreen {
                // The OS's edge hit areas are easy to miss, and live resizing the
                // chrome-heavy reader window does nothing on this macOS. An explicit
                // grip resizes the window directly and disappears with the controls.
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ReaderResizeGrip(
                            window: window,
                            aspectRatio: windowAspectRatio,
                            onBegan: {
                                revealControls()
                                isResizingWindow = true
                            },
                            onEnded: {
                                isResizingWindow = false
                                revealControls()
                            }
                        )
                        .frame(width: 22, height: 22)
                        .padding(.trailing, 10)
                        .padding(.bottom, 10)
                    }
                }
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
        }
        // The window hosting the view, reported by AppKit rather than guessed from
        // whichever window happens to be key.
        .background(WindowAccessor(window: $window))
        .onChange(of: window) { _, newWindow in
            // One-time window setup: make the page run under the title bar and keep
            // AppKit's own full screen out of the reader's way.
            guard let newWindow else { return }
            makeBorderless(newWindow)
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
        .onKeyPress("+") { model.zoomIn(); return .handled }
        .onKeyPress("=") { model.zoomIn(); return .handled }
        .onKeyPress("-") { model.zoomOut(); return .handled }
        .onKeyPress("0") { model.resetZoom(); return .handled }
        .onKeyPress("[") { Task { await model.goToChapter(index: model.currentChapterIndex - 1) }; return .handled }
        .onKeyPress("]") { Task { await model.goToChapter(index: model.currentChapterIndex + 1) }; return .handled }
        .onKeyPress("b") { model.toggleBookmark(); return .handled }
        .onKeyPress("f") { toggleFullScreen(); return .handled }
        .onKeyPress(.escape) {
            // Escape leaves full screen first, the way it does in a native full
            // screen window; only an ordinary window closes the reader.
            if isReaderFullScreen {
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
        .task(id: model.currentIndex) {
            // A page's proportions are only knowable once its image has been loaded, so this
            // looks again a few times before settling for the stand-in.
            for attempt in 0..<4 {
                await readPageAspect()
                if let window {
                    // Resize once the page's real shape is known, so a horizontal
                    // window takes the page's proportions instead of framing it.
                    reconcileWindow(window, resizingWindowShape: pageAspect != nil)
                }
                if pageAspect != nil || attempt == 3 { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: settings.layout) { _, _ in
            guard let window else { return }
            if settings.layout == .vertical {
                // Releasing the lock must not wait on full-screen bookkeeping; this
                // only clears the ratio and any stuck size limit, it never resizes.
                applyWindowShape()
            }
            reconcileWindow(window, resizingWindowShape: true)
        }
        .onChange(of: settings.pageMode) { _, _ in
            guard let window else { return }
            reconcileWindow(window, resizingWindowShape: true)
        }
        .onChange(of: model.isLoading) { _, isLoading in
            if !isLoading { scheduleIntroIfNeeded() }
        }
        // Native full screen is tracked separately from the reader's own screen-filling
        // mode. Nothing is done to the window from `will…` until the transition has
        // unwound, so AppKit never has to reconcile the reader while it is capturing
        // and restoring the window.
        .task(id: window) {
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSWindow.willEnterFullScreenNotification,
                object: window
            ) {
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
                }
            }
        }
        .onDisappear {
            // Presentation options are app-wide, so full screen must not outlive the view.
            if isReaderFullScreen, NSApp.isActive {
                NSApp.presentationOptions = savedPresentationOptions
            }
            model.flushProgress()
        }
    }

    /// Marks AppKit's native full screen transition as in flight. Window chrome is left
    /// alone until the matching `did…` notification has unwound.
    private func beginNativeFullScreenTransition() {
        nativeFullScreenGeneration += 1
        isNativeFullScreenTransition = true
    }

    /// Fills the screen with the reader without involving AppKit's full screen.
    ///
    /// The window stays an ordinary window the whole time: only its frame and the
    /// system's presentation options change. There is no space transition and no
    /// title bar swap, which is what avoids the native full screen exit hang.
    private func enterReaderFullScreen(_ window: NSWindow) {
        guard !isReaderFullScreen, let screen = window.screen ?? NSScreen.main else { return }
        windowedFrame = window.frame
        windowedSizeLimits = (window.minSize, window.maxSize)
        savedPresentationOptions = NSApp.presentationOptions
        isReaderFullScreen = true
        settings.readerFullscreen = true

        // The page fills the screen; the grip that shapes the windowed reader is
        // not available there.
        appliedAspectRatio = 0
        window.minSize = screen.frame.size
        window.maxSize = screen.frame.size

        // Native full screen is not available while the reader is filling the screen
        // itself; the green button zooms instead. It comes back on exit.
        window.collectionBehavior.insert(.fullScreenNone)
        window.collectionBehavior.remove(.fullScreenPrimary)

        if NSApp.isActive {
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        }
        // A screen-filling window should not slide around under the pointer.
        window.isMovable = false
        window.setFrame(screen.frame, display: true)
        reconcileWindow(window)
    }

    /// Puts the window back where it was and hands the menu bar and Dock back.
    private func exitReaderFullScreen(_ window: NSWindow) {
        guard isReaderFullScreen else { return }
        isReaderFullScreen = false
        settings.readerFullscreen = false
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)

        if NSApp.isActive {
            NSApp.presentationOptions = savedPresentationOptions
        }
        if let windowedSizeLimits {
            window.minSize = windowedSizeLimits.min
            window.maxSize = windowedSizeLimits.max
            self.windowedSizeLimits = nil
        }
        window.isMovable = true
        if let windowedFrame {
            window.setFrame(windowedFrame, display: true)
            self.windowedFrame = nil
        }
        reconcileWindow(window)
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
            _ = try? await images.image(for: firstPage, maxPixelSize: size)
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
            let pageWidth = geometry.size.width
            let zoom = model.zoom
            // Zoom changes the pages' real layout size, so the lazy stack knows
            // exactly what is on screen. Zoombed out, the stack is the window's width
            // and the smaller pages sit centred inside it, leaving bars on both sides.
            let contentWidth = max(pageWidth, pageWidth * zoom)

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 0) {
                    ForEach(model.pages) { page in
                        AsyncPageImage(page: page, maxPixelSize: model.renderMaxPixelSize, contentMode: .fit)
                            .frame(width: pageWidth * zoom)
                            .id(page.index)
                    }
                }
                .frame(width: contentWidth)
                .scrollTargetLayout()
                // Inside the scroll content, so it is definitely the scroll view
                // containing it that gets found.
                .background(ScrollViewAccessor(scrollView: $verticalScrollView))
            }
            .scrollPosition(id: positionBinding)
            .scrollIndicators(.never)
            .gesture(verticalZoomGesture)
            .onTapGesture(count: 2) {
                model.zoom > 1 ? model.resetZoom() : model.setZoom(2)
            }
        }
    }

    /// Horizontal paging is the platform's scroll view with one custom decision about
    /// where a gesture comes to rest.
    ///
    /// Every spread is a page in a scrolling row, so the pages track the fingers the way
    /// the desktop swipe does — across as many of them as the gesture covers.
    /// `ReaderPagingBehavior` then settles on whichever page the fingers were nearest to
    /// rather than following the momentum, so a fast swipe lands where it was aimed
    /// instead of sailing past pages that were never read.
    private var horizontalReader: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(spreads.enumerated()), id: \.offset) { _, spread in
                        spreadView(spread, size: size)
                            .frame(width: size.width, height: size.height)
                            .id(spread.first?.index ?? 0)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(ReaderPagingBehavior(pageWidth: size.width, offset: scrollOffset))
            .scrollPosition(id: $spreadPosition, anchor: .center)
            .scrollIndicators(.never)
            // A zoomed page needs the drag to pan it rather than to turn the page.
            .scrollDisabled(model.zoom > 1)
            // Right to left reverses the axis, which is exactly what manga wants.
            .environment(\.layoutDirection, settings.direction == .rightToLeft ? .rightToLeft : .leftToRight)
            .gesture(zoomGesture)
            .onTapGesture(count: 2) {
                model.zoom > 1 ? model.resetZoom() : model.setZoom(2)
            }
            // Where the fingers let go is only knowable here, so it is passed to the
            // behavior rather than left to the momentum the scroll view would project.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, offset in
                scrollOffset.value = offset
            }
            .onAppear { spreadPosition = spreadID(at: currentSpreadIndex) }
            .onChange(of: spreadPosition) { _, newValue in
                guard let newValue, newValue != spreadID(at: currentSpreadIndex) else { return }
                model.goToPage(newValue)
            }
            .onChange(of: model.currentIndex) { _, _ in
                guard spreadID(at: currentSpreadIndex) != spreadPosition else { return }
                withAnimation(ReaderView.pageTurnAnimation) { spreadPosition = spreadID(at: currentSpreadIndex) }
            }
        }
    }

    /// Identity the scroll view is addressed by: the first page of a spread.
    private func spreadID(at index: Int) -> Int? {
        let grid = spreads
        guard grid.indices.contains(index) else { return nil }
        return grid[index].first?.index
    }

    /// Deliberate page turn: one spread, which is one page in single-page mode and a
    /// facing pair in double-page mode.
    private func turnSpread(_ direction: Int) {
        guard settings.layout == .horizontal else {
            direction > 0 ? model.nextPage() : model.previousPage()
            return
        }

        // A reading-order step, which right to left reverses.
        let step = settings.direction == .rightToLeft ? -direction : direction
        let neighbour = currentSpreadIndex + step
        guard spreads.indices.contains(neighbour), let firstPage = spreads[neighbour].first else {
            // At the end of the chapter, keep the existing behaviour of moving on.
            direction > 0 ? model.nextPage() : model.previousPage()
            return
        }

        withAnimation(ReaderView.pageTurnAnimation) {
            spreadPosition = firstPage.index
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
        ReaderSpreads.group(
            model.pages,
            pageMode: settings.pageMode,
            firstPageAlone: settings.doublePageFirstPageAlone
        )
    }

    private var positionBinding: Binding<Int?> {
        Binding(
            get: { model.currentIndex },
            set: { newValue in
                // Magnifying changes every page's width, which shifts the scroll
                // view's idea of the current page. Those intermediate positions are
                // not page turns: feeding them back made the reader fight itself,
                // flicker between placeholder and page, and jump up and down.
                guard !isMagnifying, let newValue else { return }
                model.goToPage(newValue, resetZoom: false)
            }
        )
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !isMagnifying {
                    isMagnifying = true
                    zoomGestureBase = model.zoom
                }
                model.setZoom(zoomGestureBase * value.magnification)
            }
            .onEnded { _ in
                zoomGestureBase = model.zoom
                isMagnifying = false
            }
    }

    /// Enables the scroll view's magnification used by the vertical reader. The pinch
    /// itself is handled by `verticalZoomGesture`, which applies the zoom at the
    /// pointer; programmatic zoom still works while user magnification is off.
    /// The vertical reader's pinch. Layout zoom keeps the lazy stack's page rendering
    /// in step with what is visible; when the pinch ends the scroll offset is moved so
    /// the point that was under the pointer is under it again.
    private var verticalZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !isMagnifying {
                    isMagnifying = true
                    zoomGestureBase = model.zoom
                    zoomAnchor = captureZoomAnchor(zoom: model.zoom)
                }
                model.setZoom(zoomGestureBase * value.magnification)
            }
            .onEnded { _ in
                restoreZoomAnchor()
                zoomGestureBase = model.zoom
                isMagnifying = false
            }
    }

    private func captureZoomAnchor(zoom: CGFloat) -> ReaderZoomAnchor? {
        guard let scrollView = verticalScrollView,
              let window = scrollView.window
        else { return nil }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let clip = scrollView.contentView
        let documentPoint = clip.convert(windowPoint, from: nil)
        let viewportPoint = NSPoint(
            x: documentPoint.x - clip.bounds.origin.x,
            y: documentPoint.y - clip.bounds.origin.y
        )
        return ReaderZoomAnchor(
            documentPoint: documentPoint,
            viewportPoint: viewportPoint,
            zoom: zoom
        )
    }

    private func restoreZoomAnchor() {
        guard let anchor = zoomAnchor, let scrollView = verticalScrollView else {
            zoomAnchor = nil
            return
        }
        zoomAnchor = nil

        let ratio = model.zoom / anchor.zoom
        guard ratio.isFinite, ratio > 0 else { return }

        let origin = NSPoint(
            x: anchor.documentPoint.x * ratio - anchor.viewportPoint.x,
            y: anchor.documentPoint.y * ratio - anchor.viewportPoint.y
        )
        Task { @MainActor in
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
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
        .padding(.top, controlBarTopPadding)
        // A soft shadow lifts the floating bar off the page while the controls are up;
        // it fades away with them.
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        .onGeometryChange(for: CGFloat.self) { bar in
            bar.size.height
        } action: { height in
            controlBarHeight = height
        }
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
            Task { await model.goToChapter(index: model.currentChapterIndex - 1) }
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
            Task { await model.goToChapter(index: model.currentChapterIndex + 1) }
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
            displayOptions
        }
        .help("Reading options")
    }

    private var fullScreenControl: some View {
        Button {
            toggleFullScreen()
        } label: {
            Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .help("Exclusive full screen (F) — the green button uses native full screen")
    }

    // MARK: - Display options

    /// The reader's settings, with the viewing presets at the top.
    ///
    /// A popover rather than a menu: a menu renders one row per item and flattens anything
    /// that is not a menu item, so the presets could only ever have been plain rows. Here
    /// they are buttons that look like buttons.
    private var displayOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(ReaderPreset.allCases) { preset in
                    presetButton(preset)
                }
            }

            Divider()

            LabeledContent("Layout") {
                Picker("Layout", selection: binding(get: { $0.layout }, set: { $0.layout = $1 })) {
                    ForEach(ReaderLayoutKind.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            LabeledContent("Direction") {
                Picker("Direction", selection: binding(get: { $0.direction }, set: { $0.direction = $1 })) {
                    ForEach(ReadingDirection.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            LabeledContent("Pages") {
                Picker("Pages", selection: binding(get: { $0.pageMode }, set: { $0.pageMode = $1 })) {
                    ForEach(PageMode.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            LabeledContent("Fit") {
                Picker("Fit", selection: binding(get: { $0.fitMode }, set: { $0.fitMode = $1 })) {
                    ForEach(PageFitMode.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }

            Divider()

            HStack(spacing: 8) {
                Button("Zoom In") { model.zoomIn() }
                Button("Zoom Out") { model.zoomOut() }
                Button("Actual Fit") { model.resetZoom() }
            }
            .controlSize(.small)

            Divider()

            HStack(spacing: 8) {
                Button("Mark Chapter Read") { model.markCurrentChapterRead() }
                Button("Mark Unread") { model.markCurrentChapterUnread() }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
    }

    /// A preset as a pill, filled in when the reader is already set up that way.
    private func presetButton(_ preset: ReaderPreset) -> some View {
        let isCurrent = settings.layout == preset.layout && settings.pageMode == preset.pageMode
        return Button {
            settings.layout = preset.layout
            settings.pageMode = preset.pageMode
        } label: {
            Text(preset.displayName)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func binding<Value>(
        get: @escaping (SettingsStore) -> Value,
        set: @escaping (SettingsStore, Value) -> Void
    ) -> Binding<Value> {
        Binding(get: { get(settings) }, set: { set(settings, $0) })
    }

    private func toggleFullScreen() {
        // The green button and the View menu own native full screen; this toggle is the
        // reader's own screen-filling mode, and the two do not overlap.
        guard let window,
              !isNativeFullScreen,
              !isNativeFullScreenTransition,
              !window.styleMask.contains(.fullScreen)
        else { return }

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
            window.toolbar = NSToolbar(identifier: "UzumakiReaderToolbar")
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
        guard settings.layout == .horizontal else { return nil }
        let page = pageAspect ?? Self.typicalPageAspectRatio
        return settings.pageMode == .double ? page * 2 : page
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
            pageAspect = CGFloat(image.width) / CGFloat(image.height)
            return
        }
        pageAspect = nil
    }

    /// Stand-in proportions, used until a page has loaded.
    private static let typicalPageAspectRatio: CGFloat = 2.0 / 3.0

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

        let width = window.contentRect(forFrameRect: window.frame).width
        guard width > 0 else { return }
        window.setContentSize(NSSize(width: width, height: (width / ratio).rounded()))
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

/// A point on the page, the matching point in the viewport, and the zoom it was
/// captured at — used to keep the page under the pointer while zooming.
private struct ReaderZoomAnchor {
    let documentPoint: CGPoint
    let viewportPoint: CGPoint
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
