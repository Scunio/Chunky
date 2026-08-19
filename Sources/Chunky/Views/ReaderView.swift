import SwiftUI
import CoreData
#if os(macOS)
import AppKit
#endif

/// Wrapper that owns "which comic is active": switching to the next one recreates
/// ReaderContentView with a different identity (.id), something an @ObservedObject can't do
/// on its own (it isn't legal to reassign it from inside an action closure).
struct ReaderView: View {
    let comic: ComicEntity
    var libraryComics: [ComicEntity] = []
    @State private var activeComic: ComicEntity

    init(comic: ComicEntity, libraryComics: [ComicEntity] = []) {
        self.comic = comic
        self.libraryComics = libraryComics
        _activeComic = State(initialValue: comic)
    }

    var body: some View {
        ReaderContentView(comic: activeComic, libraryComics: libraryComics) { next in
            activeComic = next
        }
        .id(activeComic.objectID)
    }
}

private struct ReaderContentView: View {
    @ObservedObject var comic: ComicEntity
    /// List (in the same order shown in the library) used to propose "the next comic" once
    /// reading is finished. Empty if the reader is opened without a library context.
    var libraryComics: [ComicEntity] = []
    let onSwitchComic: (ComicEntity) -> Void
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    // On Mac the reader lives in its own window (WindowGroup(for: ComicID.self)), not in a
    // .sheet: dismiss() there has no effect. dismissWindow() closes the window that contains
    // it, which is the real equivalent of "exit the reader" here.
    @Environment(\.dismissWindow) private var dismissWindow
    #endif
    /// Explicit single/double page choice, only valid when not in automatic mode.
    @AppStorage("doublePageMode") private var isDoublePageEnabled = false
    /// In automatic mode, double page simply follows the available space (isDoublePageAllowed).
    @AppStorage("doublePageAutoMode") private var isDoublePageAutoMode = true
    /// If true, the first page (usually the cover) is always shown alone even in double
    /// page, and pairing into two pages resumes from the second one.
    @AppStorage("doublePageCoverAlone") private var isCoverAlone = true
    @AppStorage("tapPageTurnStyle") private var tapPageTurnStyle = TapPageTurnStyle.slide
    @AppStorage("swipePageTurnStyle") private var swipePageTurnStyle = TapPageTurnStyle.slide
    /// Duration of the "Dissolvenza" (`.fade`) page-turn style's cross-dissolve — see
    /// `PageCollectionPager.fadeDuration`.
    @AppStorage("fadeTransitionDuration") private var fadeTransitionDuration = 0.25
    @AppStorage("oneHandedMode") private var isOneHandedModeEnabled = false
    @AppStorage("oneHandedZonesReversed") private var isOneHandedZonesReversed = false
    @AppStorage("hotCornersEnabled") private var isHotCornersEnabled = false
    @AppStorage("tapToPanEnabled") private var isTapToPanEnabled = false
    @AppStorage("twoFingerBrightnessEnabled") private var isTwoFingerBrightnessEnabled = true
    @AppStorage("readerIdleResetSeconds") private var readerIdleReset = ReaderIdleResetOption.never
    @State private var idleResetWorkItem: DispatchWorkItem?
    /// Raised by PageView (via binding) so the pager knows whether the current page is
    /// zoomed in: with zoom active, swipe-to-change-page must be suspended, otherwise it
    /// conflicts with the drag used to move around inside the zoomed page.
    @State private var isZoomed = false
    /// Style and direction of the last page change: the pager uses them to choose the
    /// transition. They're needed because the style is per-gesture (tap and swipe have
    /// independent settings), so it can't be read from AppStorage when building the view:
    /// it's necessary to know *which* gesture triggered the change.
    @State private var turnStyle = TapPageTurnStyle.slide
    /// +1 = the page index increases, -1 = it decreases (already adjusted for reading direction).
    @State private var turnDirection = 1
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Viewport dimensions, to figure out whether there's really horizontal space for
    /// double page: on iPad the size class stays "regular" even in portrait, so it isn't
    /// enough on its own to avoid wasting space (two narrow pages with black bands above/below).
    @State private var viewportSize: CGSize = .zero
    @State private var provider: ComicPageProvider?
    // Prefetch around the current page on both platforms: it used to be macOS-only (the iOS
    // pager has its own cache of already-built views that avoided the most visible problem,
    // rebuilding everything on every page, but never gets ahead of decoding before the user
    // pages through — every new page still starts from scratch).
    @State private var pageCache: PageImageCache?
    // Duplicate the keys also read by `PageView`: needed here to invalidate the cache when
    // they change (see `.onChange` further below), not for the processing itself.
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    /// Index of the "main" page (the first one, leftmost in LTR) of the current spread.
    @State private var currentPage: Int = 0
    @State private var loadError: String?
    /// Progress (0...1) of the iCloud download of the comic being opened, nil if no download
    /// is in progress: the comic can always be opened, it's the opening itself that downloads it.
    @State private var downloadProgress: Double?
    /// The download in progress, so it can be cancelled directly from the reader.
    @State private var downloadItem: DownloadItem?
    /// A load is in progress (iCloud download and/or opening the archive): see
    /// `loadComic`.
    @State private var isLoadingComic = false
    @State private var isControlsVisible = true
    @State private var isSharePresented = false
    @State private var shareImage: PlatformImage?
    @State private var pendingNextComic: ComicEntity?
    @State private var isPanelSelectionPresented = false
    /// Text search within the comic. The index is only created the first time the card is
    /// opened: building it when the reader opens on a comic that's never been searched
    /// would mean paying for OCR nobody asked for.
    @State private var isFindPresented = false
    @State private var findQuery = ""
    @State private var textIndex: ComicTextIndex?
    @State private var isPageJumpPresented = false
    @State private var jumpPageNumber = 1
    @State private var isInfoPresented = false
    @State private var isToolsPresented = false
    @State private var isAccountsPresented = false
    /// Measured widths of the header's leading/trailing icon groups, so the title between
    /// them can be reserved equal space on both sides and land on the bar's true center
    /// regardless of which group has more icons — see `HeaderLeadingWidthKey`.
    @State private var headerLeadingWidth: CGFloat = 0
    @State private var headerTrailingWidth: CGFloat = 0
    #if os(iOS)
    /// Measured heights of the control bars: needed by the tap zones so they don't react
    /// to touches that fall on the bars (see `PageTapZones.topInset`). Measured rather than
    /// estimated because they depend on the safe area, text size and the bars' content.
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    /// Brightness level shown by the indicator during the two-finger gesture, `nil` when
    /// the indicator is hidden. Without visible feedback there's no way, on device, to
    /// distinguish "the gesture isn't arriving" from "brightness isn't moving" — see
    /// `TwoFingerBrightnessView`.
    @State private var brightnessLevel: Double?
    /// Level tracked during the gesture. It's accumulated here instead of re-reading
    /// `UIScreen.brightness` every time: re-reading makes the gesture depend on the system
    /// actually accepting the write (in the simulator it doesn't, and the value always
    /// bounces back to the starting one), and summing on top of a value that never advances
    /// means never moving at all. Reset to zero at the end of the gesture, so the next
    /// gesture starts again from the real brightness — which the user may have changed from
    /// Control Center in the meantime.
    @State private var brightnessTarget: CGFloat?
    /// Changes on every update: only the last one hides the indicator, so a long gesture
    /// doesn't make it disappear halfway through.
    @State private var brightnessHideToken = 0
    #endif
    @State private var isNewComicsPresented = false
    @State private var isNowReadingPresented = false
    @AppStorage("newTrayClearedAt") private var newTrayClearedAtTimestamp: Double = 0
    @AppStorage("pageBackground") private var pageBackgroundRawValue = PageBackground.black.rawValue
    @Environment(\.colorScheme) private var colorScheme

