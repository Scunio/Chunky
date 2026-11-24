import SwiftUI

/// iOS/iPadOS reader pager, tap zones and hardware-keyboard handling. Split out of
/// ReaderView.swift to keep `ReaderContentView`'s body under SwiftLint's `type_body_length`.
#if os(iOS)
extension ReaderContentView {
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
    func iOSPager(provider: ComicPageProvider) -> some View {
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
            advancePage(-1, provider: provider, style: tapPageTurnStyle)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            advancePage(1, provider: provider, style: tapPageTurnStyle)
            return .handled
        }
        .onKeyPress(.space) {
            // Space always moves forward in *reading* order (like Page Down), not toward
            // the right: in a manga that's the left neighbour — same as the Mac's
            // `forwardInReadingOrder`. The arrows above stay spatial.
            advancePage(comic.readingDirection == .rightToLeft ? -1 : 1, provider: provider, style: tapPageTurnStyle)
            return .handled
        }
        // `onKeyPress` only fires on a view in the focus chain: without being focusable the
        // pager never received hardware-keyboard events on iPad. No focus ring — it's the
        // whole page. Re-focused whenever an overlay that takes the keyboard goes away.
        .focusable()
        .focusEffectDisabled()
        .focused($isIOSPagerFocused)
        .onAppear { isIOSPagerFocused = true }
        .onChange(of: isIOSKeyboardOverlayPresented) { _, presented in
            if !presented { isIOSPagerFocused = true }
        }
    }

    /// Something on screen with its own keyboard handling (text fields, cards, sheets):
    /// the pager gives focus up while it's there and takes it back afterwards.
    private var isIOSKeyboardOverlayPresented: Bool {
        isFindPresented || isPageJumpPresented || isPanelSelectionPresented || isInfoPresented
            || isToolsPresented || isAccountsPresented || isSharePresented || pendingNextComic != nil
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
            // Both bars span from the true screen edge inwards, and so does the pager these
            // zones cover, so the measured heights are the exclusion bands as they are: the
            // header's own status-bar padding is already part of `headerHeight` (see `header`),
            // the footer's home-indicator padding part of `footerHeight`.
            topInset: isControlsVisible ? headerHeight : 0,
            bottomInset: isControlsVisible ? footerHeight : 0
        )
    }

    private func pageContent(provider: ComicPageProvider, start: Int) -> some View {
        var view = PageSpreadView(provider: provider, leadingIndex: start, pagination: pagination(pageCount: provider.pageCount), isZoomed: $isZoomed, imageCache: pageCache, isActive: start == currentPage, tapZoneOptions: tapZoneOptions)
        let pageCount = provider.pageCount
        view.upscaleTargetSize = { pageUpscaleTargetSize(for: $0, pageCount: pageCount) }
        return view
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
                    pageCount: provider.pageCount,
                    backgroundIsDark: isBackgroundDark
                ),
                fadeDuration: fadeTransitionDuration
            ) { start in
                pageContent(provider: provider, start: start)
            }

            if !isInteractiveSwipe && swipePageTurnStyle != .disabled && !isZoomed {
                discreteSwipeOverlay(provider: provider)
            }

            pageTapZonesOverlay(provider: provider)
        }
    }

    /// Recognizes the swipe as a discrete gesture (threshold exceeded = one page) for the
    /// styles that interactive paging can't render. `simultaneousGesture` so as not to steal
    /// the touch from the tap zones underneath.
    private func discreteSwipeOverlay(provider: ComicPageProvider) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height),
                              abs(value.translation.width) > 60 else { return }
                        advancePage(value.translation.width < 0 ? 1 : -1, provider: provider, style: swipePageTurnStyle)
                    }
            )
    }

    @available(*, deprecated, renamed: "discreteSwipeOverlay")
    private func discreteSwipeCatcher(provider: ComicPageProvider) -> some View {
        discreteSwipeOverlay(provider: provider)
    }

    private func pageTapZonesOverlay(provider: ComicPageProvider) -> some View {
        PageTapZones(
            oneHanded: isOneHandedModeEnabled,
            oneHandedReversed: isOneHandedZonesReversed,
            hotCorners: isHotCornersEnabled,
            zonesEnabled: tapPageTurnStyle != .disabled,
            rightToLeft: comic.readingDirection == .rightToLeft,
            // See the identical comment on `tapZoneOptions`.
            topInset: isControlsVisible ? headerHeight : 0,
            bottomInset: isControlsVisible ? footerHeight : 0,
            isZoomed: isZoomed
        ) {
            // With "Tap-to-pan" the "back" zone also advances: handy if you can't
            // comfortably reach both sides of the screen. Ignored while one-handed mode is
            // on: there both zones already share one action (`PageTapZoneGeometry.action`'s
            // `oneHandedAction`, following `isOneHandedZonesReversed`) for the same "can't
            // reach both sides" reason, so this would otherwise silently fight that choice
            // — turning "one-handed, reversed" (meant to send both zones back) into "both
            // zones forward" behind the user's back, with no indication why.
            advancePage(isTapToPanEnabled && !isOneHandedModeEnabled ? 1 : -1, provider: provider, style: tapPageTurnStyle)
        } onNext: {
            advancePage(1, provider: provider, style: tapPageTurnStyle)
        } onToggleControls: {
            toggleControls()
        } onExit: {
            exitReader()
        } onOpenSettings: {
            openTools()
        } onToggleDoublePage: {
            if isDoublePageAllowed { isDoublePageEnabled.toggle() }
        }
    }

    @available(*, deprecated, renamed: "pageTapZonesOverlay")
    private func tapZonesOrControlsToggle(provider: ComicPageProvider) -> some View {
        pageTapZonesOverlay(provider: provider)
    }
}
#endif
