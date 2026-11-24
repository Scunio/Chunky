import SwiftUI

/// macOS reader pager: persistent spread window, click zones, keyboard/menu commands,
/// page-turn timing and the HUD's mouse-idle auto-hide. Split out of ReaderView.swift to
/// keep `ReaderContentView`'s body under SwiftLint's `type_body_length`.
#if os(macOS)
extension ReaderContentView {
    /// Persistent pager: the current spread *and its two neighbours* stay mounted side by side
    /// (each keyed by its start index, so a spread keeps its identity — and its already decoded
    /// image — as it moves), and a page turn just animates their horizontal offsets. Before,
    /// `.id(currentPage)` + `.transition` built the incoming spread from scratch on every turn,
    /// mid-animation; now the page sliding in has been laid out and decoded while it waited
    /// off-screen. Jumps further than one spread (Home/End, slider, Go to page) insert a spread
    /// that wasn't mounted: it arrives with the same transition the old pager used.
    ///
    /// Only the visible spread takes hits (click zones, double-click zoom) and ⌘+/⌘−/⌘0, and a
    /// neighbour drops its zoom when it leaves the screen (see `PageSpreadView.isActive`).
    /// "Fade" stacks the spreads in place and cross-fades their opacity instead.
    private func macPersistentPager(provider: ComicPageProvider) -> some View {
        let starts = spreadStarts(pageCount: provider.pageCount)
        let currentPosition = starts.firstIndex(of: currentPage) ?? starts.lastIndex(where: { $0 <= currentPage }) ?? 0
        let window = starts.isEmpty ? [] : Array(starts[max(currentPosition - 1, 0)...min(currentPosition + 1, starts.count - 1)])
        let rightToLeft = comic.readingDirection == .rightToLeft
        let isFade = turnStyle == .fade
        return GeometryReader { proxy in
            ZStack {
                ForEach(window, id: \.self) { start in
                    let slot = (starts.firstIndex(of: start) ?? currentPosition) - currentPosition
                    // The higher-index spread sits on the right in LTR, on the left in manga.
                    let visualSlot = CGFloat(rightToLeft ? -slot : slot)
                    spreadView(provider: provider, start: start)
                        .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .offset(x: isFade ? 0 : visualSlot * proxy.size.width)
                        .opacity(slot == 0 || !isFade ? 1 : 0)
                        .allowsHitTesting(slot == 0)
                        .accessibilityHidden(slot != 0)
                        .transition(pageTurnTransition)
                        .zIndex(slot == 0 ? 1 : 0)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Outside the per-spread manga mirroring, so offsets and `.move(edge:)` resolve in LTR
        // and the direction is decided above / in `pageTurnTransition`.
        .environment(\.layoutDirection, .leftToRight)
        .task(id: currentPage) {
            await prefetchAroundCurrentPage(provider: provider)
        }
    }

    func macOSPager(provider: ComicPageProvider) -> some View {
        ZStack {
            macPersistentPager(provider: provider)
        }
        // No padding for the chrome any more: the actions are in the window toolbar and the
        // page counter is a floating HUD, so the page keeps one size whether or not the HUD is
        // showing (it used to shrink/grow by the bars' height on every toggle).
        // Scoped to the pager: the page-turn animation used to be a global `withAnimation`,
        // which also animated every other view depending on `currentPage` (page counter,
        // slider, header) on each turn. `nil` for "Immediate".
        .animation(macPageTurnAnimation, value: currentPage)
        .clipped()
        // A gesture on the pager, not views layered over it: see `PageClickZones`.
        .modifier(PageClickZones(
            zonesEnabled: tapPageTurnStyle != .disabled,
            hotCorners: isHotCornersEnabled,
            rightToLeft: comic.readingDirection == .rightToLeft,
            isZoomed: isZoomed,
            onPrevious: {
                // "Always advance on tap": the back zone advances too (as on iOS).
                advancePage(isTapToPanEnabled ? 1 : -1, provider: provider, style: tapPageTurnStyle)
            },
            onNext: { advancePage(1, provider: provider, style: tapPageTurnStyle) },
            onToggleControls: { toggleControls() },
            onExit: { exitReader() },
            onOpenSettings: { openTools() },
            onToggleDoublePage: { if isDoublePageAllowed { isDoublePageEnabled.toggle() } },
            hintColor: chromeForeground,
            onPointerMoved: { macPointerMoved(to: $0) }
        ))
        .background(ScrollSwipeMonitor { direction in
            guard swipePageTurnStyle != .disabled, !isZoomed else { return }
            advancePage(direction, provider: provider, style: swipePageTurnStyle)
        })
        .background(ReaderKeyMonitor(isEnabled: isReaderKeyboardActive) { key in
            let readingForward = comic.readingDirection == .rightToLeft ? -1 : 1
            switch key {
            case .left: advancePage(-1, provider: provider, style: tapPageTurnStyle)
            case .right: advancePage(1, provider: provider, style: tapPageTurnStyle)
            case .forward: advancePage(readingForward, provider: provider, style: tapPageTurnStyle)
            case .backward: advancePage(-readingForward, provider: provider, style: tapPageTurnStyle)
            case .first:
                macTurnPage(to: spreadStarts(pageCount: provider.pageCount).first ?? 0, style: tapPageTurnStyle)
            case .last:
                macTurnPage(to: spreadStarts(pageCount: provider.pageCount).last ?? 0, style: tapPageTurnStyle)
            case .escape:
                // Esc dismisses the "page N on another device" banner; otherwise it's
                // left to the system (e.g. leaving full screen).
                guard pendingRemotePage != nil else { return false }
                pendingRemotePage = nil
            }
            return true
        })
        // Published only while this view is alive, so only while a reader window is really
        // on stage — no parental-lock filter here, because with `lock.isLocked`
        // `ReaderWindowContainer` shows `ParentalLockGateView` instead of `ReaderView`, so
        // this code simply isn't mounted at all.
        .focusedSceneValue(\.readerActions, isReaderKeyboardActive ? macReaderCommandActions(provider: provider) : nil)
        .environment(\.readerZoomCommand, macZoomCommand)
    }

    /// False while something with its own keyboard handling is on screen (a text field, a
    /// card, a sheet): the menu items go disabled, and a disabled item doesn't steal its bare
    /// Left/Right/Space key equivalent from the search or page-jump fields.
    private var isReaderKeyboardActive: Bool {
        !(isFindPresented || isPageJumpPresented || isPanelSelectionPresented || isInfoPresented
          || isToolsPresented || isAccountsPresented || isNewComicsPresented || isNowReadingPresented
          || pendingNextComic != nil)
    }

    private func macReaderCommandActions(provider: ComicPageProvider) -> ReaderCommandActions {
        let readingForward = comic.readingDirection == .rightToLeft ? -1 : 1
        return ReaderCommandActions(
            previousPage: { advancePage(-1, provider: provider, style: tapPageTurnStyle) },
            nextPage: { advancePage(1, provider: provider, style: tapPageTurnStyle) },
            forwardInReadingOrder: { advancePage(readingForward, provider: provider, style: tapPageTurnStyle) },
            firstPage: {
                let starts = spreadStarts(pageCount: provider.pageCount)
                macTurnPage(to: starts.first ?? 0, style: tapPageTurnStyle)
            },
            lastPage: {
                let starts = spreadStarts(pageCount: provider.pageCount)
                macTurnPage(to: starts.last ?? 0, style: tapPageTurnStyle)
            },
            find: { presentFind() },
            goToPage: {
                jumpPageNumber = currentPage + 1
                isPageJumpPresented = true
            },
            zoomIn: { sendZoomCommand(.zoomIn) },
            zoomOut: { sendZoomCommand(.zoomOut) },
            actualSize: { sendZoomCommand(.reset) }
        )
    }

    private func sendZoomCommand(_ kind: ReaderZoomCommand.Kind) {
        macZoomCommand = ReaderZoomCommand(id: (macZoomCommand?.id ?? 0) + 1, kind: kind)
    }

    /// The pager's own animation (see `.animation(_:value:)` on `macOSPager`): the "Fade" style
    /// honors the user's duration setting, which before only the iOS pager read.
    private var macPageTurnAnimation: Animation? {
        switch turnStyle {
        case .fade: return .easeInOut(duration: fadeTransitionDuration)
        case .slide: return .easeInOut(duration: 0.2)
        case .immediate, .disabled: return nil
        }
    }

    /// Every macOS page turn goes through here. When the style or direction differs from the
    /// previous turn, they are committed one runloop tick *before* the page changes: the
    /// outgoing page keeps the removal transition from its last render, so updating both in the
    /// same transaction made it leave toward the old direction (e.g. after going back, the next
    /// "forward" turn slid the old page out the wrong side) or with the old style.
    func macTurnPage(to target: Int, style: TapPageTurnStyle) {
        let origin = macPendingTarget ?? currentPage
        guard target != origin else { return }
        let direction = target > origin ? 1 : -1
        guard style != turnStyle || direction != turnDirection else {
            if macPendingTarget != nil {
                // A deferred turn is still in flight: just retarget it.
                macPendingTarget = target
            } else {
                currentPage = target
            }
            return
        }
        turnStyle = style
        turnDirection = direction
        macPendingTarget = target
        // About one frame later, not a plain `async`: the main queue is drained before
        // SwiftUI renders in the same run-loop pass, so both changes would land in a single
        // update and the outgoing page would still leave with its stale transition.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
            guard let pending = macPendingTarget else { return }
            macPendingTarget = nil
            currentPage = pending
        }
    }

    /// Pointer moved over the reader: reveal the HUD and restart the idle countdown.
    private func macPointerMoved(to location: CGPoint) {
        // Zero-distance hover updates (content changing under a still pointer) aren't the
        // user moving the mouse.
        if let last = macChromeIdle.lastPointerLocation, hypot(location.x - last.x, location.y - last.y) < 1 { return }
        macChromeIdle.lastPointerLocation = location
        if !isControlsVisible {
            withAnimation(.easeInOut(duration: 0.22)) { isControlsVisible = true }
        }
        scheduleMacChromeAutoHide()
    }

    /// Hides the HUD after a few idle seconds, the way
    /// QuickTime/Preview's slideshow do — never while the pointer is over the HUD itself.
    func scheduleMacChromeAutoHide() {
        macChromeIdle.hideWorkItem?.cancel()
        guard !isPointerOverMacFooter else { return }
        let idle = macChromeIdle
        let work = DispatchWorkItem {
            idle.hideWorkItem = nil
            guard isControlsVisible, !isPointerOverMacFooter, isReaderKeyboardActive else { return }
            withAnimation(.easeInOut(duration: 0.3)) { isControlsVisible = false }
        }
        macChromeIdle.hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.macChromeIdleDelay, execute: work)
    }
}
#endif
