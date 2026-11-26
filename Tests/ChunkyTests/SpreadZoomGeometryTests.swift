import CoreGraphics
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Zoom della doppia pagina su Mac: il punto sotto il cursore resta fermo, e il trascinamento
/// non porta mai il bordo della pagina dentro la finestra.
struct SpreadZoomGeometryTests {
    private let frame = CGSize(width: 1000, height: 800)

    /// Where a content point `p` (from the centre, unscaled) is drawn: `p * s + o`, plus the centre.
    private func drawn(_ point: CGSize, scale: CGFloat, offset: CGSize) -> CGPoint {
        CGPoint(x: point.width * scale + offset.width + frame.width / 2, y: point.height * scale + offset.height + frame.height / 2)
    }

    @Test func zoomKeepsThePointUnderTheCursorInPlace() {
        let cursor = CGPoint(x: 800, y: 200)
        let startOffset = CGSize(width: 30, height: -20)
        let startScale: CGFloat = 1.5
        let newScale: CGFloat = 3
        // The content point currently under the cursor.
        let content = CGSize(
            width: (cursor.x - frame.width / 2 - startOffset.width) / startScale,
            height: (cursor.y - frame.height / 2 - startOffset.height) / startScale
        )
        let offset = SpreadZoomGeometry.anchoredOffset(
            at: cursor, frame: frame, startScale: startScale, startOffset: startOffset, newScale: newScale
        )
        let after = drawn(content, scale: newScale, offset: offset)
        #expect(abs(after.x - cursor.x) < 0.001)
        #expect(abs(after.y - cursor.y) < 0.001)
    }

    @Test func zoomAtTheCentreKeepsTheOffsetCentred() {
        let offset = SpreadZoomGeometry.anchoredOffset(
            at: CGPoint(x: 500, y: 400), frame: frame, startScale: 1, startOffset: .zero, newScale: 2.5
        )
        #expect(offset == .zero)
    }

    @Test func panStopsAtTheSpreadEdge() {
        // A double spread exactly as wide as the window, at 2x: 500 points of overflow per side.
        let content = CGSize(width: 1000, height: 800)
        let clamped = SpreadZoomGeometry.clamped(
            CGSize(width: 5000, height: -5000), content: content, frame: frame, scale: 2
        )
        #expect(clamped == CGSize(width: 500, height: -400))
    }

    @Test func narrowPageStaysCentredWhileItStillFitsHorizontally() {
        // A single tall page, 400 wide: at 2x it is 800 wide, still inside the 1000 window.
        let content = CGSize(width: 400, height: 800)
        let clamped = SpreadZoomGeometry.clamped(
            CGSize(width: 200, height: 200), content: content, frame: frame, scale: 2
        )
        #expect(clamped.width == 0)
        #expect(clamped.height == 200)
    }
}
