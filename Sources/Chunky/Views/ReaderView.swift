import SwiftUI
import CoreData
import Combine
#if os(macOS)
import AppKit
#endif

#if os(tvOS)
extension View {
    /// Sizing for a header/footer icon on tvOS. No custom background: `.buttonStyle(.automatic)`
    /// already draws its own resting-state backdrop, and adding another produced two nested shapes.
    func readerTVIconChip() -> some View {
        frame(width: 60, height: 60)
    }
}
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

struct ReaderContentView: View {
    @ObservedObject var comic: ComicEntity
    /// List (in the same order shown in the library) used to propose "the next comic" once
    /// reading is finished. Empty if the reader is opened without a library context.
    var libraryComics: [ComicEntity] = []
    let onSwitchComic: (ComicEntity) -> Void
    @Environment(\.managedObjectContext) private var context
    @ReaderDismiss private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    // On Mac the reader lives in its own window (WindowGroup(for: ComicID.self)), not in a
    // .sheet: dismiss() there has no effect. dismissWindow() closes the window that contains
    // it, which is the real equivalent of "exit the reader" here.
    @Environment(\.dismissWindow) private var dismissWindow
    #endif
    /// Explicit single/double page choice, only valid when not in automatic mode.
    @AppStorage("doublePageMode") var isDoublePageEnabled = false
    /// In automatic mode, double page simply follows the available space (isDoublePageAllowed).
    @AppStorage("doublePageAutoMode") var isDoublePageAutoMode = true
    /// If true, the first page (usually the cover) is always shown alone even in double
    /// page, and pairing into two pages resumes from the second one.
    @AppStorage("doublePageCoverAlone") private var isCoverAlone = true
    @AppStorage("tapPageTurnStyle") var tapPageTurnStyle = TapPageTurnStyle.slide
    @AppStorage("swipePageTurnStyle") var swipePageTurnStyle = TapPageTurnStyle.slide
    /// Duration of the "Dissolvenza" (`.fade`) page-turn style's cross-dissolve — see
    /// `PageCollectionPager.fadeDuration`.
    @AppStorage("fadeTransitionDuration") var fadeTransitionDuration = 0.25
    @AppStorage("oneHandedMode") var isOneHandedModeEnabled = false
    @AppStorage("oneHandedZonesReversed") var isOneHandedZonesReversed = false
    @AppStorage("hotCornersEnabled") var isHotCornersEnabled = false
    @AppStorage("tapToPanEnabled") var isTapToPanEnabled = false
    @AppStorage("twoFingerBrightnessEnabled") private var isTwoFingerBrightnessEnabled = true
    @AppStorage("readerIdleResetSeconds") private var readerIdleReset = ReaderIdleResetOption.never
    @State private var idleResetWorkItem: DispatchWorkItem?
    /// Raised by PageView (via binding) so the pager knows whether the current page is
    /// zoomed in: with zoom active, swipe-to-change-page must be suspended, otherwise it
    /// conflicts with the drag used to move around inside the zoomed page.
    @State var isZoomed = false
    /// Style and direction of the last page change: the pager uses them to choose the
    /// transition. They're needed because the style is per-gesture (tap and swipe have
    /// independent settings), so it can't be read from AppStorage when building the view:
    /// it's necessary to know *which* gesture triggered the change.
    @State var turnStyle = TapPageTurnStyle.slide
    /// +1 = the page index increases, -1 = it decreases (already adjusted for reading direction).
    @State var turnDirection = 1
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    #if os(macOS)
    /// The pointer is over the floating page-counter HUD: it must not auto-hide from under it.
    @State var isPointerOverMacFooter = false
    /// Pending auto-hide and last pointer location — see `macPointerMoved`. A reference held in
    /// `@State`, not two `@State` values: it changes on every mouse move, and mutating a
    /// `@State` value there would re-evaluate the whole reader body at pointer rate.
    @State var macChromeIdle = MacChromeIdleState()
    static let macChromeIdleDelay: TimeInterval = 2.5
    #endif
    @ScaledMetric(relativeTo: .callout) var pageCounterCharWidth: CGFloat = 7
    @ScaledMetric(relativeTo: .callout) var pageCounterMinWidth: CGFloat = 70
    #if os(iOS)
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    /// Keeps the pager in the focus chain so `.onKeyPress` sees an iPad hardware keyboard.
    @FocusState var isIOSPagerFocused: Bool
    #endif
    #if os(macOS)
    /// Last ⌘+/⌘−/⌘0 request, handed to the visible `PageView`s via the environment.
    @State var macZoomCommand: ReaderZoomCommand?
    /// Target of a page turn whose `currentPage` assignment is deferred by `macTurnPage`:
    /// further turns requested meanwhile step from here, not from the stale `currentPage`.
    @State var macPendingTarget: Int?
    #endif

