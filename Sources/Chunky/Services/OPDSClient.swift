import Foundation

/// Client for OPDS (Open Publication Distribution System) catalogs, the standard used by
/// Calibre Content Server, Ubooquity, and similar. An OPDS catalog is an Atom feed in which each
/// <entry> is either a subfolder (navigation link) or a downloadable comic (acquisition
/// link).
final class OPDSClient: RemoteBrowsing {
    /// Segue i link `rel="next"` del feed (cataloghi grandi, es. Calibre con
    /// migliaia di titoli): senza, la libreria vedrebbe solo la prima pagina.
    /// Tetto anti-loop: max 5 pagine, e stop se `next` punta alla pagina stessa.
    func listEntries(at url: URL, account: RemoteAccountEntity) async throws -> [RemoteEntry] {
        var allEntries: [RemoteEntry] = []
        var pageURL: URL? = url
        var pagesFetched = 0

        while let current = pageURL, pagesFetched < 5 {
            pagesFetched += 1
            let (entries, next) = try await fetchPage(at: current, account: account)
            allEntries += entries
            pageURL = (next == nil || next == current || next == url) ? nil : next
        }
        return allEntries
    }

    func download(_ entry: RemoteEntry, account: RemoteAccountEntity) async throws -> URL {
        try await downloadFile(from: entry.url, account: account, suggestedName: entry.title)
    }

    private func fetchPage(at url: URL, account: RemoteAccountEntity) async throws -> ([RemoteEntry], URL?) {
        let request = authenticatedRequest(for: url, account: account)
        // Credenziali lette qui in modo sincrono: dopo il primo `await`
        // l'account (main-confined) non va più toccato.
        let (data, response) = try await RemoteSession.data(
            for: request,
            username: account.username,
            password: account.password
        )
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw RemoteBrowsingError.unauthorized
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteBrowsingError.invalidResponse
        }
        return try Self.parseFeed(data, baseURL: url)
    }

    /// Parsing puro (niente rete): testabile con fixture XML inline.
    static func parseFeed(_ data: Data, baseURL: URL) throws -> ([RemoteEntry], URL?) {
        let parser = XMLParser(data: data)
        let delegate = OPDSFeedDelegate(baseURL: baseURL)
        parser.delegate = delegate
        guard parser.parse() else { throw RemoteBrowsingError.parsingFailed }
        let next = delegate.nextHref.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        return (delegate.entries, next)
    }
}

private final class OPDSFeedDelegate: NSObject, XMLParserDelegate {
    let baseURL: URL
    private(set) var entries: [RemoteEntry] = []
    /// Link `rel="next"` a livello di feed (fuori dalle `<entry>`): pagina successiva.
    private(set) var nextHref: String?

    private var currentTitle = ""
    private var currentText = ""
    private var currentElement = ""
    private var isInEntry = false
    private var acquisitionHref: String?
    private var navigationHref: String?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "entry" {
            isInEntry = true
            currentTitle = ""
            acquisitionHref = nil
            navigationHref = nil
        }

        if elementName == "link", !isInEntry {
            if attributeDict["rel"] == "next", let href = attributeDict["href"] {
                nextHref = href
            }
        }

        if elementName == "link", isInEntry {
            let rel = attributeDict["rel"] ?? ""
            let type = attributeDict["type"] ?? ""
            let href = attributeDict["href"]
            if rel.contains("acquisition"), let href = href {
                acquisitionHref = href
            } else if rel == "subsection" || rel.isEmpty || rel == "alternate",
                      type.contains("opds-catalog"), let href = href {
                navigationHref = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "title" {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "title", isInEntry {
            currentTitle = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if elementName == "entry" {
            isInEntry = false
            if let href = acquisitionHref, let url = URL(string: href, relativeTo: baseURL) {
                entries.append(RemoteEntry(title: currentTitle, isContainer: false, url: url.absoluteURL))
            } else if let href = navigationHref, let url = URL(string: href, relativeTo: baseURL) {
                entries.append(RemoteEntry(title: currentTitle, isContainer: true, url: url.absoluteURL))
            }
        }
    }
}
