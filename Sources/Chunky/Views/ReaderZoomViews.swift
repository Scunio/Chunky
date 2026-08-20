import SwiftUI
#if os(iOS)
import UIKit

// UIKit layer of the reader's zoom (pinch, pan while zoomed, double tap), extracted from
// `ReaderSupportViews.swift`. `ZoomableImageView` and `SpreadZoomableImageView` are internal
// and no longer private because the page content that uses them now lives in another file.

/// Pinch-to-zoom, pan while zoomed and double-tap on the page as in Photos: a real
/// `UIScrollView` with native zoom, not SwiftUI gestures layered on top of the pager.
///
/// The initial plan was to let the `UIScrollView` itself "win" the two-finger touches,
/// relying on the simultaneous recognition UIKit already handles for nested scroll views.
/// That's not enough: `PageTapZones` (the invisible tap-to-turn-page zones) sits *above* the
/// content in the same ZStack and, with `.contentShape(Rectangle())`, covers the whole page
/// — by UIKit's hit-testing rules it's the one that wins the initial touch, always,
/// regardless of which pager is underneath. Verified live with logs on `touchesBegan`: zero
/// touches reached the scroll view, not even a single tap.
///
/// The solution is the same one already used for two-finger brightness (see
/// `WindowPanRelayView` below): a recognizer hooked onto the `window`, not this view, with
/// `hitTest` always returning `nil`. The `window` is an ancestor of *any* view hit by the
/// hit-test (`PageTapZones` included), so its recognizers still receive every touch — pinch
/// and two-finger pan included — regardless of who "wins" the hit-test for the initial
/// touch. `UIScrollView`'s native pinch/pan (its own internal `pinchGestureRecognizer`) stays
/// unused for the same reason the original SwiftUI `MagnificationGesture` was dead: zoom is
/// driven "by hand" from an external recognizer, on the same `UIScrollView`, which remains
/// the simplest way to get pan/rubber-banding rendering for free.
///
/// Several `PageView`s can be alive at the same time (the pager caches adjacent pages for
/// smooth swiping): each recognizer only acts if the gesture's point falls within its own
/// scroll view's bounds, so only the page that's actually visible responds.
private final class ZoomingScrollView: UIScrollView {
    weak var coordinator: ZoomableImageView.Coordinator?

    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator?.layOutImage(in: self)
    }
}

/// Never intercepts hit-testing (see the comment on `ZoomableImageView` above): its
/// recognizers, hooked onto the window, receive every touch anyway because the window is an
/// ancestor of whatever view gets hit by the hit-test.
private final class ZoomGestureRelayView: UIView {
    weak var coordinator: ZoomableImageView.Coordinator?
    private var recognizers: [UIGestureRecognizer] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        recognizers = []
        guard let window, let coordinator else { return }

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(ZoomableImageView.Coordinator.handlePinch(_:)))
        pinch.delegate = coordinator
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(ZoomableImageView.Coordinator.handlePan(_:)))
        pan.delegate = coordinator
        pan.maximumNumberOfTouches = 1
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(ZoomableImageView.Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coordinator

        for recognizer in [pinch, pan, doubleTap] as [UIGestureRecognizer] {
            recognizer.cancelsTouchesInView = false
            window.addGestureRecognizer(recognizer)
        }
        recognizers = [pinch, pan, doubleTap]
    }

    deinit {
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
    }
}

