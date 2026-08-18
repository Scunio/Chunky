import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(iOS)
/// Tap zones to change page: two side thirds (forward/back) and a central band to show/hide
/// the controls, or — in "one-handed" mode — the whole left/right side (no central band, to
/// stay comfortable with the thumb across the full screen).
///
/// Not three `Color.clear` overlaid on the content with `.contentShape` +
/// `simultaneousGesture` (previous version): for UIKit's hit-testing, whoever is on top in a
/// ZStack always wins the initial touch, regardless of `simultaneousGesture` — which arbitrates
/// between SwiftUI gestures on the same view, it doesn't pass touches through to a sibling
/// `UIViewRepresentable` underneath (the pager, the zoom scroll view). Verified live with logs
/// on `touchesBegan`: zero touches reached the real content, not even a simple tap.
///
/// Here instead — as `ReaderViewController.handleTap` does in Aidoku
/// (github.com/Aidoku/Aidoku/blob/main/iOS/UI/Reader/ReaderViewController.swift) — there's a
/// single `UITapGestureRecognizer`, and the touched zone (left/center/right/corners) is
/// computed from the touch coordinates instead of having one view per zone. Hooked onto the
/// `window` rather than this view (`hitTest` always `nil`, never on top of the hit-test): the
/// `window` is an ancestor of whatever view gets hit by the hit-test, so it receives the touch
/// regardless — the same technique already used for two-finger brightness and for
/// pinch/pan/double-tap in `ZoomableImageView`.
///
/// The accessibility labels stay SwiftUI (`allowsHitTesting(false)`, so they don't interfere
/// with the hit-test): VoiceOver navigates the view tree independently of normal touch
/// hit-testing.
struct PageTapZones: View {
    let oneHanded: Bool
    /// In "one-handed" mode, swaps which side (left/right) goes forward and which goes
    /// back: handy to adapt to right/left hand or to how the phone is held.
    let oneHandedReversed: Bool
    let hotCorners: Bool
    /// With no zones (tap page-turn disabled): any touch shows/hides the controls, as in
    /// the original app.
    let zonesEnabled: Bool
    /// In manga the left side is the one that *advances*: only needed for the
    /// accessibility labels, since the actual direction reversal already happens in `step`.
    let rightToLeft: Bool
    /// Height of the control bars when visible, at the top and bottom: within those bands
    /// the touch belongs to the controls, not to the page zones. Without this, a touch on
    /// the empty part of the bar (to the right or left of the title) fell into the side
    /// zone underneath and advanced or went back a page in the comic.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleControls: () -> Void
    /// Active corners with "Hot corners": top left exits the reader, top right opens
    /// settings, bottom right toggles double page.
    let onExit: () -> Void
    let onOpenSettings: () -> Void
    let onToggleDoublePage: () -> Void

    var body: some View {
        TapZoneRelay(
            oneHanded: oneHanded,
            oneHandedReversed: oneHandedReversed,
            rightToLeft: rightToLeft,
            hotCorners: hotCorners,
            zonesEnabled: zonesEnabled,
            topInset: topInset,
            bottomInset: bottomInset,
            onPrevious: onPrevious,
            onNext: onNext,
            onToggleControls: onToggleControls,
            onExit: onExit,
            onOpenSettings: onOpenSettings,
            onToggleDoublePage: onToggleDoublePage
        )
        .overlay(accessibilityOverlay)
    }