    /// Viewport dimensions, to figure out whether there's really horizontal space for
    /// double page: on iPad the size class stays "regular" even in portrait, so it isn't
    /// enough on its own to avoid wasting space (two narrow pages with black bands above/below).
    @State var viewportSize: CGSize = .zero
    @State var provider: ComicPageProvider?
    // Prefetch around the current page on both platforms: it used to be macOS-only (the iOS
    // pager has its own cache of already-built views that avoided the most visible problem,
    // rebuilding everything on every page, but never gets ahead of decoding before the user
    // pages through — every new page still starts from scratch).
    @State var pageCache: PageImageCache?
    // Duplicate the keys also read by `PageView`: needed here to invalidate the cache when
    // they change (see `.onChange` further below), not for the processing itself.
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    /// Index of the "main" page (the first one, leftmost in LTR) of the current spread.
    @State var currentPage: Int = 0
    /// Page arrived via CloudKit from another device while the reader is open and the
    /// local page hasn't followed it. Shown as a "Vai alla pagina" banner instead of
    /// jumping automatically — see `handleRemotePageChange`.
    @State var pendingRemotePage: Int?
    /// Progress this reader last recorded itself (page and `dateLastOpened`). A remote change
    /// that isn't newer than it is this device's own progress coming back stale, typically
    /// bounced off another device through the Core Data mirror: see `handleRemotePageChange`.
    @State var localProgress: (page: Int32, date: Date)?
    /// `relativePath` of an iCloud-library comic, captured at open: once deduplication deletes
    /// the row it reads back nil, and this is how the survivor is found.
    @State private var openedLibraryPath: String?
    /// Throttles `context.save()` while paging: every page turn updates `lastReadPage`
    /// in memory immediately, but persisting (and therefore enqueueing a CloudKit
    /// export transaction) happens at most every few seconds, plus a guaranteed flush
    /// on exit/background. Rapid per-page saves coalesce in the exporter's queue and
    /// paradoxically delay the upload — this is why progress seemed to leave only when
    /// returning to the library.
    @State private var pendingProgressSave: DispatchWorkItem?
    @State private var lastProgressSave = Date.distantPast
    private static let progressSaveInterval: TimeInterval = 5
    @State private var loadError: String?
    /// Progress (0...1) of the iCloud download of the comic being opened, nil if no download
    /// is in progress: the comic can always be opened, it's the opening itself that downloads it.
    @State private var downloadProgress: Double?
    /// The download in progress, so it can be cancelled directly from the reader.
    @State var downloadItem: DownloadItem?
    /// A load is in progress (iCloud download and/or opening the archive): see
    /// `loadComic`.
    @State private var isLoadingComic = false
    #if os(tvOS)
    // Without an explicit focus target, tvOS defaults focus to some header button (the
    // system requires *something* focused) and the page never receives .onMoveCommand —
    // the remote's directional pad just moves focus between chrome buttons instead of
    // turning pages.
    //
    // An enum target (not a plain Bool "is the pager focused") because just clearing the
    // pager's own focus flag on Up and letting the system pick a default next target is
    // racy: confirmed via logging that the very next directional press can still land on
    // the pager (turning a page) before the system's own fallback focus-move completes.
    // Naming this view's intended target explicitly makes the move synchronous instead of
    // hoping the system's nearest-neighbor default resolves before the next key event.
    //
    // Every header button that can receive focus needs its OWN case with its own
    // `.focused($readerFocus, equals:)` binding — not just one "header" catch-all on the
    // first button. Confirmed via logging: once real focus moves (through ordinary system
    // navigation) to a button with no binding of its own, `readerFocus` reverts to `nil`
    // (nothing currently matches either bound case), which made `isPagerFocusable` become
    // true again while focus was still genuinely on a header button — re-enabling the
    // pager's `.onMoveCommand`/tap handling underneath whatever the user was actually doing.
    enum ReaderFocusTarget: Hashable {
        case pager
        case libreria
        case info
        case layout
        // Shared by both dialogs (pageJumpCard / nextComicConfirmation) — only one is ever
        // on screen at a time, so they don't need distinct cases the way header buttons do.
        case dialogCancel
        case dialogConfirm
        // `pageJumpCard`'s −10/−1/+1/+10 stepper buttons (tvOS has no `Stepper`): bound like
        // every other reachable button so `readerFocus` never reverts to `nil` under the card.
        case dialogStep(Int)
    }
    @FocusState var readerFocus: ReaderFocusTarget?
    /// See `handleHeaderMoveCommand` — gates the header's Left/Right page-turn proxy so it
    /// only kicks in after an explicit Down, not on every Right press made while browsing
    /// between header icons.
    @State var isAwaitingPagerReturn = false
    /// Remote-driven zoom (Play/Pause toggles it, D-pad pans while zoomed, Menu exits it):
    /// tvOS has no pinch/drag, so it's applied as a plain scale+offset around the whole
    /// spread in `tvOSPager` rather than inside the shared `PageView`.
    @State var tvZoomScale: CGFloat = 1
    @State var tvZoomOffset: CGSize = .zero
    /// Pending auto-hide of the reader chrome — see `scheduleChromeAutoHide`.
    @State var chromeAutoHideWorkItem: DispatchWorkItem?
    #endif
    @State var isControlsVisible = true
    @State var isSharePresented = false
    @State private var shareImage: PlatformImage?
    @State var pendingNextComic: ComicEntity?
    @State var isPanelSelectionPresented = false
    /// Text search within the comic. The index is only created the first time the card is
    /// opened: building it when the reader opens on a comic that's never been searched
    /// would mean paying for OCR nobody asked for.
    @State var isFindPresented = false
    @State private var findQuery = ""
    @State private var textIndex: ComicTextIndex?
    @State var isPageJumpPresented = false
    @State var jumpPageNumber = 1
    @State var isInfoPresented = false
    @State var isToolsPresented = false
    @State var isAccountsPresented = false
    /// Measured widths of the header's leading/trailing icon groups, so the title between
    /// them can be reserved equal space on both sides and land on the bar's true center
    /// regardless of which group has more icons — see `HeaderLeadingWidthKey`.
    @State var headerLeadingWidth: CGFloat = 0
    @State var headerTrailingWidth: CGFloat = 0
    #if os(iOS)
    /// Measured heights of the control bars: needed by the tap zones so they don't react
    /// to touches that fall on the bars (see `PageTapZones.topInset`). Measured rather than
    /// estimated because they depend on the safe area, text size and the bars' content.
    @State var headerHeight: CGFloat = 0
    @State var footerHeight: CGFloat = 0
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
    @State var isNewComicsPresented = false
    @State var isNowReadingPresented = false
    @AppStorage("newTrayClearedAt") var newTrayClearedAtTimestamp: Double = 0
    @AppStorage("pageBackground") private var pageBackgroundRawValue = PageBackground.black.rawValue
    @Environment(\.colorScheme) private var colorScheme

