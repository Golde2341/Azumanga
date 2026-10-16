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
    @Environment(\.imagePipeline) private var images

    @State private var showChapterPicker = false
    /// The window hosting the reader, used to drive full screen.
    @State private var window: NSWindow?
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

    var body: some View {
        ZStack {
            settings.backgroundColor
                .ignoresSafeArea()

            content
                // A click on the page also brings the controls back, for when the pointer
                // has not moved to do it.
                .simultaneousGesture(TapGesture().onEnded { revealControls() })

            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
            }

            if controlsVisible {
                VStack {
                    controlBar
                    Spacer()
                }
                .transition(.opacity)
            }

            if controlsVisible {
                pageIndicator
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: controlsVisible)
        // The page runs to the very top edge. Without this the window keeps a strip the
        // height of a title bar above the content, which reads as a bar across the top even
        // though no title is drawn in it.
        .ignoresSafeArea(.container, edges: .top)
        // The window has an empty toolbar, which is what gives the traffic lights their
        // ordinary spacing. In full screen macOS would otherwise draw it at the top of the
        // display — and being empty, it is a blank strip of material. Asking for it on hover
        // is as far as this can go: hiding the window toolbar outright changes the title bar
        // itself, and doing that around a full screen transition is what hangs the window.
        .windowToolbarFullScreenVisibility(.onHover)
        .onChange(of: controlsVisible) { _, _ in
            guard let window else { return }
            applyTrafficLightVisibility(in: window)
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
            // sheet are anchored to controls, and hiding those would take them along.
            guard !Task.isCancelled, !showsDisplayOptions, !showChapterPicker else { return }
            controlsVisible = false
        }
        .onAppear { revealControls() }
        .background(WindowAccessor(window: $window))
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
        .onKeyPress("m") { model.markCurrentChapterRead(); return .handled }
        .sheet(isPresented: $showChapterPicker) {
            ChapterPickerSheet(model: model, isPresented: $showChapterPicker)
        }
        .onChange(of: window) { _, newValue in
            guard let newValue else { return }
            makeBorderless(newValue)
            restoreFullScreenPreference(in: newValue)
            applyWindowShape(resizing: true)
        }
        .onChange(of: settings.layout) { _, _ in applyWindowShape(resizing: true) }
        .onChange(of: settings.pageMode) { _, _ in applyWindowShape(resizing: true) }
        .task(id: model.currentIndex) {
            // A page's proportions are only knowable once its image has been loaded, so this
            // looks again a few times before settling for the stand-in.
            for attempt in 0..<4 {
                await readPageAspect()
                applyWindowShape()
                if pageAspect != nil || attempt == 3 { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: window) {
            // Track full screen as it actually is, so leaving it with the green
            // button is remembered just like the toolbar toggle.
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSWindow.didEnterFullScreenNotification,
                object: window
            ) {
                settings.readerFullscreen = true
                // Nothing touches the window here. It is in the middle of AppKit's full
                // screen transition, and mutating the window in that state is what hung it.
                // The work waits until the transition has settled.
                let window = window
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    guard window.styleMask.contains(.fullScreen) else { return }
                    applyWindowShape()
                }
            }
        }
        .task(id: window) {
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSWindow.didExitFullScreenNotification,
                object: window
            ) {
                settings.readerFullscreen = false
                // Same again: the window is still settling back, so the measuring and the
                // shape wait for it.
                let window = window
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    guard !window.styleMask.contains(.fullScreen) else { return }
                    measureTrafficLights(in: window)
                    applyWindowShape()
                }
            }
        }
        .onDisappear {
            model.flushProgress()
        }
    }

    /// Shows the controls and restarts the countdown that puts them away again.
    private func revealControls() {
        controlsVisible = true
        revealTick += 1
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

        // An empty toolbar is the root of the traffic lights' spacing. macOS lays them out
        // the way it does for an ordinary window when a toolbar is present, and tucks them
        // into the corner when the window has only a bare title bar. None of it is drawn —
        // the title bar is transparent and the page runs the full height of the window —
        // and because the system owns the layout, resizing leaves the lights where they are
        // with nothing to re-apply.
        if window.toolbar == nil {
            window.toolbarStyle = .unified
            window.toolbar = NSToolbar(identifier: "UzumakiReaderToolbar")
        }

        applyTrafficLightVisibility(in: window)
        measureTrafficLights(in: window)
    }

    /// Records where the traffic lights sit, so the control bar can clear them and put its
    /// own centre line on theirs.
    ///
    /// The room they take is measured in full screen as well: macOS reveals the window's
    /// toolbar — and the lights with it — when the pointer goes to the top of the display,
    /// and the controls need to have moved over by then.
    private func measureTrafficLights(in window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }

        guard let close = buttons.first, let last = buttons.last else {
            trafficLightCentre = nil
            trafficLightSpan = 0
            return
        }

        // Full screen has no title bar of its own, so there is no centre line to line up
        // with and the controls fall back to their own inset.
        trafficLightCentre = window.styleMask.contains(.fullScreen)
            ? nil
            : window.frame.height - close.convert(close.bounds, to: nil).midY
        trafficLightSpan = last.convert(last.bounds, to: nil).maxX + 10
    }

    /// The window's shape when two pages are read at a time: two of them side by side.
    private var twoPageAspectRatio: CGFloat {
        2 * (pageAspect ?? Self.typicalPageAspectRatio)
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

    /// Locks the window to the shape of the pages it is showing, so a two-page spread fills
    /// it instead of being letterboxed inside it.
    ///
    /// Released whenever two pages are not being read at a time, and in full screen, where
    /// an aspect ratio would fight the window filling the display.
    ///
    /// `resizing` also resizes the window to take the shape on. That is only safe once the
    /// window is settled, so the full screen transitions never ask for it — resizing the
    /// window while it is coming out of full screen hangs it, and a ratio that changed while
    /// it was away is not a reason to do it then.
    private func applyWindowShape(resizing: Bool = false) {
        guard let window else { return }
        guard settings.layout == .horizontal,
              settings.pageMode == .double,
              !window.styleMask.contains(.fullScreen)
        else {
            appliedAspectRatio = 0
            window.contentAspectRatio = .zero
            return
        }

        let ratio = twoPageAspectRatio
        window.contentAspectRatio = NSSize(width: ratio, height: 1)

        // Take the shape on when it is first applied or whenever the pages' proportions turn
        // out to be different, keeping the width.
        guard resizing, ratio != appliedAspectRatio else { return }
        appliedAspectRatio = ratio

        let width = window.contentRect(forFrameRect: window.frame).width
        guard width > 0 else { return }
        window.setContentSize(NSSize(width: width, height: (width / ratio).rounded()))
    }

    /// The traffic lights go away with the rest of the controls, so a reader with the
    /// controls put away has nothing on screen but the page. Hidden rather than faded, so
    /// they cannot be clicked while they cannot be seen.
    private func applyTrafficLightVisibility(in window: NSWindow) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = !controlsVisible
        }
    }

    /// Applies the remembered window state when the reader opens.
    private func restoreFullScreenPreference(in window: NSWindow) {
        let wantsFullScreen = settings.readerFullscreen
        let isFullScreen = window.styleMask.contains(.fullScreen)
        guard wantsFullScreen != isFullScreen else { return }
        window.toggleFullScreen(nil)
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

                    VStack(spacing: 4) {
                        Text("\(scrubPage + 1) / \(model.pages.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        progressBar
                    }
                    .frame(width: 260)

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
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        isScrubbing = true
                        scrubFraction = min(max(0, value.location.x / width), 1)
                    }
                    .onEnded { _ in
                        let target = ReaderScrubbing.page(
                            atFraction: scrubFraction,
                            pageCount: model.pages.count
                        )
                        isScrubbing = false
                        model.goToPage(target)
                    }
            )
        }
        .frame(height: 12)
        .help("Drag to jump to a page")
    }

    // MARK: - Controls

    /// The reader's controls, sitting in a bar across the top of the page.
    ///
    /// An overlay rather than the window's toolbar. A title bar occupies a strip of its
    /// own, so hiding and showing it pushed the page up and down underneath it; drawn over
    /// the page means the controls can come and go without the reading position moving.
    ///
    /// The bar spans the window and the traffic lights sit in it, with the controls
    /// gathered into rounded groups beside them.
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
                // title stays centred on the window.
                .padding(.leading, trafficLightSpan)
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
        .onGeometryChange(for: CGFloat.self) { bar in
            bar.size.height
        } action: { height in
            controlBarHeight = height
        }
    }

    /// Puts the control bar's centre line on the traffic lights' centre line, so the lights
    /// read as part of the bar rather than floating above it.
    private var controlBarTopPadding: CGFloat {
        guard let centre = trafficLightCentre, controlBarHeight > 0 else { return 8 }
        return max(0, centre - controlBarHeight / 2)
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
        .keyboardShortcut(.escape, modifiers: [])
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
        .help("Full screen")
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
        (window ?? NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }
}

/// Reports the window hosting the view, so the reader can control full screen
/// without guessing which window is key.
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