    /// Only labels/actions for VoiceOver, invisible to normal touches: the real zones (with
    /// the same dimensions, see `PageTapZoneGeometry`) are computed by `TapZoneRelay`.
    @ViewBuilder
    private var accessibilityOverlay: some View {
        if zonesEnabled {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    if hotCorners {
                        accessibilityZone(label: "Esci dalla lettura", action: onExit)
                            .frame(width: PageTapZoneGeometry.cornerSize, height: PageTapZoneGeometry.cornerSize)
                        accessibilityZone(label: "Impostazioni", action: onOpenSettings)
                            .frame(width: PageTapZoneGeometry.cornerSize, height: PageTapZoneGeometry.cornerSize)
                            .position(x: proxy.size.width - PageTapZoneGeometry.cornerSize / 2, y: PageTapZoneGeometry.cornerSize / 2)
                        accessibilityZone(label: "Doppia pagina", action: onToggleDoublePage)
                            .frame(width: PageTapZoneGeometry.cornerSize, height: PageTapZoneGeometry.cornerSize)
                            .position(
                                x: proxy.size.width - PageTapZoneGeometry.cornerSize / 2,
                                y: proxy.size.height - PageTapZoneGeometry.cornerSize / 2
                            )
                    }
                    // The widths here must mirror the ones used by `TapZoneRelay` for the
                    // real hit-testing (see `PageTapZoneGeometry.action`): in one-handed
                    // mode the two sides do the same action (no asymmetry); otherwise the
                    // wide zone follows whichever side is "forward" in reading order — on
                    // the right normally, on the left with RTL reading.
                    let leftWidth = oneHanded
                        ? PageTapZoneGeometry.oneHandedSideWidth(for: proxy.size.width)
                        : (rightToLeft ? PageTapZoneGeometry.forwardSideWidth(for: proxy.size.width) : PageTapZoneGeometry.backSideWidth(for: proxy.size.width))
                    let rightWidth = oneHanded
                        ? PageTapZoneGeometry.oneHandedSideWidth(for: proxy.size.width)
                        : (rightToLeft ? PageTapZoneGeometry.backSideWidth(for: proxy.size.width) : PageTapZoneGeometry.forwardSideWidth(for: proxy.size.width))
                    let verticalInset: CGFloat = hotCorners ? PageTapZoneGeometry.cornerSize : 0
                    let bandHeight = proxy.size.height - verticalInset * 2
                    accessibilityZone(label: previousOrSharedLabel, action: oneHanded ? sharedAction : onPrevious)
                        .frame(width: leftWidth, height: bandHeight)
                        .position(x: leftWidth / 2, y: verticalInset + bandHeight / 2)
                    accessibilityZone(label: nextOrSharedLabel, action: oneHanded ? sharedAction : onNext)
                        .frame(width: rightWidth, height: bandHeight)
                        .position(x: proxy.size.width - rightWidth / 2, y: verticalInset + bandHeight / 2)
                    accessibilityZone(label: "Mostra o nascondi i controlli", action: onToggleControls)
                        .frame(width: max(proxy.size.width - leftWidth - rightWidth, 0), height: bandHeight)
                        .position(x: leftWidth + max(proxy.size.width - leftWidth - rightWidth, 0) / 2, y: verticalInset + bandHeight / 2)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var sharedAction: () -> Void { oneHandedReversed ? onPrevious : onNext }
    /// `onPrevious`/`onNext` are the left zone and the right one: in manga the left is the
    /// one that moves forward, so the labels must be swapped.
    private var previousLabel: String { rightToLeft ? "Pagina successiva" : "Pagina precedente" }
    private var nextLabel: String { rightToLeft ? "Pagina precedente" : "Pagina successiva" }
    private var sharedLabel: String { oneHandedReversed ? previousLabel : nextLabel }
    private var previousOrSharedLabel: String { oneHanded ? sharedLabel : previousLabel }
    private var nextOrSharedLabel: String { oneHanded ? sharedLabel : nextLabel }

    private func accessibilityZone(label: String, action: @escaping () -> Void) -> some View {
        Color.clear
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityAction(.default, action)
    }
}

/// Zone geometry, shared between `TapZoneRelay` (which decides the action from a real touch)
/// and `PageTapZones`'s accessibility overlay (which must position the same rectangles): a
/// single source of truth, otherwise VoiceOver and the real touch risk getting out of sync.
private enum PageTapZoneGeometry {
    static let cornerSize: CGFloat = 88

    /// "Back" zone: narrower, as in Kindle-style readers — you go back far less often than
    /// you go forward, so a wide zone here only increases accidental touches that return to
    /// the previous page instead of opening the controls.
    static func backSideWidth(for totalWidth: CGFloat) -> CGFloat {
        min(totalWidth * 0.11, 55)
    }

    /// "Forward" zone: wider than the back zone, for the same reason in reverse. The same
    /// cap (90pt) as before the asymmetry, not any wider: verified live that a higher cap
    /// (120pt) ends up covering the "···" button on the top toolbar, which without
    /// `hotCorners` active has no vertical exclusion — a touch there also advanced the page.
    static func forwardSideWidth(for totalWidth: CGFloat) -> CGFloat {
        min(totalWidth * 0.18, 90)
    }

    /// "One-handed" mode: both sides do the same action (see `sharedAction` in
    /// `PageTapZones`), so the forward/back asymmetry doesn't make sense here — one side
    /// isn't "more forward" than the other, they're the exact same action duplicated for
    /// thumb convenience. Fixed width, as before the asymmetric zones were introduced.
    static func oneHandedSideWidth(for totalWidth: CGFloat) -> CGFloat {
        min(totalWidth * 0.18, 90)
    }

    enum Action {
        case previous, next, toggleControls, exit, openSettings, toggleDoublePage
    }

    /// The settings that decide the zone map, gathered together: they always travel all
    /// together from the reader down to `action(at:in:options:)`, and passing them one by
    /// one just meant seven positional parameters easy to mix up with each other.
    struct Options {
        var oneHanded: Bool
        var oneHandedReversed: Bool
        var rightToLeft: Bool
        var hotCorners: Bool
        var zonesEnabled: Bool
        /// Bands occupied by the control bars when visible — see
        /// `PageTapZones.topInset`.
        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0
    }

    static func action(at point: CGPoint, in size: CGSize, options: Options) -> Action? {
        let oneHanded = options.oneHanded
        let oneHandedReversed = options.oneHandedReversed
        let rightToLeft = options.rightToLeft
        let hotCorners = options.hotCorners
        let zonesEnabled = options.zonesEnabled
        guard size.width > 0, size.height > 0 else { return nil }
        // Control bands: the touch belongs to the controls (or to no one, if it falls on the
        // empty part of the bar), never to the page zones. Before the active corners, which
        // would otherwise end up underneath the top bar.
        if point.y < options.topInset || point.y > size.height - options.bottomInset { return nil }
        guard zonesEnabled else { return .toggleControls }

        if hotCorners {
            if point.x <= cornerSize, point.y <= cornerSize { return .exit }
            if point.x >= size.width - cornerSize, point.y <= cornerSize { return .openSettings }
            if point.x >= size.width - cornerSize, point.y >= size.height - cornerSize { return .toggleDoublePage }
        }

        let verticalInset: CGFloat = hotCorners ? cornerSize : 0
        guard point.y >= verticalInset, point.y <= size.height - verticalInset else { return nil }

        if oneHanded {
            // Both sides call the same closure (see `sharedAction`): there's no "forward"
            // side and "back" side to make asymmetric, they're the same action.
            let sideWidth = oneHandedSideWidth(for: size.width)
            let sharedAction: Action = oneHandedReversed ? .previous : .next
            if point.x <= sideWidth { return sharedAction }
            if point.x >= size.width - sideWidth { return sharedAction }
            return .toggleControls
        }

        // `onPrevious`/`onNext` are tied to left/right regardless of `rightToLeft` (whoever
        // implements them, `ReaderPagination.step`, already reverses the direction for
        // manga) — here only WHICH side is "forward" in reading order changes, and
        // therefore which one gets the wide zone: on the right normally, on the left when
        // reading is RTL.
        let leftWidth = rightToLeft ? forwardSideWidth(for: size.width) : backSideWidth(for: size.width)
        let rightWidth = rightToLeft ? backSideWidth(for: size.width) : forwardSideWidth(for: size.width)

        if point.x <= leftWidth {
            return .previous
        }
        if point.x >= size.width - rightWidth {
            return .next
        }
        return .toggleControls
    }
}

private struct TapZoneRelay: UIViewRepresentable {
    let oneHanded: Bool
    let oneHandedReversed: Bool
    let rightToLeft: Bool
    let hotCorners: Bool
    let zonesEnabled: Bool
    let topInset: CGFloat
    let bottomInset: CGFloat
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleControls: () -> Void
    let onExit: () -> Void
    let onOpenSettings: () -> Void
    let onToggleDoublePage: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RelayView {
        let view = RelayView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: RelayView, context: Context) {
        context.coordinator.oneHanded = oneHanded
        context.coordinator.oneHandedReversed = oneHandedReversed
        context.coordinator.rightToLeft = rightToLeft
        context.coordinator.hotCorners = hotCorners
        context.coordinator.zonesEnabled = zonesEnabled
        context.coordinator.topInset = topInset
        context.coordinator.bottomInset = bottomInset
        context.coordinator.onPrevious = onPrevious
        context.coordinator.onNext = onNext
        context.coordinator.onToggleControls = onToggleControls
        context.coordinator.onExit = onExit
        context.coordinator.onOpenSettings = onOpenSettings
        context.coordinator.onToggleDoublePage = onToggleDoublePage
    }

    /// Never intercepts hit-testing (see the comment on `PageTapZones` above): its
    /// recognizer, hooked onto the window in `didMoveToWindow`, receives every touch anyway
    /// because the window is an ancestor of whatever view gets hit by the hit-test.
    final class RelayView: UIView {
        weak var coordinator: Coordinator?
        private weak var recognizer: UITapGestureRecognizer?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
            }
            guard let window, let coordinator else { return }
            coordinator.relayView = self
            let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
            tap.delegate = coordinator
            tap.cancelsTouchesInView = false
            window.addGestureRecognizer(tap)
            recognizer = tap
        }

        deinit {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var relayView: UIView?
        var oneHanded = false
        var oneHandedReversed = false
        var rightToLeft = false
        var hotCorners = false
        var zonesEnabled = true
        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0
        var onPrevious: () -> Void = {}
        var onNext: () -> Void = {}
        var onToggleControls: () -> Void = {}
        var onExit: () -> Void = {}
        var onOpenSettings: () -> Void = {}
        var onToggleDoublePage: () -> Void = {}

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        /// This single tap (1 tap required) and `ZoomGestureRelayView`'s double tap-to-zoom (2
        /// taps required) are separate recognizers on the same window: without disambiguation,
        /// this one fires immediately on the very first touch of a double-tap-to-zoom gesture,
        /// which meant every double-tap-to-zoom also fired one (sometimes two) calls to
        /// `onNext`/`onPrevious` — the "jumps ahead pages" bug.
        ///
        /// The obvious fix, `shouldRequireFailureOf`, makes this recognizer wait out the whole
        /// system multi-tap timeout on *every* single tap, not just ambiguous ones — noticeably
        /// more sluggish than Photos (measured, tried it first). So instead disambiguation is
        /// hand-rolled here, with our own short window: on a tap, the action is scheduled after
        /// `doubleTapWindow` instead of firing right away; if a second tap lands nearby before
        /// that fires, it's assumed to be turning into a double tap, so the pending action is
        /// dropped and the real `ZoomGestureRelayView` double-tap recognizer (unaffected by any
        /// of this, running with its own normal timing) is the one that ends up handling it.
        private var pendingAction: (() -> Void)?
        private var pendingTapPoint: CGPoint?
        /// Bumped every time a pending action is dropped or fired, so the corresponding
        /// `asyncAfter` closure below can tell it's stale and no-op instead of double-firing.
        private var pendingToken = 0
        private let doubleTapWindow: TimeInterval = 0.25
        /// Taps further apart than this can't be the two halves of one double tap (mirrors the
        /// system recognizer's own proximity requirement): treat the first as a genuine single
        /// tap right away instead of waiting the window out for nothing.
        private let doubleTapMaxDistance: CGFloat = 60

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let relayView, relayView.window != nil else { return }
            let point = recognizer.location(in: relayView)
            guard relayView.bounds.contains(point) else { return }

            if let pendingTapPoint, distance(point, pendingTapPoint) <= doubleTapMaxDistance {
                // Second tap of what's turning into a double tap: let the zoom recognizer take
                // it from here, this one stays silent.
                pendingAction = nil
                self.pendingTapPoint = nil
                pendingToken += 1
                return
            }
            // An unrelated tap arrived while one was still pending (too far away to be its
            // double-tap partner): that one was a genuine single tap all along, run it now
            // rather than making it wait needlessly.
            let stale = pendingAction
            pendingAction = nil
            pendingTapPoint = nil
            pendingToken += 1
            stale?()

            let action = PageTapZoneGeometry.action(
                at: point,
                in: relayView.bounds.size,
                options: PageTapZoneGeometry.Options(
                    oneHanded: oneHanded,
                    oneHandedReversed: oneHandedReversed,
                    rightToLeft: rightToLeft,
                    hotCorners: hotCorners,
                    zonesEnabled: zonesEnabled,
                    topInset: topInset,
                    bottomInset: bottomInset
                )
            )
            guard let action else { return }

            let fire: () -> Void = { [weak self] in
                switch action {
                case .previous: self?.onPrevious()
                case .next: self?.onNext()
                case .toggleControls: self?.onToggleControls()
                case .exit: self?.onExit()
                case .openSettings: self?.onOpenSettings()
                case .toggleDoublePage: self?.onToggleDoublePage()
                }
            }
            pendingAction = fire
            pendingTapPoint = point
            let token = pendingToken
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow) { [weak self] in
                guard let self, self.pendingToken == token else { return }
                self.pendingAction = nil
                self.pendingTapPoint = nil
                fire()
            }
        }