    /// Two vertical pages side by side on a narrow screen leave a huge gap above and below
    /// (the combined image is too wide relative to the available height): double page only
    /// makes sense with more horizontal than vertical space. The size class alone isn't
    /// enough on iPad, where it stays "regular" even in portrait. Logic lives in
    /// `DoublePagePolicy`: on macOS there's no compact size class, so the decision always
    /// depends solely on the measured proportions.
    var isDoublePageAllowed: Bool {
        #if os(iOS)
        DoublePagePolicy.isAllowed(viewportSize: viewportSize, isCompactWidth: horizontalSizeClass != .regular)
        #else
        DoublePagePolicy.isAllowed(viewportSize: viewportSize, isCompactWidth: false)
        #endif
    }

    /// Effective double page: in automatic mode it follows the available space, otherwise the manual choice.
    var effectiveDoublePage: Bool {
        isDoublePageAutoMode ? isDoublePageAllowed : (isDoublePageEnabled && isDoublePageAllowed)
    }

    private var pageStep: Int { effectiveDoublePage ? 2 : 1 }

    func pagination(pageCount: Int) -> ReaderPagination {
        ReaderPagination(
            pageCount: pageCount,
            pageStep: pageStep,
            isRightToLeft: comic.readingDirection == .rightToLeft,
            coverIsAlone: isCoverAlone
        )
    }

    /// Start indices of each spread (1 or 2 pages), used as navigation "tags"/steps.
    func spreadStarts(pageCount: Int) -> [Int] {
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

    var isBackgroundDark: Bool {
        switch PageBackground(rawValue: pageBackgroundRawValue) ?? .black {
        case .black: return true
        case .white: return false
        case .automatic: return colorScheme == .dark
        }
    }

    /// The reader's header/footer/menu were designed for an always-black background
    /// (white text/icons on dark pills): with "Page background" now also selectable as
    /// white, these colors must adapt or they become unreadable (white on white).
    var chromeForeground: Color { isBackgroundDark ? .white : .black }

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
    var chromeBackground: Color {
        isBackgroundDark ? Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
                          : Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255)
    }

    var body: some View {
        #if os(iOS)
        // The status bar follows the controls. That only holds because nothing in the reader
        // is laid out against the safe area any more — it used to shrink the page by the
        // status bar's height instead of just revealing the bars. See
        // `StatusBarControllingHost` for why it's a view controller, not `.statusBar(hidden:)`.
        StatusBarControllingHost(isStatusBarHidden: !isControlsVisible) {
            readerContent
        }
        // Two separate insets to defeat: `safeAreaRegions` stops the hosting controller from
        // insetting its SwiftUI content, this stops SwiftUI from handing the representable a
        // frame already reduced to the safe area. Either one alone leaves the reader short.
        .ignoresSafeArea()
        #elseif os(macOS)
        // Names the window (title bar, Window menu, Mission Control) after the comic instead
        // of the generic scene title.
        readerContent
            .navigationTitle(comic.title ?? "")
            .toolbar { macReaderToolbar }
            // Mouse-idle auto-hide of the page-counter HUD (see `controlsChrome`): moving the
            // pointer over the page shows it (`PageClickZones.onPointerMoved`), a few idle
            // seconds hide it again.
            .onAppear { scheduleMacChromeAutoHide() }
            .onDisappear { macChromeIdle.hideWorkItem?.cancel() }
            .onChange(of: isPointerOverMacFooter) { _, isOver in
                if isOver { macChromeIdle.hideWorkItem?.cancel() } else { scheduleMacChromeAutoHide() }
            }
        #else
        readerContent
        #endif
    }

