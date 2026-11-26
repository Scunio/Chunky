import SwiftUI

#if os(tvOS)
/// tvOS-only reader input: remote zoom/pan and chrome auto-hide. Split out of
/// ReaderView.swift to keep `ReaderContentView`'s own body under SwiftLint's
/// `type_body_length`.
extension ReaderContentView {
    /// The pager is driven by `.onMoveCommand` (the remote has no pointer) and Menu by `.onExitCommand`;
    /// `.onMoveCommand` keeps firing while the view is `.focusable`, whatever `readerFocus` says.
    var isPagerFocusable: Bool {
        // `nil` counts as pager-safe: it is the real value for the one frame before `onAppear`, and
        // dropping it there lets the system commit its initial focus to some other button.
        return (readerFocus == nil || readerFocus == .pager) && !(isPageJumpPresented || pendingNextComic != nil || isFindPresented || isInfoPresented)
    }

    func tvOSPager(provider: ComicPageProvider) -> some View {
        pagerContent(provider: provider)
            // Zoom is a plain transform around the whole spread (see `tvZoomScale`):
            // `.clipped()` keeps the enlarged page inside the screen instead of spilling
            // under the chrome.
            .scaleEffect(tvZoomScale)
            .offset(tvZoomOffset)
            .clipped()
            .contentShape(Rectangle())
            .focusable(isPagerFocusable)
            .focused($readerFocus, equals: .pager)
            .onAppear {
                readerFocus = .pager
                scheduleChromeAutoHide()
            }
            // After the parental-lock screen goes away, hand focus back to the pager (twice: the first can lose to the system).
            .onReceive(ParentalLock.shared.$isLocked.removeDuplicates().dropFirst().filter { !$0 }) { _ in
                for delay in [0.45, 1.2] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { readerFocus = .pager; isAwaitingPagerReturn = true }
                }
            }
            .onTapGesture {
                if isTVZoomed {
                    resetTVZoom()
                } else {
                    toggleControls()
                    scheduleChromeAutoHide()
                }
            }
            .onPlayPauseCommand { toggleTVZoom() }
            .onMoveCommand { direction in
                handlePagerMoveCommand(direction, provider: provider)
            }
            .onExitCommand {
                // Menu leaves the zoom first, the reader only once back at fit size.
                if isTVZoomed {
                    resetTVZoom()
                } else {
                    exitReader()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(comic.title ?? ""))
            .accessibilityValue(Text("Pagina \(currentPage + 1) di \(provider.pageCount)"))
            .accessibilityHint(Text("Sinistra e destra cambiano pagina, Play/Pausa o Select ingrandiscono e tornano alla pagina intera"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: advancePage(1, provider: provider, style: tapPageTurnStyle)
                case .decrement: advancePage(-1, provider: provider, style: tapPageTurnStyle)
                @unknown default: break
                }
            }
    }