        private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, a.y - b.y)
        }
    }
}
#else
/// Tap/click zones to change page: two side thirds (forward/back) and a central band to
/// show/hide the controls, or — in "one-handed" mode — the whole left/right side.
///
/// Here three `Color.clear` with `.contentShape` + `simultaneousGesture` remain: the
/// hit-testing problem for which the iOS version was rewritten (see above) arises from the
/// competition with `TabView(.page)`/`UIPageViewController` and with the zoom
/// `UIScrollView` of `ZoomableImageView` — neither exists on macOS, where the pager isn't
/// touch-scrolled and `PageView`'s zoom stays on SwiftUI's `MagnificationGesture` within the
/// same hierarchy. So there's no equivalent reason to abandon the simple approach.
struct PageTapZones: View {
    let oneHanded: Bool
    /// In "one-handed" mode, swaps which side (left/right) goes forward and which goes
    /// back: handy to adapt to right/left hand or to how the phone is held.
    let oneHandedReversed: Bool
    let hotCorners: Bool
    /// In manga the left side is the one that *advances*: only needed for the
    /// accessibility labels, since the actual direction reversal already happens in `step`.
    let rightToLeft: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleControls: () -> Void
    /// Active corners with "Hot corners": top left exits the reader, top right opens
    /// settings, bottom right toggles double page.
    let onExit: () -> Void
    let onOpenSettings: () -> Void
    let onToggleDoublePage: () -> Void