    private func platformViewportSize(fallback: CGSize) -> CGSize {
        #if os(iOS)
        let windowSize = PlatformSafeArea.windowSize
        return windowSize == .zero ? fallback : windowSize
        #else
        return fallback
        #endif
    }

    private var readerContent: some View {
        ZStack {
            readerBackground.ignoresSafeArea()

            // `.ignoresSafeArea()` doesn't stop `proxy.size` from still tracking the status
            // bar's height, which needlessly re-triggered `effectiveDoublePage` on every
            // controls toggle. `platformViewportSize` swaps in the stable window size instead.
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportSize = platformViewportSize(fallback: proxy.size) }
                    .onChange(of: proxy.size) { _, new in
                        viewportSize = platformViewportSize(fallback: new)
                    }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if let provider = provider {
                #if os(iOS)
                iOSPager(provider: provider)
                    .ignoresSafeArea()
                #elseif os(tvOS)
                tvOSPager(provider: provider)
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
                    #if os(tvOS)
                    // tvOSPager isn't mounted in this state, so its .onExitCommand never attaches.
                    Button("Libreria") { exitReader() }
                        .padding(.top, 8)
                    #endif
                }
                #if os(tvOS)
                .onExitCommand { exitReader() }
                #endif
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
                #if os(tvOS)
                .disabled(isInfoPresented)
                #endif

                #if os(iOS)
                // `.fullScreenCover` never proposes more than the safe-area frame here, so
                // this positions `footer` the ordinary way; its own `.offset` (see `footer`)
                // is what reaches the true bottom edge.
                VStack(spacing: 0) {
                    Spacer()
                    footer
                }
                .allowsHitTesting(true)
                #endif

                // Hint at where the tap zones to change page are (otherwise completely
                // invisible): they don't intercept touches, they're just a visual cue. tvOS has
                // no tap/click surface for page-turning at all (it's `.onMoveCommand` on the
                // remote — see `tvOSPager`), so this hint is meaningless there: confirmed via
                // on-device review it renders as pure dead visual weight, never wired to input.
                // macOS shows the arrow only while the pointer hovers a zone (`PageClickZones`).
                #if os(iOS)
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
                #endif
            }

            if let next = pendingNextComic {
                nextComicConfirmation(next)
            }

            if let remote = pendingRemotePage, provider != nil,
               !isPanelSelectionPresented && !isFindPresented && pendingNextComic == nil {
                remotePageBanner(target: remote)
            }

            if isPageJumpPresented, let provider = provider {
                pageJumpCard(provider: provider)
            }