/// Identical to `ZoomGestureRelayView`, but for `SpreadZoomableImageView.Coordinator`: the
/// `#selector` selectors are tied to the concrete type, so the same class can't be reused
/// between the two (the duplication here is the price of that Objective-C constraint, not a
/// choice).
private final class SpreadZoomGestureRelayView: UIView {
    weak var coordinator: SpreadZoomableImageView.Coordinator?
    private var recognizers: [UIGestureRecognizer] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        recognizers = []
        guard let window, let coordinator else { return }

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(SpreadZoomableImageView.Coordinator.handlePinch(_:)))
        pinch.delegate = coordinator
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(SpreadZoomableImageView.Coordinator.handlePan(_:)))
        pan.delegate = coordinator
        pan.maximumNumberOfTouches = 1
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(SpreadZoomableImageView.Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coordinator

        for recognizer in [pinch, pan, doubleTap] as [UIGestureRecognizer] {
            recognizer.cancelsTouchesInView = false
            window.addGestureRecognizer(recognizer)
        }
        recognizers = [pinch, pan, doubleTap]
    }

    deinit {
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    let isZoomed: Binding<Bool>
    var isActive: Bool = true
    /// True only in the double-page path (`pairedContent`), where the width must derive
    /// from the proposed height instead of from the width — see `sizeThatFits`.
    var widthFollowsHeight: Bool = false
    /// Same zone map `PageTapZones` uses, so `handleDoubleTap` can refuse to zoom on a tap
    /// that lands in a page-turn zone — see the comment there.
    var tapZoneOptions = PageTapZoneGeometry.Options(
        oneHanded: false, oneHandedReversed: false, rightToLeft: false,
        hotCorners: false, zonesEnabled: false, topInset: 0, bottomInset: 0
    )

    func makeCoordinator() -> Coordinator { Coordinator(isZoomed: isZoomed) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ZoomingScrollView()
        // Lets `ReaderLayoutUITests` measure the page's own viewport: the collection view stays
        // full-screen even when its cells don't, so the pager's frame hides the regression.
        scrollView.accessibilityIdentifier = "reader.page"
        scrollView.coordinator = context.coordinator
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.isUserInteractionEnabled = false
        scrollView.bounces = false
        scrollView.bouncesZoom = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        let relay = ZoomGestureRelayView(frame: .zero)
        relay.coordinator = context.coordinator
        scrollView.addSubview(relay)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.isZoomed = isZoomed
        context.coordinator.tapZoneOptions = tapZoneOptions
        // The pager keeps nearby pages alive for smooth swiping (see `isActive`'s doc
        // comment below): if a page goes from active to inactive while still zoomed in
        // (e.g. the user zooms, then taps/swipes to another page without zooming back out
        // first), nothing else ever calls `scrollViewDidZoom` on this now-inactive scroll
        // view again, and the shared `isZoomed` binding — which gates every swipe-to-turn
        // path — stays stuck at `true` for the rest of the session. Resetting here as soon
        // as the page deactivates keeps the binding in sync with what's actually on screen.
        if context.coordinator.isActive, !isActive, scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: false)
            if isZoomed.wrappedValue { isZoomed.wrappedValue = false }
        }
        context.coordinator.isActive = isActive
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
            // Page change: always restart from unzoomed, as in the original app (zoom
            // doesn't "follow" from one page to the next).
            scrollView.setZoomScale(1, animated: false)
        }
        context.coordinator.layOutImage(in: scrollView)
    }

    /// Lets `ZoomableImageView` size itself the way `Image().scaledToFit()` would: without
    /// this, a `UIViewRepresentable` can't compute a size on its own from the image's
    /// proportions, and would end up either with no dimensions or as big as the available
    /// space instead of as big as the image.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIScrollView, context: Context) -> CGSize? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let aspect = image.size.width / image.size.height
        func usable(_ value: CGFloat?) -> CGFloat? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
        let width = usable(proposal.width)
        let height = usable(proposal.height)
        // Only in double page must the width derive from the height regardless (see
        // `pairedContent`): there the HStack always proposes a width of its own, which
        // isn't the one we want. Elsewhere the proposed width is the viewport's real one.
        if widthFollowsHeight, let height {
            return CGSize(width: height * aspect, height: height)
        }
        switch (width, height) {
        case let (width?, height?):
            // The whole proposed frame, not the page's shape: the image's fitting happens
            // INSIDE the scroll view (`layOutImage`), which centers it leaving the
            // background bands. Sizing the view to the page instead boxed it into its own
            // rectangle: at rest it looked the same, but once zoomed the content stayed
            // clipped inside it and the bands above and below never got filled. (Giving
            // priority to the height, as the original code did, is the opposite mistake:
            // the view became wider than the screen and `PageView`'s `.clipped()` cut the
            // page off at the sides.)
            return CGSize(width: width, height: height)
        case let (width?, nil):
            return CGSize(width: width, height: width / aspect)
        case let (nil, height?):
            return CGSize(width: height * aspect, height: height)
        case (nil, nil):
            return nil
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var isZoomed: Binding<Bool>
        /// See `ZoomableImageView.isActive` / `PageSpreadView.isActive`: without this,
        /// pinch, pan and double-tap also act on the nearby page the pager keeps alive for
        /// swiping, not just on the one that's really shown — verified live, three
        /// different `Coordinator`s received the same pinch.
        var isActive = true
        var tapZoneOptions = PageTapZoneGeometry.Options(
            oneHanded: false, oneHandedReversed: false, rightToLeft: false,
            hotCorners: false, zonesEnabled: false, topInset: 0, bottomInset: 0
        )
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        private var pinchStartScale: CGFloat = 1

        init(isZoomed: Binding<Bool>) { self.isZoomed = isZoomed }

        func layOutImage(in scrollView: UIScrollView) {
            guard let imageView, let image = imageView.image else { return }
            // `layoutSubviews` (which calls this method, see `ZoomingScrollView`) also fires
            // DURING a pinch or a pan while zoomed, not just on page changes: without this
            // guard, recomputing the "at rest" fit and re-centering here reset the view to
            // the unzoomed position on every pass, while the zoom/pan stayed applied on top
            // — the visible result was the zoom always ending up in the top left and the
            // content clipped. While zoomed, position/size are governed by
            // `handlePinch`/`handlePan` via `zoomScale`/`contentOffset`, not this method.
            guard scrollView.zoomScale <= 1.01 else { return }
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0, image.size.width > 0, image.size.height > 0 else { return }
            let aspect = image.size.width / image.size.height
            var fitSize = boundsSize
            if boundsSize.width / boundsSize.height > aspect {
                fitSize.width = boundsSize.height * aspect
            } else {
                fitSize.height = boundsSize.width / aspect
            }
            if imageView.bounds.size != fitSize {
                imageView.bounds = CGRect(origin: .zero, size: fitSize)
                scrollView.contentSize = fitSize
            }
            center(imageView, in: scrollView)
        }

        private func center(_ imageView: UIImageView, in scrollView: UIScrollView) {
            let boundsSize = scrollView.bounds.size
            var frame = imageView.frame
            frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
            frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
            imageView.frame = frame
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Only when not zoomed: while zoomed, re-centering here would fight against the
            // user's pan exactly as in `layOutImage` — see the comment there.
            if let imageView, scrollView.zoomScale <= 1.01 { center(imageView, in: scrollView) }
            let zoomed = scrollView.zoomScale > 1.01
            if isZoomed.wrappedValue != zoomed { isZoomed.wrappedValue = zoomed }
        }

        /// Receives every touch regardless of who wins the hit-test (see comment on
        /// `ZoomableImageView`): it must therefore coexist with tap zones, page swipe, and
        /// the other recognizers of this same relay.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        private func location(of recognizer: UIGestureRecognizer, in scrollView: UIScrollView) -> CGPoint? {
            // Also declines while a sheet/popover/alert is presented over the reader — see
            // `UIView.hasPresentationAbove` — so pinch/pan/double-tap don't act on the page
            // underneath a modal the user is interacting with.
            guard scrollView.window != nil, !scrollView.hasPresentationAbove else { return nil }
            let point = recognizer.location(in: scrollView)
            return scrollView.bounds.contains(point) ? point : nil
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard isActive, let scrollView else { return }
            switch recognizer.state {
            case .began:
                guard location(of: recognizer, in: scrollView) != nil else { return }
                pinchStartScale = scrollView.zoomScale
            case .changed:
                guard location(of: recognizer, in: scrollView) != nil || scrollView.zoomScale > 1.01 else { return }
                let target = min(max(pinchStartScale * recognizer.scale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
                scrollView.zoomScale = target
            default:
                break
            }
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            // Pan-while-zoomed only: at rest (scale 1) a one-finger drag stays with the page
            // swipe/tap zone underneath, exactly as in the original SwiftUI version
            // (`including: scale > 1 ? .all : .subviews`).
            guard isActive, let scrollView, scrollView.zoomScale > 1.01 else { return }
            switch recognizer.state {
            case .began:
                guard location(of: recognizer, in: scrollView) != nil else { return }
            case .changed:
                let translation = recognizer.translation(in: scrollView)
                var offset = scrollView.contentOffset
                offset.x -= translation.x
                offset.y -= translation.y
                let maxX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
                let maxY = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
                offset.x = min(max(offset.x, 0), maxX)
                offset.y = min(max(offset.y, 0), maxY)
                scrollView.contentOffset = offset
                recognizer.setTranslation(.zero, in: scrollView)
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard isActive, let scrollView, let point = location(of: recognizer, in: scrollView) else { return }
            if scrollView.zoomScale > 1.01 {
                // Zooming back out: always allowed regardless of where the tap lands, the
                // page-turn-zone exclusion below only matters for *starting* a zoom.
                scrollView.setZoomScale(1, animated: true)
            } else {
                // The page-turn zones (`PageTapZoneGeometry.action` returning `.previous`/
                // `.next`) never start a zoom: `TapZoneRelay.Coordinator.handleTap` fires
                // those immediately, with no wait to disambiguate from a double tap (see the
                // comment there) — a tap landing there can never be read as the start of a
                // zoom gesture, on either half of the tap.
                let zoneAction = PageTapZoneGeometry.action(at: point, in: scrollView.bounds.size, options: tapZoneOptions)
                guard zoneAction != .previous, zoneAction != .next else { return }
                let targetScale: CGFloat = 2.5
                let size = scrollView.bounds.size
                let width = size.width / targetScale
                let height = size.height / targetScale
                let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

/// Like `ZoomableImageView`, but for two side-by-side pages zoomable as a single unit (see
/// the comment on `SpreadPairView`): a single `UIScrollView`, content = the two
/// `UIImageView`s next to each other. Same window trick for pinch/pan/double-tap, for the
/// same reason — see the comment on `ZoomableImageView`.
struct SpreadZoomableImageView: UIViewRepresentable {
    /// Exactly two images, already in visual order (left, right).
    let images: [UIImage]
    let isZoomed: Binding<Bool>
    var isActive: Bool = true
    var tapZoneOptions = PageTapZoneGeometry.Options(
        oneHanded: false, oneHandedReversed: false, rightToLeft: false,
        hotCorners: false, zonesEnabled: false, topInset: 0, bottomInset: 0
    )

    func makeCoordinator() -> Coordinator { Coordinator(isZoomed: isZoomed) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = SpreadZoomingScrollView()
        scrollView.accessibilityIdentifier = "reader.page"
        scrollView.coordinator = context.coordinator
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.isUserInteractionEnabled = false
        scrollView.bounces = false
        scrollView.bouncesZoom = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let container = UIView()
        let leadingImageView = UIImageView()
        let trailingImageView = UIImageView()
        for imageView in [leadingImageView, trailingImageView] {
            imageView.contentMode = .scaleAspectFit
            container.addSubview(imageView)
        }
        scrollView.addSubview(container)
        context.coordinator.container = container
        context.coordinator.leadingImageView = leadingImageView
        context.coordinator.trailingImageView = trailingImageView
        context.coordinator.scrollView = scrollView

        let relay = SpreadZoomGestureRelayView(frame: .zero)
        relay.coordinator = context.coordinator
        scrollView.addSubview(relay)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.isZoomed = isZoomed
        context.coordinator.tapZoneOptions = tapZoneOptions
        // See the identical guard in `ZoomableImageView.updateUIView`: same shared
        // `isZoomed` binding, same stuck-scroll risk if a zoomed spread deactivates
        // without zooming back out first.
        if context.coordinator.isActive, !isActive, scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: false)
            if isZoomed.wrappedValue { isZoomed.wrappedValue = false }
        }
        context.coordinator.isActive = isActive
        let spreadChanged = context.coordinator.images.count != images.count
            || zip(context.coordinator.images, images).contains { $0 !== $1 }
        context.coordinator.images = images
        if spreadChanged {
            // Spread change: always restart from unzoomed, exactly as in the single-page
            // path (`ZoomableImageView.updateUIView`). Without this, zoom "followed" from
            // one spread to the next, and on top of that `layOutImages` stayed blocked by
            // the zoom guard, leaving the new pages inside the old ones' frames.
            scrollView.setZoomScale(1, animated: false)
        }
        context.coordinator.layOutImages(in: scrollView)
    }

    /// Recomputes the layout on every real bounds change, not only when SwiftUI calls
    /// `updateUIView` — same reason as `ZoomingScrollView`.
    final class SpreadZoomingScrollView: UIScrollView {
        weak var coordinator: Coordinator?

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.layOutImages(in: self)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var isZoomed: Binding<Bool>
        /// See `ZoomableImageView.Coordinator.isActive`: same problem, same solution, for
        /// the two-page spread.
        var isActive = true
        var tapZoneOptions = PageTapZoneGeometry.Options(
            oneHanded: false, oneHandedReversed: false, rightToLeft: false,
            hotCorners: false, zonesEnabled: false, topInset: 0, bottomInset: 0
        )
        var images: [UIImage] = []
        weak var container: UIView?
        weak var leadingImageView: UIImageView?
        weak var trailingImageView: UIImageView?
        weak var scrollView: UIScrollView?

        init(isZoomed: Binding<Bool>) { self.isZoomed = isZoomed }

        func layOutImages(in scrollView: UIScrollView) {
            guard
                let container, let leadingImageView, let trailingImageView,
                images.count == 2
            else { return }
            // Images are only assigned together with the frame recomputation, below the
            // guards: assigning them earlier would mean drawing new pages inside the old
            // ones' frames (different proportions) every time the spread changes while
            // zoomed. See the comment on `ZoomableImageView.Coordinator.layOutImage`:
            // `layoutSubviews` also fires during pinch/pan while zoomed, and recomputing
            // the two pages' "at rest" width here from `scrollView.bounds` (the viewport,
            // unscaled) reset `container` to its unzoomed size while the zoom stayed applied
            // to its `frame` — result: content clipped or misaligned during zoom.
            guard scrollView.zoomScale <= 1.01 else { return }
            let boundsHeight = scrollView.bounds.height
            guard boundsHeight > 0 else { return }
            if leadingImageView.image !== images[0] { leadingImageView.image = images[0] }
            if trailingImageView.image !== images[1] { trailingImageView.image = images[1] }

            func fitWidth(_ image: UIImage) -> CGFloat {
                guard image.size.height > 0 else { return 0 }
                return boundsHeight * image.size.width / image.size.height
            }
            let leadingWidth = fitWidth(images[0])
            let trailingWidth = fitWidth(images[1])
            leadingImageView.frame = CGRect(x: 0, y: 0, width: leadingWidth, height: boundsHeight)
            trailingImageView.frame = CGRect(x: leadingWidth, y: 0, width: trailingWidth, height: boundsHeight)

            let contentSize = CGSize(width: leadingWidth + trailingWidth, height: boundsHeight)
            if container.bounds.size != contentSize {
                container.bounds = CGRect(origin: .zero, size: contentSize)
                scrollView.contentSize = contentSize
            }
            center(container, in: scrollView)
        }

        private func center(_ container: UIView, in scrollView: UIScrollView) {
            let boundsSize = scrollView.bounds.size
            var frame = container.frame
            frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
            frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
            container.frame = frame
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if let container, scrollView.zoomScale <= 1.01 { center(container, in: scrollView) }
            let zoomed = scrollView.zoomScale > 1.01
            if isZoomed.wrappedValue != zoomed { isZoomed.wrappedValue = zoomed }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        private func location(of recognizer: UIGestureRecognizer, in scrollView: UIScrollView) -> CGPoint? {
            guard scrollView.window != nil, !scrollView.hasPresentationAbove else { return nil }
            let point = recognizer.location(in: scrollView)
            return scrollView.bounds.contains(point) ? point : nil
        }

        private var pinchStartScale: CGFloat = 1

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard isActive, let scrollView else { return }
            switch recognizer.state {
            case .began:
                guard location(of: recognizer, in: scrollView) != nil else { return }
                pinchStartScale = scrollView.zoomScale
            case .changed:
                guard location(of: recognizer, in: scrollView) != nil || scrollView.zoomScale > 1.01 else { return }
                let target = min(max(pinchStartScale * recognizer.scale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
                scrollView.zoomScale = target
            default:
                break
            }
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard
                isActive,
                let scrollView,
                scrollView.zoomScale > 1.01
            else { return }
            switch recognizer.state {
            case .began:
                guard location(of: recognizer, in: scrollView) != nil else { return }
            case .changed:
                let translation = recognizer.translation(in: scrollView)
                var offset = scrollView.contentOffset
                offset.x -= translation.x
                offset.y -= translation.y
                let maxX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
                let maxY = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
                offset.x = min(max(offset.x, 0), maxX)
                offset.y = min(max(offset.y, 0), maxY)
                scrollView.contentOffset = offset
                recognizer.setTranslation(.zero, in: scrollView)
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard
                isActive,
                let scrollView,
                let point = location(of: recognizer, in: scrollView)
            else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                // See the identical check in `ZoomableImageView.Coordinator.handleDoubleTap`:
                // the page-turn zones never start a zoom.
                let zoneAction = PageTapZoneGeometry.action(at: point, in: scrollView.bounds.size, options: tapZoneOptions)
                guard zoneAction != .previous, zoneAction != .next else { return }
                let targetScale: CGFloat = 2.5
                let size = scrollView.bounds.size
                let width = size.width / targetScale
                let height = size.height / targetScale
                let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

#endif
