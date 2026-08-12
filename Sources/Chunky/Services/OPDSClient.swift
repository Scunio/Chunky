import Foundation

/// Client per cataloghi OPDS (Open Publication Distribution System), lo standard usato da
/// Calibre Content Server, Ubooquity e simili. Un catalogo OPDS è un feed Atom in cui ogni
/// <entry> è o una sotto-cartella (link di navigazione) o un fumetto scaricabile (link di
/// acquisizione).
final class OPDSClient: RemoteBrowsing {
    func listEntries(at url: URL, account: RemoteAccountEntity) async throws -> [RemoteEntry] {
        let request = authenticatedRequest(for: url, account: account)
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw RemoteBrowsingError.unauthorized
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteBrowsingError.invalidResponse
        }

        let parser = XMLParser(data: data)
        let delegate = OPDSFeedDelegate(baseURL: url)
        parser.delegate = delegate
        guard parser.parse() else { throw RemoteBrowsingError.parsingFailed }
        return delegate.entries
    }

    func download(_ entry: RemoteEntry, account: RemoteAccountEntity) async throws -> URL {
        try await downloadFile(from: entry.url, account: account, suggestedName: entry.title)
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: RemoteBrowsingError.invalidResponse)
                }
            }
            task.resume()
        }
    }
}

private final class OPDSFeedDelegate: NSObject, XMLParserDelegate {
    let baseURL: URL
    private(set) var entries: [RemoteEntry] = []

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

        if elementName == "link", isInEntry {
            let rel = attributeDict["rel"] ?? ""
            let type = attributeDict["type"] ?? ""
            let href = attributeDict["href"]
            if rel.contains("acquisition"), let href = href {
                acquisitionHref = href
            } else if (rel == "subsection" || rel.isEmpty || rel == "alternate"),
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
