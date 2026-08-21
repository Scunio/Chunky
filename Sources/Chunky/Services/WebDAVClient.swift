import Foundation

/// Minimal WebDAV client: lists a folder with PROPFIND (Depth: 1) and downloads files with
/// an authenticated GET. Covers NAS boxes, Nextcloud/ownCloud, and any generic WebDAV server.
final class WebDAVClient: RemoteBrowsing {
    func listEntries(at url: URL, account: RemoteAccountEntity) async throws -> [RemoteEntry] {
        var request = authenticatedRequest(for: url, account: account)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """.utf8)

        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw RemoteBrowsingError.unauthorized
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteBrowsingError.invalidResponse
        }

        let parser = XMLParser(data: data)
        let delegate = WebDAVMultistatusDelegate(baseURL: url)
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

private final class WebDAVMultistatusDelegate: NSObject, XMLParserDelegate {
    let baseURL: URL
    private(set) var entries: [RemoteEntry] = []

    private var currentElement = ""
    private var currentText = ""
    private var currentHref: String?
    private var currentDisplayName: String?
    private var isCollection = false
    private var isFirstResponse = true

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = localName(elementName)
        currentElement = local
        currentText = ""

        if local == "response" {
            currentHref = nil
            currentDisplayName = nil
            isCollection = false
        } else if local == "collection" {
            isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "href":
            currentHref = trimmed
        case "displayname":
            currentDisplayName = trimmed
        case "response":
            defer { isFirstResponse = false }
            // The first <response> in the multistatus is typically the folder itself: we skip it.
            guard !isFirstResponse, let href = currentHref, let url = URL(string: href, relativeTo: baseURL) else { return }
            let displayName = currentDisplayName.flatMap { $0.isEmpty ? nil : $0 }
            let name = displayName
                ?? url.lastPathComponent.removingPercentEncoding
                ?? url.lastPathComponent

            if isCollection {
                entries.append(RemoteEntry(title: name, isContainer: true, url: url.absoluteURL))
            } else {
                let ext = (name as NSString).pathExtension.lowercased()
                if remoteComicExtensions.contains(ext) {
                    entries.append(RemoteEntry(title: name, isContainer: false, url: url.absoluteURL))
                }
            }
        default:
            break
        }
    }

    /// Strips the namespace prefix (e.g. "D:href" -> "href") so it doesn't need to be handled explicitly.
    private func localName(_ elementName: String) -> String {
        if let range = elementName.range(of: ":") {
            return String(elementName[range.upperBound...]).lowercased()
        }
        return elementName.lowercased()
    }
}