            #if os(tvOS)
            if isInfoPresented { tvInfoOverlay }
            #endif

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
                    #if os(tvOS)
                    readerFocus = .pager
                    #endif
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
        #if os(tvOS)
        .defaultFocus($readerFocus, .pager)
        #endif
        .onAppear {
            loadComic()
            resetIdleTimerIfNeeded()
        }
        .onDisappear {
            idleResetWorkItem?.cancel()
            // Guaranteed flush of the throttled progress save: exiting right after a
            // page turn must not lose it (or leave it only in memory).
            flushPendingProgressSave()
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
            #if os(tvOS)
            resetTVZoom()
            #endif
            guard let provider = provider, provider.pageCount > 0 else { return }
            #if os(tvOS)
            // `currentPage` is the spread's *first* page: in double page the last spread
            // (n-2, n-1) never reached `pageCount - 1`, so `isFinished` stayed false and the
            // detail screen kept saying "In lettura" for a comic read to the end. Record the
            // last page actually on screen instead; restoring realigns to the spread start.
            let shownPage = pagination(pageCount: provider.pageCount).showsSecondPage(from: newValue) ? newValue + 1 : newValue
            comic.lastReadPage = Int32(min(max(shownPage, 0), provider.pageCount - 1))
            #else
            comic.lastReadPage = Int32(min(max(newValue, 0), provider.pageCount - 1))
            #endif
            let now = Date()
            comic.dateLastOpened = now
            localProgress = (comic.lastReadPage, now)
            scheduleProgressSave(page: Int(comic.lastReadPage))
            // Cross-device progress for remote-library comics (no-op for local ones):
            // `Task { @MainActor in }` because `onChange` is a synchronous context.
            Task { @MainActor in RemoteProgressSync.requestPush(comic) }
            // The user got there on their own: a pending remote banner for the same
            // page is now redundant.
            if pendingRemotePage == newValue {
                pendingRemotePage = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding without passing through `onDisappear` (e.g. Home gesture
            // mid-reading): the throttled save may still be pending.
            if phase != .active { flushPendingProgressSave() }
        }
        .onChange(of: comic.lastReadPage) { _, newRemote in
            handleRemotePageChange(Int(newRemote))
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)) { note in
            handleOpenComicDeleted(note)
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
        #if !os(tvOS)
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
        #endif
        .sheet(isPresented: $isToolsPresented) {
            ToolsPanelView()
        }
        .sheet(isPresented: $isAccountsPresented) {
            // AccountsView's own tvOS body already wraps itself in a NavigationStack (it's
            // also the tab bar's root there) — wrapping it in a second one here would nest them.
            #if os(tvOS)
            AccountsView().sheetSized()
            #else
            NavigationStack { AccountsView().toolbarDoneButton { isAccountsPresented = false } }
                .sheetSized()
            #endif
        }
        // The reader's own sheets sit above the lock screen too: closed here as well, not
        // just by dismissing the reader's cover from `LibraryView` — tearing down a cover
        // while one of its children is still presented isn't reliable mid-backgrounding.
        .onReceive(ParentalLock.shared.$isLocked.removeDuplicates().filter { $0 }) { _ in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                #if os(iOS)
                isSharePresented = false
                #endif
                isInfoPresented = false
                isToolsPresented = false
                isAccountsPresented = false
            }
        }
    }

    /// Wrench / settings hot corner. On the Mac, Settings is its own window (⌘,) with every
    /// section the iOS Tools panel links to: opening the iOS-style sheet there meant a second,
    /// differently laid-out copy of the same preferences.
    func openTools() {
        #if os(macOS)
        openWindow(id: "settings")
        #else
        isToolsPresented = true
        #endif
    }

