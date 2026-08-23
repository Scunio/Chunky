import Foundation
import Testing

@Suite("CBZ")
struct CBZPageProviderTests {
    private func provider(_ fixture: String = "sample.cbz") throws -> CBZPageProvider {
        guard let url = Fixtures.url(fixture) else { throw Fixtures.FixtureError.missing(fixture) }
        return try CBZPageProvider(fileURL: url)
    }

    @Test("Conta solo le pagine immagine, non ComicInfo.xml")
    func pageCountIgnoresMetadata() throws {
        #expect(try provider().pageCount == 3)
        #expect(try provider("sample-noinfo.cbz").pageCount == 2)
    }

    /// The fixture's pages are red/green/blue in this order: if the `localizedStandardCompare`
    /// ordering breaks, the color reveals it, whereas a simple
    /// "image not nil" check would not.
    @Test("Restituisce le pagine nell'ordine dell'archivio", arguments: [
        (0, PixelProbe.RGB.red), (1, PixelProbe.RGB.green), (2, PixelProbe.RGB.blue)
    ])
    func pagesAreInOrder(index: Int, expected: PixelProbe.RGB) throws {
        let image = try provider().image(atPage: index)
        let cgImage = try #require(image.cgImageRepresentation)
        let sampled = try #require(PixelProbe.sample(cgImage, atRelativeX: 0.5, y: 0.5))
        #expect(sampled.isCloseTo(expected), "pagina \(index): atteso \(expected), ottenuto \(sampled)")
    }

    @Test("Un indice fuori range solleva pageOutOfRange", arguments: [-1, 3, 99])
    func outOfRangeThrows(index: Int) throws {
        let sut = try provider()
        #expect(throws: ComicReadError.pageOutOfRange) { try sut.rawData(atPage: index) }
    }

    @Test("Estrae ComicInfo.xml quando presente")
    func extractsComicInfo() throws {
        let xml = try #require(try provider().comicInfoXML)
        let metadata = try #require(ComicInfoMetadata.parse(from: xml))
        #expect(metadata.series == "Topolino")
        #expect(metadata.number == "3595")
    }

    @Test("Nessun ComicInfo.xml quando l'archivio non ce l'ha")
    func noComicInfo() throws {
        #expect(try provider("sample-noinfo.cbz").comicInfoXML == nil)
    }

    @Test("Un archivio corrotto solleva corruptArchive invece di crashare")
    func corruptArchiveThrows() throws {
        let url = try #require(Fixtures.url("corrupt.cbz"))
        #expect(throws: ComicReadError.corruptArchive) { try CBZPageProvider(fileURL: url) }
    }

    @Test("rawData restituisce i byte originali, decodificabili come immagine")
    func rawDataIsDecodable() throws {
        let data = try #require(try provider().rawData(atPage: 0))
        #expect(!data.isEmpty)
        #expect(PlatformImage.from(data: data) != nil)
    }
}

// PDFPageProvider doesn't exist on tvOS: PDFKit isn't available there (see PDFPageProvider.swift).
#if !os(tvOS)
@Suite("PDF")
struct PDFPageProviderTests {
    private func provider() throws -> PDFPageProvider {
        guard let url = Fixtures.url("sample.pdf") else { throw Fixtures.FixtureError.missing("sample.pdf") }
        return try PDFPageProvider(fileURL: url)
    }

    @Test("Conta le pagine del documento")
    func pageCount() throws {
        #expect(try provider().pageCount == 2)
    }

    /// The fixture has the colored quadrant in the TOP LEFT, with the rest white.
    /// A vertically flipped rendering would put the color at the bottom: that's why
    /// the fixture is asymmetric.
    @Test("La pagina non è capovolta verticalmente", arguments: [
        (0, PixelProbe.RGB.red), (1, PixelProbe.RGB.blue)
    ])
    func pageIsNotFlipped(index: Int, expected: PixelProbe.RGB) throws {
        let image = try provider().image(atPage: index)
        let cgImage = try #require(image.cgImageRepresentation)

        let topLeft = try #require(PixelProbe.sample(cgImage, atRelativeX: 0.25, y: 0.15))
        let bottomLeft = try #require(PixelProbe.sample(cgImage, atRelativeX: 0.25, y: 0.85))

        #expect(topLeft.isCloseTo(expected), "in alto a sinistra atteso \(expected), ottenuto \(topLeft)")
        #expect(bottomLeft.isCloseTo(.white), "in basso a sinistra atteso bianco, ottenuto \(bottomLeft)")
    }

    /// `NSImage(size:)` with lockFocus used to produce, on macOS, an image whose size
    /// didn't match the actual pixels.
    @Test("L'immagine renderizzata ha pixel reali con le proporzioni della pagina")
    func renderedSizeMatchesPage() throws {
        let image = try provider().image(atPage: 0)
        let cgImage = try #require(image.cgImageRepresentation)
        #expect(cgImage.width > 0)
        #expect(cgImage.height > 0)
        // The fixture is 100×200 points: the rendering must remain vertical.
        #expect(cgImage.height == cgImage.width * 2)
    }

    @Test("Un indice fuori range solleva pageOutOfRange", arguments: [-1, 2, 99])
    func outOfRangeThrows(index: Int) throws {
        let sut = try provider()
        #expect(throws: ComicReadError.pageOutOfRange) { try sut.image(atPage: index) }
    }
}
#endif

@Suite("CBR")
struct CBRPageProviderTests {
    /// The .cbr fixture requires a RAR compressor, which isn't available everywhere:
    /// as long as it's missing, the test reports itself as skipped instead of failing opaquely.
    @Test("Legge le pagine da un archivio RAR")
    func readsPages() throws {
        try withKnownIssue("Fixture sample.cbr non presente nel bundle", isIntermittent: true) {
            guard let url = Fixtures.url("sample.cbr") else { throw Fixtures.FixtureError.missing("sample.cbr") }
            let sut = try CBRPageProvider(fileURL: url)
            #expect(sut.pageCount == 3)
            let image = try sut.image(atPage: 0)
            let cgImage = try #require(image.cgImageRepresentation)
            let sampled = try #require(PixelProbe.sample(cgImage, atRelativeX: 0.5, y: 0.5))
            #expect(sampled.isCloseTo(.red))
        }
    }
}
