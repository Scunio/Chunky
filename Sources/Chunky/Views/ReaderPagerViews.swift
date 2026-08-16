import SwiftUI
#if os(iOS)
import UIKit

// Reader pager, share sheet, and two-finger brightness gesture: extracted from
// `ReaderSupportViews.swift`.

/// Changes when something changes that forces all pages to be rebuilt from scratch (the
/// number of pages per spread, the reading direction, the comic itself): otherwise the
/// cached controllers would show spreads composed with the old rules.
struct PagerResetToken: Hashable {
    let doublePage: Bool
    let rightToLeft: Bool
    let pageCount: Int
}

/// Reader pager. Exposes `UIPageViewController` because it's the only component that offers
/// both interactive scrolling that follows the finger and a programmatic page change whose
/// animation can be chosen — the two things needed to make the "Tap page-turn" and "Swipe
/// page-turn" settings truly independent.
struct PageTurnPager<Content: View>: UIViewControllerRepresentable {
    /// Spread start indices, in increasing order: these are the navigation's "steps".
    let starts: [Int]
    @Binding var selection: Int
    let rightToLeft: Bool
    /// Style of the last programmatic page change (tap, keyboard, jump, scrubber).
    let turnStyle: TapPageTurnStyle
    /// With false, finger scrolling is off: either because the swipe style isn't
    /// "Scroll", or because the page is zoomed in and dragging is used for panning.
    let interactiveSwipe: Bool
    let resetToken: PagerResetToken
    let content: (Int) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pager.view.backgroundColor = .clear
        pager.delegate = context.coordinator
        pager.dataSource = interactiveSwipe ? context.coordinator : nil
        pager.setViewControllers([context.coordinator.controller(for: selection)], direction: .forward, animated: false)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Removing the dataSource is the clean way to disable gesture-driven paging while
        // leaving the programmatic page change working. But only when it really changes:
        // assigning it reconfigures the pager's gesture recognizers, and redoing that on every
        // update (this method runs on every state change in the parent, zoom included)
        // interrupts an ongoing drag. The coordinator is always the same object, so comparing
        // just its presence is enough.
        let wantsInteractiveDataSource = interactiveSwipe
        if (pager.dataSource != nil) != wantsInteractiveDataSource {
            pager.dataSource = wantsInteractiveDataSource ? coordinator : nil
        }

        if coordinator.resetToken != resetToken {
            coordinator.resetToken = resetToken
            coordinator.discardCachedControllers()
            coordinator.currentIndex = selection
            coordinator.lastRefreshedSelection = selection
            pager.setViewControllers([coordinator.controller(for: selection)], direction: .forward, animated: false)
            return
        }

        // Cached controllers are reused exactly as they were created: without this, `content`
        // stays evaluated at creation time and everything that depends on the parent's state
        // freezes — in particular `isActive`, which enables pinch/pan/double-tap only on the
        // current page. A controller born as a dataSource neighbour would come to life
        // inactive and stay that way even once it becomes the visible page.
        //
        // Only on page change, not on every update: reassigning `rootView` re-renders the
        // pages, including the ones UIKit is currently animating. The comparison uses a
        // separate index rather than `currentIndex`, because after an interactive swipe
        // `currentIndex` is already aligned (`didFinishAnimating` updates it) and a check
        // against that would never trigger.
        if coordinator.lastRefreshedSelection != selection {
            coordinator.lastRefreshedSelection = selection
            coordinator.refreshCachedContent()
        }

