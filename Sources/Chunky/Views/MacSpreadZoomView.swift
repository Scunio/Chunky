import SwiftUI

#if os(macOS)
/// Zoom and pan for a whole spread on macOS: one page, or both pages of a double spread
/// together, the way the iOS `SpreadPairView` zooms the pair in a single scroll view. Each
/// page used to zoom on its own around its own centre, so in double page only the clicked half
/// grew, sliding under the other one.
///
/// - Pinch and double-click zoom around the pointer, not the spread's centre.
/// - Dragging, two-finger scrolling and the mouse wheel pan, always clamped so the spread's edge
///   never comes away from the window edge (the drag used to be unbounded, so a page could be
///   thrown off-screen).
/// - ⌘+ / ⌘− / ⌘0 zoom around the centre.
/// - A spread that leaves the screen comes back at fit size.
struct MacSpreadZoomView<Content: View>: View {
    /// False in "Fit width", where the page is a plain vertical scroll view.
    let isEnabled: Bool
    /// False for the neighbouring spreads the pager keeps mounted off-screen.
    let isActive: Bool
    let isZoomed: Binding<Bool>
    @ViewBuilder let content: () -> Content

    @Environment(\.readerZoomCommand) private var zoomCommand
    @AppStorage("motionBlurEnabled") private var isMotionBlurEnabled = true
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Scale and offset when the current pinch began: the pinch is relative to them.
    @State private var pinchStart: (scale: CGFloat, offset: CGSize)?
    @State private var dragStartOffset: CGSize?
    /// The spread's laid-out size at fit scale (narrower than the window when the pages are
    /// taller than wide): the pan limits come from it, not from the window.
    @State private var contentSize: CGSize = .zero
    /// The window area, for the menu commands, which arrive without a gesture's frame.
    @State private var frameSize: CGSize = .zero
    @State private var motionBlurRadius: CGFloat = 0

    static var maxScale: CGFloat { 5 }
    private static var doubleClickScale: CGFloat { 2.5 }

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.size
            content()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
                .scaleEffect(scale)
                .offset(offset)
                .panMotionBlur(isAttached: isMotionBlurEnabled && scale > 1, radius: motionBlurRadius)
                .frame(width: frame.width, height: frame.height)
                // Only while zoomed: at fit size the drag must stay with the page swipe.
                .gesture(dragGesture(frame: frame), including: isEnabled && scale > 1 ? .all : .subviews)
                // Simultaneous, not plain `.gesture`: stacked on the same view, the double-click
                // recognizer held the drag back until it gave up, which on the Mac is only at
                // mouse-up, so the zoomed spread stood still while dragging and jumped there on
                // release. A double-click doesn't move (no drag starts), a drag does (no
                // double-click), so the two never fire for the same input.
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).onEnded { toggleZoom(at: $0.location, frame: frame) },
                    including: isEnabled ? .all : .subviews
                )
                .simultaneousGesture(magnifyGesture(frame: frame), including: isEnabled ? .all : .subviews)
                .background {
                    // Mounted only while zoomed: at fit size the same scroll events turn the
                    // page (`ScrollSwipeMonitor`, which ignores them while zoomed).
                    if scale > 1 {
                        ScrollPanMonitor { dx, dy in
                            offset = clamped(CGSize(width: offset.width + dx, height: offset.height + dy), frame: frame)
                        }
                    }
                }
        }
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { frameSize = $0 }
        .onChange(of: zoomCommand) { _, command in
            // The neighbours see the same command (so becoming the visible spread isn't a
            // "change" that replays the last one) but ignore it.
            if let command, isActive, isEnabled { applyZoomCommand(command.kind) }
        }
        .onChange(of: isActive) { _, active in
            if !active { reset() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { reset() }
        }
    }

    // MARK: - Gestures

    private func magnifyGesture(frame: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? (scale, offset)
                if pinchStart == nil { pinchStart = start }
                let newScale = min(max(start.scale * value.magnification, 1), Self.maxScale)
                offset = clamped(
                    anchoredOffset(at: value.startLocation, frame: frame, from: start, to: newScale),
                    frame: frame, scale: newScale
                )
                scale = newScale
                syncZoomedState()
            }
            .onEnded { _ in
                pinchStart = nil
                if scale <= 1.01 {
                    reset()
                } else {
                    syncZoomedState()
                }
            }
    }

    private func dragGesture(frame: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                let start = dragStartOffset ?? offset
                if dragStartOffset == nil { dragStartOffset = start }
                let newOffset = clamped(
                    CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height),
                    frame: frame
                )
                if isMotionBlurEnabled {
                    let speed = hypot(newOffset.width - offset.width, newOffset.height - offset.height)
                    motionBlurRadius = min(speed * 0.3, 6)
                }
                offset = newOffset
            }
            .onEnded { _ in
                dragStartOffset = nil
                if motionBlurRadius > 0 {
                    withAnimation(.easeOut(duration: 0.15)) { motionBlurRadius = 0 }
                }
            }
    }

    // MARK: - Zoom changes

    private func toggleZoom(at location: CGPoint, frame: CGSize) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if scale > 1 {
                scale = 1
                offset = .zero
            } else {
                let target = Self.doubleClickScale
                offset = clamped(
                    anchoredOffset(at: location, frame: frame, from: (scale, offset), to: target),
                    frame: frame, scale: target
                )
                scale = target
            }
        }
        syncZoomedState()
    }

    private func applyZoomCommand(_ kind: ReaderZoomCommand.Kind) {
        let target: CGFloat
        switch kind {
        case .zoomIn: target = min(scale * 1.25, Self.maxScale)
        case .zoomOut: target = max(scale / 1.25, 1)
        case .reset: target = 1
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            if target <= 1.01 {
                scale = 1
                offset = .zero
            } else {
                // Around the centre: the point in the middle of the window stays put.
                let ratio = target / scale
                offset = clamped(CGSize(width: offset.width * ratio, height: offset.height * ratio), frame: frameSize, scale: target)
                scale = target
            }
        }
        syncZoomedState()
    }

    private func reset() {
        pinchStart = nil
        dragStartOffset = nil
        motionBlurRadius = 0
        if scale != 1 || offset != .zero {
            scale = 1
            offset = .zero
        }
        // The pager's `isZoomed` is shared by the mounted spreads, and only the visible one
        // can be zoomed: one leaving the screen zoomed must not leave page turns suspended.
        if isZoomed.wrappedValue { isZoomed.wrappedValue = false }
    }

    private func syncZoomedState() {
        let zoomed = scale > 1.01
        if isZoomed.wrappedValue != zoomed { isZoomed.wrappedValue = zoomed }
    }

    // MARK: - Geometry

    private func anchoredOffset(
        at location: CGPoint, frame: CGSize, from start: (scale: CGFloat, offset: CGSize), to newScale: CGFloat
    ) -> CGSize {
        SpreadZoomGeometry.anchoredOffset(
            at: location, frame: frame, startScale: start.scale, startOffset: start.offset, newScale: newScale
        )
    }

    private func clamped(_ proposed: CGSize, frame: CGSize, scale: CGFloat? = nil) -> CGSize {
        SpreadZoomGeometry.clamped(
            proposed, content: contentSize == .zero ? frame : contentSize, frame: frame, scale: scale ?? self.scale
        )
    }
}