    private func presentShareImage(_ image: PlatformImage) {
        shareImage = image
        #if os(iOS)
        isSharePresented = true
        #elseif os(macOS)
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            // Anchored at the top center, under the header, instead of a zero rect (which put
            // the picker in the window's corner, far from anything the user clicked).
            let bounds = contentView.bounds
            let anchorY = contentView.isFlipped ? bounds.minY + 44 : bounds.maxY - 44
            let anchor = NSRect(x: bounds.midX, y: anchorY, width: 1, height: 1)
            // "Below the anchor" is the max-Y edge in a flipped view, the min-Y one otherwise.
            NSSharingServicePicker(items: [image]).show(relativeTo: anchor, of: contentView, preferredEdge: contentView.isFlipped ? .maxY : .minY)
        }
        #endif
    }

    func exitReader() {
        #if os(macOS)
        dismissWindow()
        #else
        dismiss()
        #endif
    }

    func toggleFavorite() {
        comic.isFavorite.toggle()
        try? context.save()
    }

    /// Opens the search card, creating the index on first use and restarting the scan from
    /// the current page: if the index already existed from a previous session, it only
    /// resumes the pages it's missing.
    func presentFind() {
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
        #if os(macOS)
        macTurnPage(to: target, style: tapPageTurnStyle)
        #else
        turnStyle = tapPageTurnStyle
        turnDirection = target > currentPage ? 1 : -1
        withAnimation(.easeInOut(duration: 0.2)) {
            currentPage = target
        }
        #endif
        isFindPresented = false
        #if os(tvOS)
        readerFocus = .pager
        // See the identical fix on `nextComicConfirmation`'s Annulla for why.
        isAwaitingPagerReturn = true
        #endif
    }

    func confirmPageJump() {
        guard let provider = provider else { return }
        let target = pagination(pageCount: provider.pageCount).realigned(jumpPageNumber - 1)
        #if os(macOS)
        macTurnPage(to: target, style: tapPageTurnStyle)
        #else
        turnStyle = tapPageTurnStyle
        turnDirection = target > currentPage ? 1 : -1
        withAnimation(.easeInOut(duration: 0.2)) {
            currentPage = target
        }
        #endif
        isPageJumpPresented = false
        #if os(tvOS)
        readerFocus = .pager
        // See the identical fix on `nextComicConfirmation`'s Annulla for why.
        isAwaitingPagerReturn = true
        #endif
    }

    private func purgePageCache() {
        guard let pageCache else { return }
        Task { await pageCache.purge() }
    }

    /// Prefetch around the current page, on both platforms.
    func prefetchAroundCurrentPage(provider: ComicPageProvider) async {
        guard let pageCache else { return }
        #if os(macOS) || os(iOS)
        // Nearest pages first, forward-biased (the next spread is by far the most likely
        // request), each with exactly the options its `PageView` will ask for.
        let pageCount = provider.pageCount
        let offsets = [0, 1, 2, 3, -1, 4, -2]
        var seen = Set<Int>()
        let requests: [(index: Int, options: PageImageCache.ProcessingOptions)] = offsets.compactMap { offset in
            let index = currentPage + offset
            guard index >= 0, index < pageCount, seen.insert(index).inserted else { return nil }
            return (index, PageImageCache.ProcessingOptions(
                autoCrop: isAutoCropEnabled,
                autoTintContrast: isAutoTintContrastEnabled,
                upscaleTargetSize: isUpscalingEnabled ? pageUpscaleTargetSize(for: index, pageCount: pageCount) : nil
            ))
        }
        await pageCache.prefetch(requests)
        return
        #else
        // tvOS: one target for every page (no per-page override in its `PageView`s yet).
        let pageTargetSize = effectiveDoublePage
            ? CGSize(width: viewportSize.width / 2, height: viewportSize.height)
            : viewportSize
        let options = PageImageCache.ProcessingOptions(
            autoCrop: isAutoCropEnabled,
            autoTintContrast: isAutoTintContrastEnabled,
            upscaleTargetSize: isUpscalingEnabled ? pageTargetSize : nil
        )
        await pageCache.prefetch(around: currentPage, radius: 3, pageCount: provider.pageCount, options: options)
        #endif
    }

    #if os(macOS) || os(iOS)
    /// The upscaling target for one page, as laid out by `PageSpreadView`: a page paired with
    /// another gets the spread's height and a 2:3 width estimate (on iOS that's exactly what
    /// `SpreadPairView` lays out), a lone page the whole viewport. Shared by the prefetch and
    /// the page views so their cache keys match by construction.
    func pageUpscaleTargetSize(for index: Int, pageCount: Int) -> CGSize {
        let pag = pagination(pageCount: pageCount)
        guard pag.showsSecondPage(from: pag.realigned(index)) else { return viewportSize }
        return CGSize(width: viewportSize.height * 2 / 3, height: viewportSize.height)
    }
    #endif

    #if os(macOS) || os(tvOS)
    /// The current page (or spread), with the last page change's transition.
    ///
    /// The order of the two `.environment` calls is deliberate: the outer one applies to
    /// the transition layer, so `.move(edge:)`'s edges always resolve in LTR and we decide
    /// the direction ourselves in `pageTurnTransition`; the inner one mirrors the spread for manga.
    func pagerContent(provider: ComicPageProvider) -> some View {
        spreadView(provider: provider)
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

    func spreadView(provider: ComicPageProvider, start: Int? = nil) -> PageSpreadView {
        var view = PageSpreadView(provider: provider, leadingIndex: start ?? currentPage, pagination: pagination(pageCount: provider.pageCount), isZoomed: $isZoomed, imageCache: pageCache)
        #if os(macOS)
        let pageCount = provider.pageCount
        view.upscaleTargetSize = { pageUpscaleTargetSize(for: $0, pageCount: pageCount) }
        view.isActive = (start ?? currentPage) == currentPage
        #endif
        return view
    }

    /// Translates the style of the gesture that triggered the change into the corresponding
    /// transition: side slide, fade or hard cut (for "Immediate" the animation is already
    /// disabled in `step`, here it's enough to add no effects).
    var pageTurnTransition: AnyTransition {
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

    /// Moves forward/back by one spread, respecting the current reading direction (manga =
    /// reversed). `style` is that of the gesture that triggered the change (tap or
    /// swipe/keyboard have independent settings) and decides the animation, rendered by
    /// `pageTurnTransition`. When the native pager is active (swipe and tap both on
    /// "Scroll") the swipe's slide doesn't go through here: the TabView handles it by
    /// following the finger.
    func advancePage(_ direction: Int, provider: ComicPageProvider, style: TapPageTurnStyle) {
        #if os(macOS)
        let origin = macPendingTarget ?? currentPage
        #else
        let origin = currentPage
        #endif
        switch pagination(pageCount: provider.pageCount).step(from: origin, direction: direction) {
        case .endReached(let triggersNextComic):
            #if os(tvOS)
            markFinishedIfNeeded(pageCount: provider.pageCount)
            #endif
            if triggersNextComic, let candidate = nextComicInLibrary {
                pendingNextComic = candidate
                #if os(tvOS)
                // Explicit target, same reasoning as the header's Up case: `isPagerFocusable`
                // going false because of `pendingNextComic` isn't enough on its own to land
                // focus on the dialog — without this it fell back to the system's default
                // search, which measured as unreliable for the header and isn't worth
                // trusting here either.
                readerFocus = .dialogCancel
                #endif
            }
        case .beginningReached:
            break
        case .page(let next):
            resetIdleTimerIfNeeded()
            #if os(macOS)
            macTurnPage(to: next, style: style)
            #else
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
            #endif
        }
    }

    func toggleControls() {
        resetIdleTimerIfNeeded()
        withAnimation(.easeInOut(duration: 0.22)) {
            isControlsVisible.toggle()
        }
        #if os(macOS)
        if isControlsVisible { scheduleMacChromeAutoHide() } else { macChromeIdle.hideWorkItem?.cancel() }
        #endif
    }

    /// "Showcase/kiosk" timer: if the reader stays inactive for the time chosen in
    /// Settings, it automatically returns to page 1. Every interaction (tap, page change)
    /// restarts it.
    private func resetIdleTimerIfNeeded() {
        idleResetWorkItem?.cancel()
        guard readerIdleReset.rawValue > 0 else { return }
        let workItem = DispatchWorkItem {
            #if os(macOS)
            macTurnPage(to: 0, style: tapPageTurnStyle)
            #else
            turnStyle = tapPageTurnStyle
            turnDirection = -1
            withAnimation(.easeInOut(duration: 0.2)) { currentPage = 0 }
            #endif
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

    func switchToComic(_ next: ComicEntity) {
        pendingNextComic = nil
        onSwitchComic(next)
    }

    /// Persists a progress change, throttled: at most one `save()` (and therefore one
    /// CloudKit export transaction) per `progressSaveInterval`, with the trailing edge
    /// scheduled. The in-memory `lastReadPage` is already current — this only paces the
    /// persistence/export. Crash window: at most `progressSaveInterval` of progress.
    /// Not logged: reading progress syncs reliably now, and a line per save was noise.
    func scheduleProgressSave(page: Int) {
        if Date().timeIntervalSince(lastProgressSave) >= Self.progressSaveInterval {
            lastProgressSave = Date()
            try? context.save()
            return
        }
        pendingProgressSave?.cancel()
        let work = DispatchWorkItem {
            lastProgressSave = Date()
            try? context.save()
        }
        pendingProgressSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.progressSaveInterval, execute: work)
    }

    /// Writes any throttled progress save still pending. Called on exit/background so
    /// the last pages are never left only in memory.
    private func flushPendingProgressSave() {
        pendingProgressSave?.cancel()
        pendingProgressSave = nil
        if context.hasChanges {
            lastProgressSave = Date()
            try? context.save()
        }
        #if os(iOS)
        // Held open by a background task: called on backgrounding, where iOS would otherwise
        // suspend the app before the CloudKit round-trip completes.
        RemoteProgressSync.flushPushInBackgroundTask()
        #else
        RemoteProgressSync.flushPush()
        #endif
    }

    /// A change to `comic.lastReadPage` that didn't come from `currentPage` is a remote
    /// CloudKit import from another device (`viewContext` merges automatically — see
    /// `PersistenceController`). `currentPage` is a local `@State` snapshot taken once in
    /// `loadComic`, so without this the reader would keep showing the old page until
    /// exit/reopen. Local page turns already set both to the same value, so they fall
    /// into the `target == currentPage` early return and never raise the banner.
    ///
    /// Not every such change is another device's reading, though. When the iPad's own
    /// progress reaches another device, that device writes it into its row, and the Core
    /// Data mirror sends that row back here, possibly after the user has already turned
    /// more pages. It then carries an older page *and* an older `dateLastOpened` than the
    /// one this reader recorded, so it is undone instead of offered as "go back".
    private func handleRemotePageChange(_ newRemote: Int) {
        // A deleted row reads back as page 0: that's not a remote page, see `handleOpenComicDeleted`.
        guard comic.managedObjectContext != nil, !comic.isDeleted else { return }
        guard let provider, provider.pageCount > 0 else { return }
        if let local = localProgress, let incoming = comic.dateLastOpened,
           incoming <= local.date, Int32(newRemote) != local.page {
            comic.lastReadPage = local.page
            comic.dateLastOpened = local.date
            scheduleProgressSave(page: Int(local.page))
            if pendingRemotePage != nil { pendingRemotePage = nil }
            return
        }
        let clamped = min(max(newRemote, 0), provider.pageCount - 1)
        let target = pagination(pageCount: provider.pageCount).realigned(clamped)
        guard target != currentPage else {
            if pendingRemotePage != nil { pendingRemotePage = nil }
            return
        }
        pendingRemotePage = target
    }

    /// Deduplication can delete the very row this reader has open: two devices registered the
    /// same iCloud file, and the open copy lost to the deterministic survivor. Every later page
    /// turn would then land on a dead object, never saved nor synced, while the other devices
    /// keep showing the survivor's old page. Hands the reader over to the survivor instead,
    /// carrying this reader's progress when it is the fresher one.
    private func handleOpenComicDeleted(_ note: Notification) {
        let deletedKeys = [NSDeletedObjectsKey, NSInvalidatedObjectsKey]
        let deleted = deletedKeys.contains { key in
            (note.userInfo?[key] as? Set<NSManagedObject>)?.contains { $0.objectID == comic.objectID } == true
        }
        guard deleted, let path = openedLibraryPath else { return }
        let request = ComicEntity.fetchRequest()
        request.predicate = NSPredicate(format: "relativePath == %@ AND sourceAccountID == nil", path)
        guard let candidates = try? context.fetch(request),
              let survivor = ComicEntity.survivor(of: candidates.filter { $0.objectID != comic.objectID })
        else { return }
        pendingProgressSave?.cancel()
        pendingProgressSave = nil
        if let local = localProgress, local.date > (survivor.dateLastOpened ?? .distantPast) {
            survivor.lastReadPage = local.page
            survivor.dateLastOpened = local.date
            try? context.save()
            RemoteProgressSync.requestPush(survivor)
        }
        onSwitchComic(survivor)
    }

    func jumpToRemotePage() {
        guard let target = pendingRemotePage, provider != nil else { return }
        pendingRemotePage = nil
        #if os(macOS)
        macTurnPage(to: target, style: tapPageTurnStyle)
        #else
        turnStyle = tapPageTurnStyle
        turnDirection = target > currentPage ? 1 : -1
        withAnimation(.easeInOut(duration: 0.2)) { currentPage = target }
        #endif
        #if os(tvOS)
        readerFocus = .pager
        isAwaitingPagerReturn = true
        #endif
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

    func toggleReadingDirection() {
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
        let url = comic.fileURL
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
        if let opened = comic.dateLastOpened { localProgress = (comic.lastReadPage, opened) }
        if comic.sourceAccountID == nil, let path = comic.relativePath, !path.isEmpty {
            openedLibraryPath = path
        }

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
                loadError = AppLocalization.userFacingError(error)
                return
            }
            #if os(tvOS)
            // No ubiquity container on tvOS: a missing file here is never "corrupt", just unsynced.
            guard FileManager.default.fileExists(atPath: url.path) else {
                isLoadingComic = false
                loadError = ComicReadError.notAvailableOnThisDevice.localizedDescription
                return
            }
            #endif
            // Re-read live: a remote import may have advanced `lastReadPage` while the
            // iCloud download was in flight, after `startingPage` was captured.
            openProvider(at: url, format: format, startingPage: Int(comic.lastReadPage))
        }
    }

    /// Opens the archive and builds the pager. Kept separate from `loadComic` because when
    /// the comic is an iCloud placeholder it only arrives after the download, not right away.
    private func openProvider(at url: URL, format: ComicFormat, startingPage: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try ComicPageProviderFactory.makeProvider(for: url, format: format)
                // An archive with no readable image opens "successfully" with zero pages: the
                // reader would then show an empty pager and clamp `lastReadPage` to -1.
                guard loaded.pageCount > 0 else { throw ComicReadError.corruptArchive }
                DispatchQueue.main.async {
                    isLoadingComic = false
                    provider = loaded
                    pageCache = PageImageCache(provider: loaded)
                    if CommandLine.arguments.contains("--uitesting-remote-banner"), loaded.pageCount > 1 {
                        pendingRemotePage = 1
                    }
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
                    loadError = AppLocalization.userFacingError(error)
                }
            }
        }
    }
}