    /// Two vertical pages side by side on a narrow screen leave a huge gap above and below
    /// (the combined image is too wide relative to the available height): double page only
    /// makes sense with more horizontal than vertical space. The size class alone isn't
    /// enough on iPad, where it stays "regular" even in portrait. Logic lives in
    /// `DoublePagePolicy`: on macOS there's no compact size class, so the decision always
    /// depends solely on the measured proportions.
    private var isDoublePageAllowed: Bool {
        #if os(iOS)
        DoublePagePolicy.isAllowed(viewportSize: viewportSize, isCompactWidth: horizontalSizeClass != .regular)
        #else
        DoublePagePolicy.isAllowed(viewportSize: viewportSize, isCompactWidth: false)
        #endif
    }

    /// Effective double page: in automatic mode it follows the available space, otherwise the manual choice.
    private var effectiveDoublePage: Bool {
        isDoublePageAutoMode ? isDoublePageAllowed : (isDoublePageEnabled && isDoublePageAllowed)
    }

    private var pageStep: Int { effectiveDoublePage ? 2 : 1 }

    private func pagination(pageCount: Int) -> ReaderPagination {
        ReaderPagination(
            pageCount: pageCount,
            pageStep: pageStep,
            isRightToLeft: comic.readingDirection == .rightToLeft,
            coverIsAlone: isCoverAlone
        )
    }

    /// Start indices of each spread (1 or 2 pages), used as navigation "tags"/steps.
    private func spreadStarts(pageCount: Int) -> [Int] {
        pagination(pageCount: pageCount).spreadStarts
    }

    /// Pages currently shown on screen, in left→right visual order (already corrected for
    /// reading direction): used by the search highlighting, which needs to know not just
    /// *which* pages are visible but also in what order they're side by side.
    private func displayedPages(pageCount: Int) -> [Int] {
        let pag = pagination(pageCount: pageCount)
        guard pag.showsSecondPage(from: currentPage) else { return [currentPage] }
        let rightToLeft = comic.readingDirection == .rightToLeft
        return rightToLeft ? [currentPage + 1, currentPage] : [currentPage, currentPage + 1]
    }

    // When the page step changes, the current index might no longer be a valid spread
    // start (e.g. going from an even page to step 2): we realign it, otherwise the
    // TabView's tag finds no match and shows the wrong page.
    private func realignCurrentPageToSpreadStart() {
        guard let provider = provider else { return }
        setPageWithoutAnimation(pagination(pageCount: provider.pageCount).realigned(currentPage))
    }

    /// Moves the current index without animating it and without letting the pager inherit
    /// the last gesture's style. Used for internal realignments (restoring the saved
    /// position, changing the single/double page step): these aren't page changes the user
    /// asked for, so they shouldn't turn the page with a slide or fade depending on how we
    /// got here.
    private func setPageWithoutAnimation(_ index: Int) {
        guard index != currentPage else { return }
        turnStyle = .immediate
        turnDirection = index > currentPage ? 1 : -1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { currentPage = index }
    }

    private var readerBackground: Color {
        switch PageBackground(rawValue: pageBackgroundRawValue) ?? .black {
        case .black: return .black
        case .white: return .white
        case .automatic: return colorScheme == .dark ? .black : .white
        }
    }

    private var isBackgroundDark: Bool {
        switch PageBackground(rawValue: pageBackgroundRawValue) ?? .black {
        case .black: return true
        case .white: return false
        case .automatic: return colorScheme == .dark
        }
    }

    /// The reader's header/footer/menu were designed for an always-black background
    /// (white text/icons on dark pills): with "Page background" now also selectable as
    /// white, these colors must adapt or they become unreadable (white on white).
    private var chromeForeground: Color { isBackgroundDark ? .white : .black }

