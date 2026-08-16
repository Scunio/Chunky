import CoreGraphics
import Testing

@Suite("Doppia pagina")
struct DoublePagePolicyTests {
    @Test("Size class compatta: mai doppia pagina, indipendentemente dalle proporzioni")
    func compactWidthNeverAllowed() {
        #expect(!DoublePagePolicy.isAllowed(viewportSize: CGSize(width: 2000, height: 100), isCompactWidth: true))
        #expect(!DoublePagePolicy.isAllowed(viewportSize: .zero, isCompactWidth: true))
    }

    @Test("Viewport più larga che alta: doppia pagina consentita")
    func wideViewportAllowed() {
        #expect(DoublePagePolicy.isAllowed(viewportSize: CGSize(width: 1000, height: 600), isCompactWidth: false))
    }

    /// This is exactly the gap macOS had: a tall, narrow window would still show
    /// two pages, because there the value was hardcoded to `true` instead of looking at the viewport.
    @Test("Viewport più alta che larga: doppia pagina NON consentita")
    func tallViewportNotAllowed() {
        #expect(!DoublePagePolicy.isAllowed(viewportSize: CGSize(width: 500, height: 1200), isCompactWidth: false))
    }

    @Test("Viewport non ancora misurata (.zero): si assume di sì per non bloccare il primo layout")
    func unmeasuredViewportDefaultsToAllowed() {
        #expect(DoublePagePolicy.isAllowed(viewportSize: .zero, isCompactWidth: false))
    }

    @Test("Proporzioni quadrate non sono 'più larghe che alte': non consentita")
    func squareViewportNotAllowed() {
        #expect(!DoublePagePolicy.isAllowed(viewportSize: CGSize(width: 800, height: 800), isCompactWidth: false))
    }
}
