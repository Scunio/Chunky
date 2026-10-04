import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

@Suite("Cataloghi OPDS")
struct OPDSClientTests {
    private static let baseURL = URL(string: "http://192.168.1.10:8080/opds")!

    private static func feed(entries: String, next: String? = nil) -> Data {
        let nextLink = next.map { "<link rel=\"next\" type=\"application/atom+xml;type=feed\" href=\"\($0)\"/>" } ?? ""
        return Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Test</title>
          \(nextLink)
          \(entries)
        </feed>
        """.utf8)
    }

    @Test("Le entry di acquisizione e navigazione vengono lette")
    func readsEntries() throws {
        let data = Self.feed(entries: """
        <entry>
          <title>Serie Uno</title>
          <link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/opds/serie1"/>
        </entry>
        <entry>
          <title>Fumetto Uno.cbz</title>
          <link rel="http://opds-spec.org/acquisition" type="application/zip" href="/opds/file1.cbz"/>
        </entry>
        """)
        let (entries, next) = try OPDSClient.parseFeed(data, baseURL: Self.baseURL)
        #expect(entries.count == 2)
        #expect(entries[0].isContainer)
        #expect(!entries[1].isContainer)
        #expect(next == nil)
    }

    @Test("Il link next relativo viene risolto contro la pagina corrente")
    func resolvesNextLink() throws {
        let data = Self.feed(entries: "", next: "/opds?page=2")
        let (_, next) = try OPDSClient.parseFeed(data, baseURL: Self.baseURL)
        #expect(next?.absoluteString == "http://192.168.1.10:8080/opds?page=2")
    }

    @Test("Un feed malformato dà parsingFailed")
    func malformedFeedFails() {
        #expect(throws: RemoteBrowsingError.parsingFailed) {
            try OPDSClient.parseFeed(Data("non xml <".utf8), baseURL: Self.baseURL)
        }
    }
}