    /// Solid, not the system's translucent material: a blurred/see-through bar let the page
    /// content show through underneath, which read as washed-out rather than a clean bar.
    ///
    /// Not the same color as the page (`readerBackground`) either: a bar in the *exact* same
    /// black/white as the page it sits on gave no visual separation between "this is chrome"
    /// and "this is the page" — the two areas just blended into one undifferentiated block.
    /// iOS's own systemGray6 (the standard tone for a surface that reads as distinct from its
    /// canvas without competing with it) at #1C1C1E dark / #F2F2F7 light: contrast against
    /// `chromeForeground` (white/black) is ~18:1 / ~19.5:1, well past WCAG AAA's 7:1 for
    /// normal text, so legibility isn't a concern with either.
    private var chromeBackground: Color {
        isBackgroundDark ? Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
                          : Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255)
    }

    var body: some View {
        #if os(iOS)
        // Hosts `readerContent` in a UIViewController that drives `prefersStatusBarHidden`
        // directly — see `StatusBarControllingHost` — instead of SwiftUI's own
        // `.statusBar(hidden:)`, which doesn't coordinate its animation with the safe-area
        // transition UIKit runs for the status bar, causing `.ignoresSafeArea()` content
        // (the pager) to visibly jump on a real device when toggled inside an animated
        // SwiftUI transaction (not reproducible in the simulator — found the hard way).
        StatusBarControllingHost(isStatusBarHidden: !isControlsVisible) {
            readerContent
        }
        #else
        readerContent
        #endif
    }

    private var readerContent: some View {
        ZStack {
            readerBackground.ignoresSafeArea()

            // Ignore the safe area here too: otherwise the measured size changes along
            // with the status bar when the controls are shown/hidden, needlessly
            // triggering effectiveDoublePage and moving/resizing the page.
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportSize = proxy.size }
                    .onChange(of: proxy.size) { viewportSize = proxy.size }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if let provider = provider {
                #if os(iOS)
                // Ignore the safe area: otherwise, when the status bar appears/disappears
                // as the controls are shown/hidden, the safe area changes and the page gets
                // resized/moved instead of staying still underneath the controls.
                iOSPager(provider: provider).ignoresSafeArea()
                #else
                macOSPager(provider: provider)
                #endif
            } else if let loadError = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.yellow)
                    Text(loadError)
                        .foregroundColor(chromeForeground)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else if let downloadProgress = downloadProgress {
                downloadOverlay(progress: downloadProgress)
            } else {
                ProgressView().accentColor(chromeForeground)
            }

            #if os(iOS)
            if isTwoFingerBrightnessEnabled {
                TwoFingerBrightnessView(onBegan: { brightnessTarget = UIScreen.current?.brightness }) { delta in
                    applyBrightnessDelta(delta)
                }
            }
            #endif

            #if os(iOS)
            if let brightnessLevel {
                brightnessIndicator(level: brightnessLevel)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            #endif

            if isControlsVisible && !isPanelSelectionPresented && !isFindPresented {
                controlsChrome
                .allowsHitTesting(true)

                #if os(iOS)
                // No `.ignoresSafeArea`/`.safeAreaInset` here: several placements of both
                // measurably failed to reach the true bottom edge on iPad — a `GeometryReader`
                // kept reporting the same `PlatformSafeArea.bottomInset`-sized shortfall no
                // matter which one was used, with or without `StatusBarControllingHost` in
                // the loop, so it's `.fullScreenCover` itself that never proposes more than
                // the safe-area-inset frame here, regardless of what content asks for. This
                // `VStack` positions `footer` the ordinary, safe-area-respecting way (its
                // bottom edge lands exactly on the safe boundary); `footer`'s own `.offset`
                // is what actually pushes it the rest of the way to the true edge — verified
                // pixel-for-pixel with `xcrun simctl io screenshot` (the raw device image;
                // the MCP screenshot tool's own processing pads a fixed strip at the bottom
                // that looks identical to this bug but isn't it).
                VStack(spacing: 0) {
                    Spacer()
                    footer
                }
                .allowsHitTesting(true)
                #endif

                // Hint at where the tap zones to change page are (otherwise completely
                // invisible): they don't intercept touches, they're just a visual cue.
                if tapPageTurnStyle != .disabled {
                    if isOneHandedModeEnabled {
                        // In one-handed mode both sides do the same action, so the arrows
                        // both point in the same direction (the shared action's) instead of
                        // one forward and one back.
                        let sharedSymbol = isOneHandedZonesReversed ? "arrowtriangle.left" : "arrowtriangle.right"
                        HStack {
                            Image(systemName: sharedSymbol)
                            Spacer()
                            Image(systemName: sharedSymbol)
                        }
                        .font(.title2)
                        .foregroundColor(chromeForeground.opacity(0.35))
                        .padding(.horizontal, 14)
                        .allowsHitTesting(false)
                    } else {
                        HStack {
                            Image(systemName: "arrowtriangle.left")
                            Spacer()
                            Image(systemName: "arrowtriangle.right")
                        }
                        .font(.title2)
                        .foregroundColor(chromeForeground.opacity(0.35))
                        .padding(.horizontal, 14)
                        .allowsHitTesting(false)
                    }
                }
            }

            if let next = pendingNextComic {
                nextComicConfirmation(next)
            }

            if isPageJumpPresented, let provider = provider {
                pageJumpCard(provider: provider)
            }

            // The highlights stay even after the card is closed, until the search is
            // cleared: after jumping, the useful thing is seeing *where* the word is, and
            // the card would cover half the page.
            if let textIndex, let provider = provider, !findQuery.isEmpty {
                ReaderFindHighlightOverlay(
                    index: textIndex,
                    query: findQuery,
                    displayedPages: displayedPages(pageCount: provider.pageCount),
                    provider: provider
                )
            }

            if isFindPresented, let textIndex {
                ReaderFindView(index: textIndex, query: $findQuery) { match in
                    jumpToMatch(match)
                } onClose: {
                    isFindPresented = false
                }
            }

            // Overlaid directly on the already-visible page (not another screen/sheet):
            // the page underneath is still visible, not a comic reloaded as its own thing.
            if isPanelSelectionPresented, let provider = provider {
                PanelSelectionView(pageIndex: currentPage, provider: provider) { cropped in
                    isPanelSelectionPresented = false
                    presentShareImage(cropped)
                } onCancel: {
                    isPanelSelectionPresented = false
                }
            }
        }
        #if os(iOS)
        // On iPad a horizontal swipe starting near the bottom edge risks being stolen by
        // the system gesture (Dock/App Switcher). defersSystemGestures gives priority to
        // our page-change DragGesture as long as the touch is in progress on that edge.
        .defersSystemGestures(on: .bottom)
        #endif
        .onAppear {
            loadComic()
            resetIdleTimerIfNeeded()
        }
        .onDisappear {
            idleResetWorkItem?.cancel()
            // OCR scanning is the most expensive thing the reader could have in progress:
            // letting it keep running after exiting would heat up the phone for a result
            // nobody is looking at anymore.
            textIndex?.cancelScanning()
        }
        .onChange(of: currentPage) { _, newValue in
            // A page that turns is never still zoomed by definition (each page's zoom
            // starts over, see `ZoomableImageView.updateUIView`): resetting the shared flag
            // right here, on the one state change every page-turn path goes through, doesn't
            // depend on the UIKit collection view cell for the zoomed-out page actually
            // running through `isActive` becoming false before it's reused for another
            // page — which isn't guaranteed (a cell scrolled far enough off-screen can be
            // recycled for a different index without ever seeing that transition), and was
            // the gap that still let `isZoomed` latch `true` and freeze swiping.
            if isZoomed { isZoomed = false }
            guard let provider = provider else { return }
            comic.lastReadPage = Int32(min(max(newValue, 0), provider.pageCount - 1))
            comic.dateLastOpened = Date()
            try? context.save()
        }
        .onChange(of: isDoublePageEnabled) { realignCurrentPageToSpreadStart() }
        .onChange(of: isDoublePageAutoMode) { realignCurrentPageToSpreadStart() }
        .onChange(of: viewportSize) { realignCurrentPageToSpreadStart() }
        // Cached entries were processed with the previous options: without clearing it, a
        // page already seen would show the old crop/tint until it falls outside the
        // prefetch window.
        .onChange(of: isAutoCropEnabled) { purgePageCache() }
        .onChange(of: isUpscalingEnabled) { purgePageCache() }
        .onChange(of: isAutoTintContrastEnabled) { purgePageCache() }
        #if os(iOS)
        .sheet(isPresented: $isSharePresented) {
            if let shareImage = shareImage {
                ActivityShareSheet(activityItems: [shareImage])
            }
        }
        #endif
        .sheet(isPresented: $isInfoPresented) {
            ComicInfoSheet(
                comic: comic,
                loadedPageCount: provider?.pageCount,
                onJumpToPage: {
                    jumpPageNumber = currentPage + 1
                    isPageJumpPresented = true
                },
                onToggleFavorite: toggleFavorite,
                onToggleReadingDirection: toggleReadingDirection
            )
        }
        .sheet(isPresented: $isToolsPresented) {
            ToolsPanelView()
        }
        .sheet(isPresented: $isAccountsPresented) {
            NavigationStack { AccountsView().toolbarDoneButton { isAccountsPresented = false } }
                .sheetSized()
        }
    }

    private func presentShareImage(_ image: PlatformImage) {
        shareImage = image
        #if os(iOS)
        isSharePresented = true
        #elseif os(macOS)
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            NSSharingServicePicker(items: [image]).show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
        #endif
    }

    private func exitReader() {
        #if os(macOS)
        dismissWindow()
        #else
        dismiss()
        #endif
    }

    private func toggleFavorite() {
        comic.isFavorite.toggle()
        try? context.save()
    }

    /// Card to jump directly to a specific page, opened from the header's "..." menu.
    private func pageJumpCard(provider: ComicPageProvider) -> some View {
        VStack(spacing: 16) {
            Text("Vai a pagina")
                .font(.headline)
                .foregroundColor(.white)

            Stepper(value: $jumpPageNumber, in: 1...max(provider.pageCount, 1)) {
                Text("Pagina \(jumpPageNumber) di \(provider.pageCount)")
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 12) {
                Button(action: { isPageJumpPresented = false }) {
                    Text("Annulla")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                Button(action: confirmPageJump) {
                    Text("Vai")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(Color.black.opacity(0.85))
        .cornerRadius(16)
    }

    /// Opens the search card, creating the index on first use and restarting the scan from
    /// the current page: if the index already existed from a previous session, it only
    /// resumes the pages it's missing.
    private func presentFind() {
        guard let provider = provider else { return }
        // Whoever reaches the end of the comic already has the "continue with…" confirmation
        // on screen: the two cards would overlap. Opening the search is an answer to that
        // question ("no, I want to search for something"), so the confirmation exits the scene.
        pendingNextComic = nil
        if textIndex == nil {
            textIndex = ComicTextIndex(
                provider: provider,
                comicIdentifier: comic.objectID.uriRepresentation().absoluteString
            )
        }
        textIndex?.startScanning(from: currentPage)
        isFindPresented = true
    }

    private func jumpToMatch(_ match: ComicTextMatch) {
        guard let provider = provider else { return }
        let target = pagination(pageCount: provider.pageCount).realigned(match.pageIndex)
        turnStyle = tapPageTurnStyle
        turnDirection = target > currentPage ? 1 : -1
        withAnimation(.easeInOut(duration: 0.2)) {
            currentPage = target
        }
        isFindPresented = false
    }

    private func confirmPageJump() {
        guard let provider = provider else { return }
        let target = pagination(pageCount: provider.pageCount).realigned(jumpPageNumber - 1)
        turnStyle = tapPageTurnStyle
        turnDirection = target > currentPage ? 1 : -1
        withAnimation(.easeInOut(duration: 0.2)) {
            currentPage = target
        }
        isPageJumpPresented = false
    }

    private func purgePageCache() {
        guard let pageCache else { return }
        Task { await pageCache.purge() }
    }

    /// Prefetch around the current page, on both platforms.
    private func prefetchAroundCurrentPage(provider: ComicPageProvider) async {
        guard let pageCache else { return }
        // Must match the `proxy.size` that `PageView.loadImage` will actually use: in
        // double page each `PageView` takes up about half the viewport's width
        // (HStack(spacing: 0) in `PageSpreadView`), not the whole viewport. Without this,
        // `ProcessingOptions` never matches between prefetch and the real request, and the
        // cache misses on every page — exactly in the mode (double page + upscaling) where
        // it costs the most.
        let pageTargetSize = effectiveDoublePage
            ? CGSize(width: viewportSize.width / 2, height: viewportSize.height)
            : viewportSize
        let options = PageImageCache.ProcessingOptions(
            autoCrop: isAutoCropEnabled,
            autoTintContrast: isAutoTintContrastEnabled,
            upscaleTargetSize: isUpscalingEnabled ? pageTargetSize : nil
        )
        await pageCache.prefetch(around: currentPage, radius: 3, pageCount: provider.pageCount, options: options)
    }

    #if os(macOS)
    /// The current page (or spread), with the last page change's transition.
    ///
    /// The order of the two `.environment` calls is deliberate: the outer one applies to
    /// the transition layer, so `.move(edge:)`'s edges always resolve in LTR and we decide
    /// the direction ourselves in `pageTurnTransition`; the inner one mirrors the spread for manga.
    private func pagerContent(provider: ComicPageProvider) -> some View {
        PageSpreadView(provider: provider, leadingIndex: currentPage, pagination: pagination(pageCount: provider.pageCount), isZoomed: $isZoomed, imageCache: pageCache)
            .environment(\.layoutDirection, comic.readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
            .id(currentPage)
            .transition(pageTurnTransition)
            .environment(\.layoutDirection, .leftToRight)
            // Started as soon as `currentPage` changes, not inside `PageView.onAppear`: this
            // way prefetch starts right away, in parallel with the transition animation,
            // instead of waiting for the incoming page to request it.
            .task(id: currentPage) {
                await prefetchAroundCurrentPage(provider: provider)
            }
    }

    /// Translates the style of the gesture that triggered the change into the corresponding
    /// transition: side slide, fade or hard cut (for "Immediate" the animation is already
    /// disabled in `step`, here it's enough to add no effects).
    private var pageTurnTransition: AnyTransition {
        switch turnStyle {
        case .fade:
            return .opacity
        case .slide:
            // The page with the higher index is on the right in LTR and on the left in
            // manga: that's where it must enter from when the index increases, and from
            // the opposite side when it decreases.
            let indexIncreasing = turnDirection > 0
            let rightToLeft = comic.readingDirection == .rightToLeft
            let entering: Edge = (indexIncreasing != rightToLeft) ? .trailing : .leading
            return .asymmetric(
                insertion: .move(edge: entering),
                removal: .move(edge: entering == .trailing ? .leading : .trailing)
            )
        case .immediate, .disabled:
            return .identity
        }
    }

    #endif

    #if os(iOS)
    /// When the swipe must follow the finger, `TabView(.page)` is used: `UIPageViewController`'s
    /// interactive paging doesn't complete the transition within this hierarchy (the pan
    /// starts, the dataSource returns the neighbouring page, but `didFinishAnimating` never
    /// arrives — also verified with the content reduced to a solid color, so it's not the
    /// fault of the page's gestures or the overlays). TabView, on the other hand, works, at
    /// the cost of not being able to replace its own slide animation.
    ///
    /// For the other styles that's exactly what's needed: "Immediate" and "Fade" can't be
    /// represented by a continuous drag, so there gesture-driven paging is switched off, the
    /// swipe is recognized as a discrete gesture and the page turns programmatically with
    /// the right animation — something `PageTurnPager` can do and TabView can't.
    @ViewBuilder
    private func iOSPager(provider: ComicPageProvider) -> some View {
        // A single pager for all styles. There used to be two: `TabView(.page)` when swipe
        // and tap were both "Scroll", programmatic pager otherwise. TabView fell because it
        // can't suspend its own scrolling when the page is zoomed in, so dragging to pan
        // around the zoomed page changed the page.
        //
        // `PageCollectionPager` suspends scrolling with `isScrollEnabled`, which is a
        // property and not a remount: `UIPageViewController`, for the same thing, forced you
        // to detach the `dataSource`, and therefore to reconfigure its own gesture
        // recognizers while the finger was still on the screen.
        Group {
            programmaticPager(provider: provider)
        }
        // At the whole pager's level, not inside `PageView.onAppear`: starts right away on
        // a page change, in parallel with any animation, instead of waiting for the
        // incoming page to request it — same reason it's on `pagerContent` on macOS.
        .task(id: currentPage) {
            await prefetchAroundCurrentPage(provider: provider)
        }
        // Same shortcuts as the "Go to" menu on Mac (`ChunkyCommands`), but via `onKeyPress`
        // instead of `.commands`: on iPad there's no menu bar to populate, and `.commands`
        // would still need the same `.focusedSceneValue` infrastructure already designed
        // for the Mac's multiple windows, useless here with a single scene. Only useful
        // with an external keyboard connected; nothing changes for touch.
        .onKeyPress(.leftArrow) {
            step(-1, provider: provider, style: tapPageTurnStyle)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(1, provider: provider, style: tapPageTurnStyle)
            return .handled
        }
        .onKeyPress(.space) {
            step(1, provider: provider, style: tapPageTurnStyle)
            return .handled
        }
    }

    /// Same options `tapZonesOrControlsToggle` builds for `PageTapZones`, handed down to the
    /// zoom coordinators too — see `PageSpreadView.tapZoneOptions`.
    private var tapZoneOptions: PageTapZoneGeometry.Options {
        PageTapZoneGeometry.Options(
            oneHanded: isOneHandedModeEnabled,
            oneHandedReversed: isOneHandedZonesReversed,
            rightToLeft: comic.readingDirection == .rightToLeft,
            hotCorners: isHotCornersEnabled,
            zonesEnabled: tapPageTurnStyle != .disabled,
            // The pager these zones cover ignores the safe area (see `iOSPager`), so its
            // coordinate space starts at the true top/bottom of the screen — a header/footer
            // positioned the normal, safe-area-respecting way sits `PlatformSafeArea.topInset`/
            // `bottomInset` points further in, not right at that origin. Without adding it
            // here, a tap in that gap (visually right on the header/footer) fell through to
            // the ordinary page-turn zones underneath. The footer doesn't need the same
            // treatment: it already extends its own frame down to that true edge (see
            // `footer`'s `.offset`/`PlatformSafeArea.bottomInset` padding), so the measured
            // `footerHeight` reaches it too.
            topInset: isControlsVisible ? headerHeight + PlatformSafeArea.topInset : 0,
            bottomInset: isControlsVisible ? footerHeight : 0
        )
    }

    private func pageContent(provider: ComicPageProvider, start: Int) -> some View {
        PageSpreadView(provider: provider, leadingIndex: start, pagination: pagination(pageCount: provider.pageCount), isZoomed: $isZoomed, imageCache: pageCache, isActive: start == currentPage, tapZoneOptions: tapZoneOptions)
            .environment(\.layoutDirection, comic.readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }

    /// The tap zones are mounted once here, as a sibling of the pager, not inside each page's
    /// content: `pageContent` is rebuilt per spread start, and the pager keeps 2-3 of them
    /// alive at once for smooth swiping, so one `PageTapZones` per page meant that many
    /// `TapZoneRelay` coordinators alive simultaneously — each with its own window-attached
    /// recognizer and its own tap-debounce state (see `TapZoneRelay.Coordinator`). That state
    /// needs to outlive a single tap's disambiguation window; a per-page coordinator doesn't
    /// reliably: `PageCollectionPager.refreshVisibleContent()` reconfigures visible cells'
    /// content on every page change, which tears down and rebuilds that page's `PageTapZones`
    /// — silently dropping a tap still waiting out its window. Measured live: tap the center
    /// band right after a page change and the pending "toggle controls" never fires.
    ///
    /// Mounting it once instead is safe here even though `pageContent` no longer overlays it:
    /// the historical reason for nesting it inside the content (an overlaid sibling stealing
    /// every touch via `hitTest`, see the old comment this replaced) doesn't apply to this
    /// window-relay implementation — `RelayView.hitTest` already always returns `nil`, so it
    /// was never "on top" for hit-testing purposes regardless of where in the tree it lives.
    /// macOS's own `PageTapZones` has always been mounted this way, as a pager sibling.
    private func programmaticPager(provider: ComicPageProvider) -> some View {
        let isInteractiveSwipe = swipePageTurnStyle == .slide && !isZoomed
        return ZStack {
            PageCollectionPager(
                starts: spreadStarts(pageCount: provider.pageCount),
                selection: $currentPage,
                rightToLeft: comic.readingDirection == .rightToLeft,
                turnStyle: turnStyle,
                interactiveSwipe: isInteractiveSwipe,
                resetToken: PagerResetToken(
                    doublePage: effectiveDoublePage,
                    rightToLeft: comic.readingDirection == .rightToLeft,
                    pageCount: provider.pageCount
                ),
                fadeDuration: fadeTransitionDuration
            ) { start in
                pageContent(provider: provider, start: start)
            }

            if !isInteractiveSwipe && swipePageTurnStyle != .disabled && !isZoomed {
                discreteSwipeCatcher(provider: provider)
            }

            tapZonesOrControlsToggle(provider: provider)
        }
    }

    /// Recognizes the swipe as a discrete gesture (threshold exceeded = one page) for the
    /// styles that interactive paging can't render. `simultaneousGesture` so as not to steal
    /// the touch from the tap zones underneath.
    private func discreteSwipeCatcher(provider: ComicPageProvider) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height),
                              abs(value.translation.width) > 60 else { return }
                        step(value.translation.width < 0 ? 1 : -1, provider: provider, style: swipePageTurnStyle)
                    }
            )
    }

    private func tapZonesOrControlsToggle(provider: ComicPageProvider) -> some View {
        PageTapZones(
            oneHanded: isOneHandedModeEnabled,
            oneHandedReversed: isOneHandedZonesReversed,
            hotCorners: isHotCornersEnabled,
            zonesEnabled: tapPageTurnStyle != .disabled,
            rightToLeft: comic.readingDirection == .rightToLeft,
            // See the identical comment on `tapZoneOptions`.
            topInset: isControlsVisible ? headerHeight + PlatformSafeArea.topInset : 0,
            bottomInset: isControlsVisible ? footerHeight : 0,
            isZoomed: isZoomed
        ) {
            // With "Tap-to-pan" the "back" zone also advances: handy if you can't
            // comfortably reach both sides of the screen. Ignored while one-handed mode is
            // on: there both zones already share one action (`PageTapZoneGeometry.action`'s
            // `sharedAction`, following `isOneHandedZonesReversed`) for the same "can't
            // reach both sides" reason, so this would otherwise silently fight that choice
            // — turning "one-handed, reversed" (meant to send both zones back) into "both
            // zones forward" behind the user's back, with no indication why.
            step(isTapToPanEnabled && !isOneHandedModeEnabled ? 1 : -1, provider: provider, style: tapPageTurnStyle)
        } onNext: {
            step(1, provider: provider, style: tapPageTurnStyle)
        } onToggleControls: {
            toggleControls()
        } onExit: {
            exitReader()
        } onOpenSettings: {
            isToolsPresented = true
        } onToggleDoublePage: {
            if isDoublePageAllowed { isDoublePageEnabled.toggle() }
        }
    }
    #else
    private func macOSPager(provider: ComicPageProvider) -> some View {
        ZStack {
            pagerContent(provider: provider)

            if tapPageTurnStyle != .disabled {
                PageTapZones(oneHanded: isOneHandedModeEnabled, oneHandedReversed: isOneHandedZonesReversed, hotCorners: isHotCornersEnabled, rightToLeft: comic.readingDirection == .rightToLeft) {
                    step(-1, provider: provider, style: tapPageTurnStyle)
                } onNext: {
                    step(1, provider: provider, style: tapPageTurnStyle)
                } onToggleControls: {
                    toggleControls()
                } onExit: {
                    exitReader()
                } onOpenSettings: {
                    isToolsPresented = true
                } onToggleDoublePage: {
                    if isDoublePageAllowed { isDoublePageEnabled.toggle() }
                }
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
            }
        }
        .background(ScrollSwipeMonitor { direction in
            guard swipePageTurnStyle != .disabled, !isZoomed else { return }
            step(direction, provider: provider, style: swipePageTurnStyle)
        })
        // Published only while this view is alive, so only while a reader window is really
        // on stage — no parental-lock filter here, because with `lock.isLocked`
        // `ReaderWindowContainer` shows `ParentalLockGateView` instead of `ReaderView`, so
        // this code simply isn't mounted at all.
        .focusedSceneValue(\.readerActions, ReaderCommandActions(
            previousPage: { step(-1, provider: provider, style: tapPageTurnStyle) },
            nextPage: { step(1, provider: provider, style: tapPageTurnStyle) }
        ))
    }
    #endif

    /// Moves forward/back by one spread, respecting the current reading direction (manga =
    /// reversed). `style` is that of the gesture that triggered the change (tap or
    /// swipe/keyboard have independent settings) and decides the animation, rendered by
    /// `pageTurnTransition`. When the native pager is active (swipe and tap both on
    /// "Scroll") the swipe's slide doesn't go through here: the TabView handles it by
    /// following the finger.
    private func step(_ direction: Int, provider: ComicPageProvider, style: TapPageTurnStyle) {
        switch pagination(pageCount: provider.pageCount).step(from: currentPage, direction: direction) {
        case .endReached(let triggersNextComic):
            if triggersNextComic, let candidate = nextComicInLibrary {
                pendingNextComic = candidate
            }
        case .beginningReached:
            break
        case .page(let next):
            resetIdleTimerIfNeeded()
            turnStyle = style
            turnDirection = next > currentPage ? 1 : -1
            switch style {
            case .immediate:
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { currentPage = next }
            default:
                withAnimation(.easeInOut(duration: 0.2)) { currentPage = next }
            }
        }
    }

    private func toggleControls() {
        resetIdleTimerIfNeeded()
        withAnimation(.easeInOut(duration: 0.22)) {
            isControlsVisible.toggle()
        }
    }

    /// "Showcase/kiosk" timer: if the reader stays inactive for the time chosen in
    /// Settings, it automatically returns to page 1. Every interaction (tap, page change)
    /// restarts it.
    private func resetIdleTimerIfNeeded() {
        idleResetWorkItem?.cancel()
        guard readerIdleReset.rawValue > 0 else { return }
        let workItem = DispatchWorkItem {
            turnStyle = tapPageTurnStyle
            turnDirection = -1
            withAnimation(.easeInOut(duration: 0.2)) { currentPage = 0 }
        }
        idleResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(readerIdleReset.rawValue), execute: workItem)
    }

    /// The comic after the current one in the order shown in the library, if it exists.
    private var nextComicInLibrary: ComicEntity? {
        guard let index = libraryComics.firstIndex(where: { $0.objectID == comic.objectID }) else { return nil }
        let nextIndex = index + 1
        guard nextIndex < libraryComics.count else { return nil }
        return libraryComics[nextIndex]
    }

    /// Confirmation card shown at the end of reading: explicitly asks whether to open the
    /// next comic in the library, showing its cover and title before proceeding.
    private func nextComicConfirmation(_ next: ComicEntity) -> some View {
        VStack(spacing: 16) {
            Text("Fine del fumetto")
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 12) {
                ComicGridItemView(comic: next)
                    .frame(width: 90, height: 135)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continuare con:")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Text(next.title ?? "")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Button(action: { pendingNextComic = nil }) {
                    Text("Annulla")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                Button(action: { switchToComic(next) }) {
                    Text("Apri")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(Color.black.opacity(0.85))
        .cornerRadius(16)
    }

    private func switchToComic(_ next: ComicEntity) {
        pendingNextComic = nil
        onSwitchComic(next)
    }

    #if os(iOS)
    /// Brightness indicator during the two-finger gesture: same role as the system HUD
    /// (which doesn't appear when the app changes the brightness), i.e. showing that the
    /// gesture is working and at what level it has reached.
    private func brightnessIndicator(level: Double) -> some View {
        VStack(spacing: 10) {
            Image(systemName: level < 0.35 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 30))
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 8, height: 120)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 8, height: max(4, 120 * level))
                }
        }
        .foregroundColor(.white)
        .padding(.vertical, 22)
        .padding(.horizontal, 26)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func applyBrightnessDelta(_ delta: CGFloat) {
        let base = brightnessTarget ?? UIScreen.current?.brightness ?? 1
        let level = min(max(base + delta, 0), 1)
        brightnessTarget = level
        UIScreen.current?.brightness = level
        showBrightnessIndicator(level)
    }

    private func showBrightnessIndicator(_ level: CGFloat) {
        withAnimation(.easeOut(duration: 0.12)) { brightnessLevel = Double(level) }
        brightnessHideToken &+= 1
        let token = brightnessHideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard brightnessHideToken == token else { return }
            withAnimation(.easeOut(duration: 0.25)) { brightnessLevel = nil }
            brightnessTarget = nil
        }
    }
    #endif

    private var findButton: some View {
        Button(action: presentFind) {
            Image(systemName: "text.magnifyingglass").frame(width: 44, height: 44)
        }
    }

    /// Control bars, with the measurement of their height on iOS: needed by the tap zones
    /// so they don't react to touches that fall on the bars (see `PageTapZones.topInset`).
    /// A separate property rather than inline in the `body` because the reader's body is
    /// already at the limit of what the compiler can infer in a reasonable time.
    private var controlsChrome: some View {
        VStack {
            #if os(iOS)
            // The footer isn't here: it's a direct sibling of `controlsChrome` in the
            // outer `ZStack` instead (see `readerContent`), in its own `VStack`+`Spacer`
            // positioned at the bottom — a `VStack` sibling of `header` inside *this* one
            // wouldn't reach past the safe area no matter what's applied to it, since
            // `Spacer` only ever pushes it up to the edge of the safe frame, not past it.
            header
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ChromeHeightKey.self, value: proxy.size.height)
                })
                .onPreferenceChange(ChromeHeightKey.self) { headerHeight = $0 }
            Spacer()
            #else
            header
            Spacer()
            footer
            #endif
        }
    }

    /// Leading icon group, isolated so its width can be measured (see `header`).
    private var headerLeadingActions: some View {
        HStack(spacing: 2) {
            Button(action: exitReader) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Libreria")
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(minHeight: 44)
            }
            // Crop: opens the panel selection (an area is always selected, there's no
            // separate "share the whole page" button).
            Button(action: { isPanelSelectionPresented = true }) {
                Image(systemName: "ellipsis.bubble").frame(width: 44, height: 44)
            }
            // Search the pages' text (OCR, or the text layer if the file is a native PDF).
            // On iPhone in compact width the icon doesn't appear here: a third icon on the
            // left would leave the title very little room, so it lives in the "..." menu
            // like the other actions that don't fit there (same choice as
            // `headerTrailingActions`).
            #if os(iOS)
            if horizontalSizeClass != .compact {
                findButton
            }
            #else
            findButton
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            headerLeadingActions
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: HeaderLeadingWidthKey.self, value: proxy.size.width)
                })
                // Reserves the wider group's width on both flanks (see
                // `HeaderLeadingWidthKey`), so the title below lands on the bar's true
                // center instead of the midpoint between two differently-sized groups.
                .frame(minWidth: max(headerLeadingWidth, headerTrailingWidth), alignment: .leading)
            Spacer(minLength: 4)
            // Comic info (go-to-page/favorites/reading direction): long press on the
            // title, so as not to add another icon to the header. Dropdown Menus with
            // interactive content are unreliable on this target (see ToolsPanelView).
            Text(comic.title ?? "")
                .font(.subheadline.bold())
                .lineLimit(1)
                .onLongPressGesture { isInfoPresented = true }
            Spacer(minLength: 4)
            headerTrailingActions
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: HeaderTrailingWidthKey.self, value: proxy.size.width)
                })
                .frame(minWidth: max(headerLeadingWidth, headerTrailingWidth), alignment: .trailing)
        }
        .onPreferenceChange(HeaderLeadingWidthKey.self) { headerLeadingWidth = $0 }
        .onPreferenceChange(HeaderTrailingWidthKey.self) { headerTrailingWidth = $0 }
        .foregroundColor(chromeForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        // Extends the material into the status bar's area instead of stopping at the safe
        // area, so the bar reaches the true top edge instead of leaving a gap of bare
        // background above it — the content itself (buttons, title) still respects the
        // safe area via normal layout, only the background reaches further.
        .background(chromeBackground.ignoresSafeArea(edges: .top))
        // The system material follows the current scheme: here we force the one consistent
        // with "Page background" (black/white/auto), as chromeForeground already does for
        // text/icons.
        .environment(\.colorScheme, isBackgroundDark ? .dark : .light)
        .buttonStyle(PlainButtonStyle())
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// The header's 4 trailing icons when there's room to show them individually (iPad,
    /// Mac, iPhone in landscape) — shared by both branches of `headerTrailingActions`.
    ///
    /// An `HStack`, not a `Group`: `header` wraps this in `.frame(minWidth:alignment:)` to
    /// reserve the wider of the two icon groups' width and keep the title centered (see
    /// `HeaderLeadingWidthKey`) — a `Group`'s children are spliced directly into the parent
    /// `HStack` instead of staying together as one view, so that `.frame` modifier ended up
    /// applied to each icon *individually*, inflating each one to that width on its own and
    /// spreading them apart with large gaps instead of keeping them clustered together.
    private var expandedTrailingActions: some View {
        HStack(spacing: 2) {
            newComicsButton
            nowReadingButton
            Button(action: { isAccountsPresented = true }) {
                Image(systemName: "cloud").frame(width: 44, height: 44)
            }
            Button(action: { isToolsPresented = true }) {
                Image(systemName: "wrench.and.screwdriver").frame(width: 44, height: 44)
            }
        }
    }

    /// On iPhone (compact width) the header's 4 trailing icons don't fit comfortably: we
    /// gather them into a single "..." menu. The reader doesn't live in a NavigationStack
    /// (see header/chromeBackground above), so there's no real system toolbar here that
    /// collapses on its own: the trigger is manual, based on horizontalSizeClass. On
    /// iPad/Mac the individual icons remain, unchanged.
    @ViewBuilder
    private var headerTrailingActions: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            Menu {
                Button(action: presentFind) {
                    Label("Cerca nel testo", systemImage: "text.magnifyingglass")
                }
                Button(action: { isNewComicsPresented = true }) {
                    Label("Nuovi fumetti", systemImage: "envelope")
                }
                if lastReadComic != nil {
                    Button(action: { isNowReadingPresented = true }) {
                        Label("Ora in lettura", systemImage: "book")
                    }
                }
                Button(action: { isAccountsPresented = true }) {
                    Label("Account", systemImage: "cloud")
                }
                Button(action: { isToolsPresented = true }) {
                    Label("Strumenti", systemImage: "wrench.and.screwdriver")
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
            }
            .popover(isPresented: $isNewComicsPresented) {
                NewComicsView(comics: recentComics) {
                    isNewComicsPresented = false
                    if $0 != comic { onSwitchComic($0) }
                } onClear: {
                    newTrayClearedAtTimestamp = Date().timeIntervalSince1970
                    isNewComicsPresented = false
                }
            }
            .popover(isPresented: $isNowReadingPresented) {
                if let lastRead = lastReadComic {
                    NowReadingView(comic: lastRead) {
                        isNowReadingPresented = false
                        if lastRead != comic { onSwitchComic(lastRead) }
                    }
                }
            }
        } else {
            expandedTrailingActions
        }
        #else
        expandedTrailingActions
        #endif
    }

    /// Comics imported in the last 7 days, as in the library (same "Clear" key shared via
    /// @AppStorage). Empty if the reader is opened without a library context.
    private var recentComics: [ComicEntity] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let clearedAt = Date(timeIntervalSince1970: newTrayClearedAtTimestamp)
        let effectiveCutoff = max(cutoff, clearedAt)
        return libraryComics
            .filter { ($0.dateAdded ?? .distantPast) > effectiveCutoff }
            .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
    }

    private var newComicsButton: some View {
        Button(action: { isNewComicsPresented = true }) {
            Image(systemName: "envelope").frame(width: 44, height: 44)
        }
        .popover(isPresented: $isNewComicsPresented) {
            NewComicsView(comics: recentComics) {
                isNewComicsPresented = false
                if $0 != comic { onSwitchComic($0) }
            } onClear: {
                newTrayClearedAtTimestamp = Date().timeIntervalSince1970
                isNewComicsPresented = false
            }
        }
    }

    /// The most recently opened comic in the library, as in the button of the same name there.
    private var lastReadComic: ComicEntity? {
        libraryComics
            .filter { $0.dateLastOpened != nil }
            .max { ($0.dateLastOpened ?? .distantPast) < ($1.dateLastOpened ?? .distantPast) }
    }

    @ViewBuilder
    private var nowReadingButton: some View {
        if let lastRead = lastReadComic {
            Button(action: { isNowReadingPresented = true }) {
                Image(systemName: "book").frame(width: 44, height: 44)
            }
            .popover(isPresented: $isNowReadingPresented) {
                NowReadingView(comic: lastRead) {
                    isNowReadingPresented = false
                    if lastRead != comic { onSwitchComic(lastRead) }
                }
            }
        }
    }

    private var footer: some View {
        Group {
            if let provider = provider, provider.pageCount > 1 {
                // Real end of the current spread, i.e. the start of the next one: `pageStep`
                // is 2 for double page throughout, but with "cover alone" the first spread
                // contains just one, and the label used to announce "1–2" while only the
                // cover was on screen. Same thing for the last page of a comic with an odd
                // page count.
                let upperBound = spreadStarts(pageCount: provider.pageCount)
                    .first(where: { $0 > currentPage }) ?? provider.pageCount
                let label = upperBound - currentPage > 1
                    ? "\(currentPage + 1)–\(upperBound) / \(provider.pageCount)"
                    : "\(currentPage + 1) / \(provider.pageCount)"
                // Column width computed on the worst case ("100–101 / 164"), not on the
                // current label: fixed avoids the slider jumping on every page, but it must
                // grow with the digit count and with double page, otherwise the label wraps.
                let digits = String(provider.pageCount).count
                let labelChars = effectiveDoublePage ? digits * 3 + 4 : digits * 2 + 3
                let labelWidth = max(70, CGFloat(labelChars) * 7 + 8)
                HStack(spacing: 4) {
                    // Fixed-width column: the page number's width varies (e.g. "1 / 20" vs
                    // "10–11 / 20") and without pre-allocating the space, the slider next to
                    // it would shift every time the page changes.
                    //
                    // The whole column is one tap target, not just the chevron: swaps which
                    // half (top/bottom) advances/goes back in one-handed mode. A `Button`
                    // wrapping both, not a separate one on just the small icon — the label
                    // alone was an easy-to-miss target compared to the rest of the bar.
                    Button(action: { isOneHandedZonesReversed.toggle() }) {
                        VStack(spacing: 2) {
                            Text(label)
                                .font(.callout.monospacedDigit())
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .rotationEffect(.degrees(isOneHandedZonesReversed ? 180 : 0))
                        }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .frame(width: labelWidth, height: 44)
                    pageSlider(provider: provider)
                    if isDoublePageAllowed {
                        // Cycles single → double → automatic page.
                        Button(action: cyclePageLayoutMode) {
                            Image(systemName: pageLayoutModeIconName)
                                .font(.footnote.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(chromeForeground.opacity(0.7), lineWidth: 1)
                                        .frame(width: 26, height: 20)
                                )
                        }
                    }
                }
                .foregroundColor(chromeForeground)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                #if os(iOS)
                // Extra bottom padding equal to the home indicator's own height, so the
                // row's total height covers it, plus an equal `.offset` to push the whole
                // taller row down by that same amount. Neither `.ignoresSafeArea` nor
                // `.safeAreaInset` reach the true bottom edge here — confirmed with a
                // `GeometryReader` on every full-bleed view in `readerContent`, with and
                // without `StatusBarControllingHost` in the loop: `.fullScreenCover` itself
                // never proposes more than the safe-area-inset frame, on this iPad, no
                // matter what the content asks for. `.offset` sidesteps that entirely: it
                // moves the already-laid-out view, not a size/position *request* that layout
                // gets to cap. The padding keeps the row's own content (buttons, slider)
                // sitting where it always did — only the background grows to follow it down.
                .padding(.bottom, 4 + PlatformSafeArea.bottomInset)
                #else
                .padding(.bottom, 4)
                #endif
                .frame(maxWidth: .infinity)
                .background(chromeBackground)
                #if os(iOS)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ChromeFooterHeightKey.self, value: proxy.size.height)
                })
                .onPreferenceChange(ChromeFooterHeightKey.self) { footerHeight = $0 }
                .offset(y: PlatformSafeArea.bottomInset)
                #endif
                .environment(\.colorScheme, isBackgroundDark ? .dark : .light)
                .buttonStyle(PlainButtonStyle())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var pageLayoutModeIconName: String {
        if isDoublePageAutoMode { return "a.square" }
        return isDoublePageEnabled ? "square.split.2x1" : "square"
    }

    private func cyclePageLayoutMode() {
        if isDoublePageAutoMode {
            isDoublePageAutoMode = false
            isDoublePageEnabled = false
        } else if !isDoublePageEnabled {
            isDoublePageEnabled = true
        } else {
            isDoublePageAutoMode = true
        }
    }

    private func pageSlider(provider: ComicPageProvider) -> some View {
        let maxValue = Double(max(provider.pageCount - 1, 0))
        let isRTL = comic.readingDirection == .rightToLeft
        // We don't use the system Slider: overlaid on TabView(.page), its internal pan
        // gesture loses the arbitration against the page's scroll gesture (the page turns
        // instead of dragging the thumb — verified live, the thumb stays still while the
        // pager shows the swipe indicators). A high-priority DragGesture always wins over
        // the underlying swipe gesture.
        return GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = maxValue > 0 ? CGFloat(currentPage) / CGFloat(maxValue) : 0
            let thumbX = isRTL ? width * (1 - progress) : width * progress

            ZStack(alignment: .leading) {
                Capsule().fill(chromeForeground.opacity(0.25))
                Capsule().fill(chromeForeground).frame(width: width * progress)
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity, alignment: .center)

            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .shadow(radius: 1)
                .position(x: thumbX, y: proxy.size.height / 2)
                .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard maxValue > 0 else { return }
                            let fraction = min(max(value.location.x / width, 0), 1)
                            let target = Int((Double(isRTL ? 1 - fraction : fraction) * maxValue).rounded())
                            let starts = spreadStarts(pageCount: provider.pageCount)
                            // Dragging the thumb crosses many pages in a row: animating
                            // them one by one would be slow and jerky.
                            turnStyle = .immediate
                            currentPage = starts.min(by: { abs($0 - target) < abs($1 - target) }) ?? 0
                        }
                )
        }
        .frame(height: 24)
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }

    /// Shown while the comic is being downloaded from iCloud: real percentage and the
    /// ability to cancel without having to go through the Downloads screen.
    @ViewBuilder
    private func downloadOverlay(progress: Double) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.largeTitle)
                .foregroundColor(chromeForeground)
            Text(comic.title ?? "Fumetto")
                .foregroundColor(chromeForeground)
                .multilineTextAlignment(.center)
            ProgressView(value: progress)
                .frame(maxWidth: 240)
            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundColor(chromeForeground.opacity(0.7))
            Button(action: { downloadItem?.cancel() }) {
                Text("Annulla")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.25))
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 32)
    }

    private func toggleReadingDirection() {
        comic.readingDirection = comic.readingDirection == .rightToLeft ? .leftToRight : .rightToLeft
        try? context.save()
    }

    private func loadComic() {
        // `onAppear` can fire more than once on the same view, and for an iCloud placeholder
        // the opening now only arrives once the download is finished: without this guard the
        // second pass would hook a second callback onto the same transfer and open the
        // archive twice.
        guard provider == nil, !isLoadingComic else { return }
        isLoadingComic = true
        let url = LibraryStorage.fileURL(forRelativePath: comic.relativePath ?? "")
        let format = comic.format
        let startingPage = Int(comic.lastReadPage)

        // The saved page must be restored *before* the pager exists, not when the provider
        // arrives: the pager builds itself by reading currentPage, so if it finds it still
        // at 0 and then sees it change right after, it runs a programmatic scroll toward the
        // right page — and the user's first swipe, which lands right inside that settling,
        // gets lost (verified: opening at page 1, where there's nothing to restore, the
        // first swipe works). Here the page count isn't known yet: alignment to the spread
        // start happens afterward, and it's a no-op in single page.
        currentPage = max(0, startingPage)

        // The iCloud download can take more than a few seconds (large files, slow
        // connection): it goes through `ComicDownloadService`, which registers it in the
        // Downloads tab with real progress instead of failing the reader after a fixed timeout.
        downloadItem = ComicDownloadService.downloadIfNeeded(comic: comic) { progress in
            downloadProgress = progress
        } completion: { error in
            downloadItem = nil
            downloadProgress = nil
            if let error = error {
                isLoadingComic = false
                loadError = error.localizedDescription
                return
            }
            openProvider(at: url, format: format, startingPage: startingPage)
        }
    }

    /// Opens the archive and builds the pager. Kept separate from `loadComic` because when
    /// the comic is an iCloud placeholder it only arrives after the download, not right away.
    private func openProvider(at url: URL, format: ComicFormat, startingPage: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try ComicPageProviderFactory.makeProvider(for: url, format: format)
                DispatchQueue.main.async {
                    isLoadingComic = false
                    provider = loaded
                    pageCache = PageImageCache(provider: loaded)
                    let clampedStart = min(startingPage, max(0, loaded.pageCount - 1))
                    let starts = spreadStarts(pageCount: loaded.pageCount)
                    let aligned = starts.last(where: { $0 <= clampedStart }) ?? 0
                    // Restoring the saved position: it must be a hard jump, not an animated
                    // page change (and `setPageWithoutAnimation` does nothing if the
                    // restored page was already a valid spread start).
                    setPageWithoutAnimation(aligned)
                    if comic.pageCount == 0 {
                        comic.pageCount = Int32(loaded.pageCount)
                        try? context.save()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isLoadingComic = false
                    loadError = error.localizedDescription
                }
            }
        }
    }
}

/// Measured width of the header's leading button group (see `ReaderView.header`): the
/// leading and trailing groups don't have the same number of icons (more on iPad/landscape,
/// where they're not collapsed into a menu), so an ordinary `HStack` with a `Spacer` on
/// each side of the title leaves it visibly off-center — verified live, exactly the "is the
/// title centered?" report. Reserving the wider group's width on both sides (see `header`)
/// keeps the title centered on the bar as a whole instead of centered between whatever
/// the two groups happen to measure. Not gated to iOS: `header` is shared with macOS.
struct HeaderLeadingWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// See `HeaderLeadingWidthKey`: separate key for the same reason `ChromeFooterHeightKey` is
/// separate from `ChromeHeightKey`.
struct HeaderTrailingWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

#if os(iOS)
/// Measured height of the top control bar (see `ReaderView.headerHeight`).
struct ChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Like `ChromeHeightKey`, for the bottom bar: two distinct keys because the two
/// measurements travel through the same tree and a single one would merge them together.
struct ChromeFooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
#endif