/// Small helpers kept out of `ReaderContentView`'s own body for SwiftLint's
/// `type_body_length` (same file, so they still reach its `private` state).
extension ReaderContentView {
    /// tvOS: the 320pt iOS card was a small island in the middle of a 1920pt screen, its
    /// text barely readable from the couch.
    var readerCardMaxWidth: CGFloat {
        #if os(tvOS)
        760
        #else
        320
        #endif
    }

    var readerCardPadding: CGFloat {
        #if os(tvOS)
        40
        #else
        20
        #endif
    }

    /// tvOS `.card` adds no inner padding: 14 matches "Riprendi"/"Leggi"; 10 is the iOS/macOS value.
    var readerCardButtonVerticalPadding: CGFloat {
        #if os(tvOS)
        14
        #else
        10
        #endif
    }
}

// No real comic file backs this, so the pager shows its "couldn't load" state rather than
// actual pages — still useful for iterating on the chrome (header/footer/controls) live.
// The controls-toggle bug this file is being debugged for won't reproduce here: Preview
// doesn't run through `StatusBarControllingHost`'s real UIKit status bar the way a full
// simulator/device run does.
#Preview {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext
    let comic = ComicEntity.create(
        title: "Anteprima",
        relativePath: "preview.cbz",
        format: .cbz,
        in: context
    )
    return ReaderView(comic: comic)
        .environment(\.managedObjectContext, context)
}

#if os(macOS)
/// Mutable, non-observed state for the reader HUD's mouse-idle auto-hide (see
/// `ReaderContentView.macPointerMoved`).
final class MacChromeIdleState {
    var hideWorkItem: DispatchWorkItem?
    var lastPointerLocation: CGPoint?
}
#endif