    var body: some View {
        GeometryReader { proxy in
            if hotCorners {
                // Non-overlapping rows (rather than a ZStack): two overlapping tap zones
                // would both use simultaneousGesture and would both fire on the same touch.
                VStack(spacing: 0) {
                    HStack {
                        zone(label: "Esci dalla lettura", action: onExit)
                            .frame(width: 88, height: 88)
                        Spacer()
                        zone(label: "Impostazioni", action: onOpenSettings)
                            .frame(width: 88, height: 88)
                    }
                    mainZones(proxy: proxy)
                    HStack {
                        Spacer()
                        zone(label: "Doppia pagina", action: onToggleDoublePage)
                            .frame(width: 88, height: 88)
                    }
                }
            } else {
                mainZones(proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private func mainZones(proxy: GeometryProxy) -> some View {
        if oneHanded {
            // Left and right do the same action (the thumb doesn't need to aim at the exact
            // edge): which one, oneHandedReversed decides. Central band for the controls,
            // as in normal mode.
            let sharedAction = oneHandedReversed ? onPrevious : onNext
            let sharedLabel = oneHandedReversed ? previousLabel : nextLabel
            HStack(spacing: 0) {
                zone(label: sharedLabel, action: sharedAction)
                    .frame(width: min(proxy.size.width * 0.18, 90))
                zone(label: "Mostra o nascondi i controlli", action: onToggleControls)
                zone(label: sharedLabel, action: sharedAction)
                    .frame(width: min(proxy.size.width * 0.18, 90))
            }
        } else {
            HStack(spacing: 0) {
                zone(label: previousLabel, action: onPrevious)
                    .frame(width: min(proxy.size.width * 0.18, 90))
                zone(label: "Mostra o nascondi i controlli", action: onToggleControls)
                zone(label: nextLabel, action: onNext)
                    .frame(width: min(proxy.size.width * 0.18, 90))
            }
        }
    }

    /// `onPrevious`/`onNext` are the left zone and the right one: in manga the left is the
    /// one that moves forward, so the labels must be swapped.
    private var previousLabel: String { rightToLeft ? "Pagina successiva" : "Pagina precedente" }
    private var nextLabel: String { rightToLeft ? "Pagina precedente" : "Pagina successiva" }

    /// Explicit label and trait: the zone is a `Color.clear`, so without these VoiceOver
    /// would have no way to turn the page (and automated tests no target).
    private func zone(label: String, action: @escaping () -> Void) -> some View {
        // simultaneousGesture, not .onTapGesture: the latter claims the touch exclusively,
        // preventing the underlying swipe from working at all.
        Color.clear
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(action))
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
    }
}
#endif

#if os(macOS)
/// On the Mac there's no finger swipe: the equivalent is horizontal two-finger scrolling on
/// the trackpad (or the mouse's horizontal wheel), which SwiftUI doesn't expose — Mac's
/// DragGesture follows a drag with the button held down, not two fingers. We therefore read
/// it from scrollWheel events, with a threshold and a single trigger per gesture so as not
/// to skip several pages at once.
struct ScrollSwipeMonitor: NSViewRepresentable {
    /// +1 = next page, -1 = previous (in reading order, like the swipe on iOS).
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitoringView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitoringView)?.onSwipe = onSwipe
    }

    final class MonitoringView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var didFireForCurrentGesture = false

        // Also called when the view *leaves* a window: without the two guards, a monitor
        // would accumulate on every reopening of the reader, and a single swipe would turn
        // just as many pages.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                removeMonitor()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            // The monitor is app-wide, not view-scoped: without this filter we'd also react
            // to scrolling over settings or another window.
            guard let window = window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            // The inertia after releasing the fingers is the tail of the same gesture:
            // counting it would turn a second page on its own.
            guard event.momentumPhase == [] else { return }

            // A traditional mouse wheel (not a trackpad) never sends `.began`/`.ended`:
            // `event.phase` always stays empty, so the phase-based reset below never
            // triggers for it. It needs to be handled separately, BEFORE the horizontal
            // dominance filter below — which includes it anyway, being just an additional
            // check.
            if event.phase.isEmpty {
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
                accumulated += event.scrollingDeltaX
                guard abs(accumulated) > 40 else { return }
                let direction = accumulated < 0 ? 1 : -1
                accumulated = 0
                onSwipe?(direction)
                return
            }

            // The reset at the gesture's edges stays unconditional with respect to
            // horizontal dominance: a vertical gesture start/end frame must still zero out
            // the state, otherwise a subsequent gesture might come across as already
            // "consumed" and not turn the page.
            if event.phase.contains(.began) {
                accumulated = 0
                didFireForCurrentGesture = false
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                accumulated = 0
                didFireForCurrentGesture = false
                return
            }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
            accumulated += event.scrollingDeltaX
            guard !didFireForCurrentGesture, abs(accumulated) > 40 else { return }
            didFireForCurrentGesture = true
            onSwipe?(accumulated < 0 ? 1 : -1)
        }

        private func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

#endif