private extension View {
    /// The drag's motion blur, attached for the whole time the spread is zoomed and absent at fit
    /// size (where `.blur`, even at radius zero, would cost a Core Image pass on every frame).
    ///
    /// The branch must not follow the radius: switching an `if` rebuilds everything inside it,
    /// and the radius goes to zero on every drag event without movement. The pages were
    /// recreated many times a second mid-drag, so the zoomed spread froze while dragging and
    /// only jumped to its new place on release.
    @ViewBuilder
    func panMotionBlur(isAttached: Bool, radius: CGFloat) -> some View {
        if isAttached {
            self.blur(radius: radius)
        } else {
            self
        }
    }
}
#endif

/// The pure geometry of `MacSpreadZoomView`, kept platform-neutral so the tests run everywhere.
enum SpreadZoomGeometry {
    /// The offset that keeps the content point under `location` (window coordinates) in place
    /// while the scale goes from `startScale` to `newScale`. `scaleEffect` scales around the
    /// centre, then `offset` moves: a point at `p` from the centre is drawn at `p * s + o`.
    static func anchoredOffset(
        at location: CGPoint, frame: CGSize, startScale: CGFloat, startOffset: CGSize, newScale: CGFloat
    ) -> CGSize {
        let anchor = CGSize(width: location.x - frame.width / 2, height: location.y - frame.height / 2)
        let ratio = newScale / max(startScale, 0.01)
        return CGSize(
            width: anchor.width - (anchor.width - startOffset.width) * ratio,
            height: anchor.height - (anchor.height - startOffset.height) * ratio
        )
    }

    /// Keeps content of size `content`, scaled by `scale` and centred in `frame`, covering the
    /// frame wherever it overflows it, and centred on an axis where it still fits.
    static func clamped(_ proposed: CGSize, content: CGSize, frame: CGSize, scale: CGFloat) -> CGSize {
        let maxX = max((content.width * scale - frame.width) / 2, 0)
        let maxY = max((content.height * scale - frame.height) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}