        // The comparison is against the index kept by the coordinator, never against a
        // captured value: this method is called on every state change in the parent (zoom,
        // for one, changes on every pinch) and a wrong comparison would turn the page on its
        // own.
        guard selection != coordinator.currentIndex else { return }
        let indexIncreasing = selection > coordinator.currentIndex
        coordinator.currentIndex = selection
        let next = coordinator.controller(for: selection)
        let direction = Self.navigationDirection(indexIncreasing: indexIncreasing, rightToLeft: rightToLeft)
        switch turnStyle {
        case .slide:
            pager.setViewControllers([next], direction: direction, animated: true)
        case .fade:
            UIView.transition(with: pager.view, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                pager.setViewControllers([next], direction: direction, animated: false)
            }
        case .immediate, .disabled:
            pager.setViewControllers([next], direction: direction, animated: false)
        }
    }

    /// `.forward` makes the new page enter from the right. The page with the higher index
    /// is on the right in LTR and on the left in manga, so in manga the two directions must
    /// be swapped. Same rule for the neighbour returned to the dataSource, so the two can
    /// never diverge.
    static func navigationDirection(indexIncreasing: Bool, rightToLeft: Bool) -> UIPageViewController.NavigationDirection {
        (indexIncreasing != rightToLeft) ? .forward : .reverse
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageTurnPager
        var currentIndex: Int
        /// Last index for which `refreshCachedContent` has already run.
        var lastRefreshedSelection: Int
        var resetToken: PagerResetToken
        private var controllers: [Int: UIHostingController<Content>] = [:]

        init(_ parent: PageTurnPager) {
            self.parent = parent
            self.currentIndex = parent.selection
            self.lastRefreshedSelection = parent.selection
            self.resetToken = parent.resetToken
        }

        func discardCachedControllers() {
            controllers.removeAll()
        }

        /// Realigns the content of already-created controllers to the parent's current state:
        /// `UIHostingController` doesn't re-evaluate its own `rootView` on its own, it must be
        /// reassigned.
        func refreshCachedContent() {
            for (index, hosting) in controllers {
                hosting.rootView = parent.content(index)
            }
        }

        func controller(for index: Int) -> UIHostingController<Content> {
            if let existing = controllers[index] { return existing }
            let hosting = UIHostingController(rootView: parent.content(index))
            hosting.view.backgroundColor = .clear
            controllers[index] = hosting
            pruneCache(around: index)
            return hosting
        }

        /// We only keep nearby spreads in the cache: in a long comic, keeping them all would
        /// mean holding every already-decoded image in memory. The outgoing one stays alive
        /// anyway for as long as it's needed, because the pager retains it as a child.
        private func pruneCache(around index: Int) {
            guard let position = parent.starts.firstIndex(of: index) else { return }
            let keep = Set((position - 2...position + 2)
                .filter { parent.starts.indices.contains($0) }
                .map { parent.starts[$0] })
            controllers = controllers.filter { keep.contains($0.key) }
        }

        private func index(of viewController: UIViewController) -> Int? {
            controllers.first(where: { $0.value === viewController })?.key
        }

        private func neighbour(of viewController: UIViewController, offset: Int) -> UIViewController? {
            guard let index = index(of: viewController),
                  let position = parent.starts.firstIndex(of: index) else { return nil }
            let target = position + offset
            guard parent.starts.indices.contains(target) else { return nil }
            return controller(for: parent.starts[target])
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            // "Before" is what's on the left: in manga that's the page with the higher index.
            neighbour(of: viewController, offset: parent.rightToLeft ? 1 : -1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            neighbour(of: viewController, offset: parent.rightToLeft ? -1 : 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let visible = pageViewController.viewControllers?.first,
                  let index = index(of: visible) else { return }
            // First the coordinator, then the binding: the update that follows sees no
            // difference and doesn't re-animate a page change the finger has already made.
            currentIndex = index
            parent.selection = index
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Intercepts a two-finger pan to adjust screen brightness, without stealing touches from
/// the underlying views (page swipe, tap zones, pinch-to-zoom).
struct TwoFingerBrightnessView: UIViewRepresentable {
    /// Start of the gesture: the listener takes the opportunity to capture the starting
    /// brightness just once, instead of reading it again on every move (see `ReaderView`).
    let onBegan: () -> Void
    /// Normalized vertical delta (-1...1) to add to the current brightness.
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> WindowPanRelayView {
        let view = WindowPanRelayView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: WindowPanRelayView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onBegan = onBegan
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onChange: onChange)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: () -> Void
        var onChange: (CGFloat) -> Void
        init(onBegan: @escaping () -> Void, onChange: @escaping (CGFloat) -> Void) {
            self.onBegan = onBegan
            self.onChange = onChange
        }

        /// Distance between the two fingers at the start of the gesture: used to
        /// distinguish a parallel drag (brightness) from a pinch (zoom), which arrive on the
        /// page the same way — two fingers moving — and which, without this distinction,
        /// would compete for the same gesture. `nil` until the gesture has started with two
        /// fingers.
        private var initialTouchSpread: CGFloat?
        /// True once the distance between the fingers has changed enough to call it a
        /// pinch: from then on the gesture belongs to zoom, and brightness backs off until
        /// the next touch.
        private var gestureIsPinch = false
        /// Beyond this relative deviation between the fingers, the gesture is a pinch, not
        /// a parallel drag: used to keep brightness from sliding while zooming in (two
        /// fingers moving apart still have some vertical component). The pinch side has no
        /// mirrored threshold of its own: it zooms right away, as expected.
        /// With real fingers the distance always wobbles a bit, so too low a threshold
        /// would classify any drag as a pinch.
        private static let pinchSpreadTolerance: CGFloat = 0.08
        /// Vertical movement (in points) to accumulate before touching the brightness.
        ///
        /// Needed because the classification is *reactive*: `pinchSpreadTolerance` only
        /// triggers after the fingers have already moved apart enough, and until that
        /// moment the pan has a vertical component that used to get applied immediately —
        /// so every pinch made the brightness indicator flash for an instant. By
        /// accumulating the first points without applying them, the pinch gets time to
        /// declare itself: if the distance between the fingers changes within that window,
        /// the gesture is a zoom and brightness never moves.
        ///
        /// The delay isn't noticeable: a brightness drag is hundreds of points long, and as
        /// soon as it's classified the accumulated delta gets applied all at once, so none
        /// of the movement already made is lost.
        private static let brightnessClassificationTravel: CGFloat = 16
        /// Vertical movement accumulated and not yet applied, during the classification
        /// window.
        private var pendingVerticalTranslation: CGFloat = 0
        /// True once the gesture has been recognized as a brightness adjustment and the
        /// delta is being applied in real time.
        private var isBrightnessConfirmed = false

        private func touchSpread(of recognizer: UIGestureRecognizer, in view: UIView) -> CGFloat? {
            guard recognizer.numberOfTouches >= 2 else { return nil }
            let first = recognizer.location(ofTouch: 0, in: view)
            let second = recognizer.location(ofTouch: 1, in: view)
            return hypot(second.x - first.x, second.y - first.y)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view, view.bounds.height > 0 else { return }
            switch recognizer.state {
            case .began:
                onBegan()
                initialTouchSpread = touchSpread(of: recognizer, in: view)
                gestureIsPinch = false
                isBrightnessConfirmed = false
                pendingVerticalTranslation = 0
            case .ended, .cancelled, .failed:
                initialTouchSpread = nil
                gestureIsPinch = false
                isBrightnessConfirmed = false
                pendingVerticalTranslation = 0
                return
            default:
                break
            }
            guard !gestureIsPinch else {
                recognizer.setTranslation(.zero, in: view)
                return
            }
            // The distance is only compared between TWO fingers: with a third finger resting
            // down, indices 0 and 1 might refer to a different pair and the distance would
            // suddenly jump, making a normal drag look like a pinch — exactly the case
            // `maximumNumberOfTouches = 3` is meant to tolerate. With a finger count other
            // than two, classification is suspended and starts over as soon as it's back to
            // two.
            if recognizer.numberOfTouches == 2 {
                let spread = touchSpread(of: recognizer, in: view)
                if let initialTouchSpread, initialTouchSpread > 0, let spread,
                   abs(spread / initialTouchSpread - 1) > Self.pinchSpreadTolerance {
                    // The fingers have moved closer or further apart: it's a zoom, not a
                    // brightness adjustment. This sticks for the rest of the gesture, so the
                    // two don't overlap.
                    gestureIsPinch = true
                    recognizer.setTranslation(.zero, in: view)
                    return
                }
                if initialTouchSpread == nil { initialTouchSpread = spread }
            } else {
                initialTouchSpread = nil
            }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)

            // Classification window: it accumulates without applying, so a pinch that
            // declares itself above (`gestureIsPinch`) exits the scene without ever having
            // moved the brightness. A symmetric pinch, moreover, barely moves the midpoint
            // between the two fingers, which is what the pan measures: it often doesn't even
            // reach the threshold.
            guard isBrightnessConfirmed else {
                pendingVerticalTranslation += translation.y
                guard abs(pendingVerticalTranslation) >= Self.brightnessClassificationTravel else { return }
                isBrightnessConfirmed = true
                onChange(-pendingVerticalTranslation / view.bounds.height)
                return
            }
            onChange(-translation.y / view.bounds.height)
        }

        /// Also lets the SwiftUI gestures underneath through (tap zones, page swipe, pinch):
        /// this recognizer must coexist with them, not replace them.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
}

/// Never intercepts hit-testing: a `hitTest` that sometimes returns itself and sometimes nil
/// depending on how many fingers are already down doesn't work, because a touch is assigned
/// permanently to the view resulting from the hit-test at its `touchesBegan` — if the first
/// finger has already been routed to the pager underneath, "stealing" the second finger here
/// isolates it from the first and no recognizer ever gets to see both touches together
/// (neither this pan, nor the page's pinch-to-zoom underneath).
///
/// The two-finger pan is therefore hooked onto the window instead of onto this view: the
/// window is an ancestor of whatever view gets hit by the hit-test (pager, tap zone, image),
/// so its recognizer receives both touches regardless.
final class WindowPanRelayView: UIView {
    weak var coordinator: TwoFingerBrightnessView.Coordinator?
    private weak var recognizer: UIPanGestureRecognizer?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let recognizer = recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
            self.recognizer = nil
        }
        guard let window = window, let coordinator = coordinator else { return }
        let recognizer = UIPanGestureRecognizer(
            target: coordinator,
            action: #selector(TwoFingerBrightnessView.Coordinator.handlePan(_:))
        )
        recognizer.minimumNumberOfTouches = 2
        // Three, not two: if during the drag even just a glancing third finger touches down
        // (or the palm does), with the cap at two the recognizer fails and the gesture dies
        // halfway through.
        recognizer.maximumNumberOfTouches = 3
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = coordinator
        window.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
    }

    deinit {
        if let recognizer = recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
    }
}

#endif