    /// Shared `.onMoveCommand` for every header button. Down is meant to return focus to
    /// the pager, but a focused `Button` doesn't reliably give up real UIKit focus just
    /// because `.focusable` toggles false (confirmed live: it keeps receiving move commands
    /// afterwards) — so Left/Right are handled right here instead of relying on that
    /// transfer, letting page-turning keep working even though the focus ring stays put.
    ///
    /// `isAwaitingPagerReturn` gates that Left/Right proxy so it only fires after an explicit
    /// Down — without it, every Right press used to move between header icons (a normal,
    /// working navigation `onMoveCommand` still receives regardless of whether the focus
    /// engine also resolves it) *also* silently turned a page, which broke navigating between
    /// icons entirely (confirmed live: Right from "Libreria" toward the search icon instead
    /// paged to the end of the comic and popped the "Fine del fumetto" dialog).
    func handleHeaderMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .down:
            readerFocus = .pager
            isAwaitingPagerReturn = true
            scheduleChromeAutoHide()
        case .up:
            isAwaitingPagerReturn = false
            chromeAutoHideWorkItem?.cancel()
            // After a Down, readerFocus is still .pager while real focus never left the button, so every header button was non-focusable.
            if readerFocus == .pager || readerFocus == nil { readerFocus = .libreria }
        case .left where isAwaitingPagerReturn:
            guard let provider else { return }
            advancePage(-1, provider: provider, style: tapPageTurnStyle)
        case .right where isAwaitingPagerReturn:
            guard let provider else { return }
            advancePage(1, provider: provider, style: tapPageTurnStyle)
        default:
            // Ordinary header browsing (Left/Right with no Down pending): keep the chrome up.
            chromeAutoHideWorkItem?.cancel()
        }
    }

    private static let tvZoomLevel: CGFloat = 2
    private static let chromeAutoHideDelay: TimeInterval = 5

    var isTVZoomed: Bool { tvZoomScale > 1 }

    func toggleTVZoom() {
        if isTVZoomed {
            resetTVZoom()
        } else {
            chromeAutoHideWorkItem?.cancel()
            withAnimation(.easeInOut(duration: 0.25)) {
                tvZoomScale = Self.tvZoomLevel
                tvZoomOffset = .zero
                // Chrome would sit on top of the enlarged page and catch Up presses meant
                // for panning.
                isControlsVisible = false
            }
        }
    }

    /// Right on the last spread = finished, even if no page turn recorded it (resumed already on the last spread).
    func markFinishedIfNeeded(pageCount: Int) {
        let last = Int32(max(pageCount - 1, 0))
        guard comic.lastReadPage < last else { return }
        comic.lastReadPage = last
        let now = Date()
        comic.dateLastOpened = now
        localProgress = (last, now)
        scheduleProgressSave(page: Int(last))
        Task { @MainActor in RemoteProgressSync.requestPush(comic) }
    }

    func resetTVZoom() {
        guard isTVZoomed || tvZoomOffset != .zero else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            tvZoomScale = 1
            tvZoomOffset = .zero
        }
    }

    /// One D-pad press pans a quarter of the screen; the offset is clamped so the page edge
    /// never leaves the screen edge (the scale is centered, so the overflow is
    /// `viewport * (scale - 1) / 2` on each side).
    private func panTVZoom(dx: CGFloat, dy: CGFloat) {
        let maxX = viewportSize.width * (tvZoomScale - 1) / 2
        let maxY = viewportSize.height * (tvZoomScale - 1) / 2
        withAnimation(.easeInOut(duration: 0.2)) {
            tvZoomOffset = CGSize(
                width: min(max(tvZoomOffset.width + dx * viewportSize.width / 4, -maxX), maxX),
                height: min(max(tvZoomOffset.height + dy * viewportSize.height / 4, -maxY), maxY)
            )
        }
    }

    func handlePagerMoveCommand(_ direction: MoveCommandDirection, provider: ComicPageProvider) {
        // Zoomed: every direction pans (pressing Left reveals what's to the left, so the
        // content moves right), nothing turns the page or leaves for the header.
        if isTVZoomed {
            switch direction {
            case .left: panTVZoom(dx: 1, dy: 0)
            case .right: panTVZoom(dx: -1, dy: 0)
            case .up: panTVZoom(dx: 0, dy: 1)
            case .down: panTVZoom(dx: 0, dy: -1)
            @unknown default: break
            }
            return
        }
        switch direction {
        case .left:
            advancePage(-1, provider: provider, style: tapPageTurnStyle)
            scheduleChromeAutoHide()
        case .right:
            advancePage(1, provider: provider, style: tapPageTurnStyle)
            scheduleChromeAutoHide()
        case .up:
            // A fresh Up from the page means the user is going to browse the header, not
            // returning from it: the Left/Right page-turn proxy must be off again (it's
            // otherwise only cleared by an Up pressed *on* a header button).
            isAwaitingPagerReturn = false
            chromeAutoHideWorkItem?.cancel()
            if isControlsVisible {
                readerFocus = .libreria
            } else {
                // The header isn't in the tree while the chrome is hidden: show it first,
                // then target "Libreria" once it exists (same explicit-target reasoning as
                // the original Up case — see `ReaderFocusTarget`).
                withAnimation(.easeInOut(duration: 0.22)) { isControlsVisible = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    readerFocus = .libreria
                }
            }
        default:
            break
        }
    }

    /// Hides the chrome after a few seconds of reading, like a video player's transport
    /// bar — only while focus is on the page itself (never under a header button the user
    /// is browsing) and with no dialog/zoom on screen.
    func scheduleChromeAutoHide() {
        chromeAutoHideWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            guard isControlsVisible,
                  readerFocus == nil || readerFocus == .pager,
                  !isPageJumpPresented, pendingNextComic == nil, !isFindPresented,
                  !isInfoPresented, !isTVZoomed else { return }
            isAwaitingPagerReturn = false
            withAnimation(.easeInOut(duration: 0.22)) { isControlsVisible = false }
        }
        chromeAutoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chromeAutoHideDelay, execute: workItem)
    }
}
#endif
