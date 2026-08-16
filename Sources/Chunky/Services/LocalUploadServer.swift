import Foundation
import Network

/// Small local HTTP server: shows a page with an upload form, so comics can be
/// dragged from a browser on a computer on the same network directly into the library — without
/// a cloud account, without cables.
final class LocalUploadServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    /// Called (on a background thread) with the local URL of each file received.
    var onFileReceived: ((URL) -> Void)?

    private var listener: NWListener?
    private let port: NWEndpoint.Port
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.scunio.Chunky.LocalUploadServer")

    init(port: UInt16 = 8281) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 8281
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.lastError = nil
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        isRunning = false
    }

    /// Local IP addresses on which the server is reachable from the network, to show to the user.
    static func localIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else { return [] }
        defer { freeifaddrs(ifaddrPointer) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            let addrFamily = ptr.pointee.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let address = String(cString: hostname)
            if !address.isEmpty { addresses.append(address) }
        }
        return addresses
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: key) }
            if case .failed = state { self?.connections.removeValue(forKey: key) }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }

            if let request = HTTPRequestParser.parse(buffer), request.isComplete {
                self.handle(request, on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, buffer: buffer)
        }
    }

    private func handle(_ request: HTTPRequestParser.ParsedRequest, on connection: NWConnection) {
        if request.method == "POST" {
            let savedCount = handleUpload(request)
            let body = "\(savedCount) file ricevuti."
            respond(on: connection, status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
        } else {
            respond(on: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(Self.uploadPageHTML.utf8))
        }
    }

    private func handleUpload(_ request: HTTPRequestParser.ParsedRequest) -> Int {
        guard let contentType = request.headers["content-type"],
              let boundary = MultipartParser.boundary(fromContentType: contentType) else {
            return 0
        }
        let parts = MultipartParser.parse(body: request.body, boundary: boundary)
        var savedCount = 0
        for part in parts {
            guard let filename = part.filename, !filename.isEmpty else { continue }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            do {
                try part.data.write(to: destination)
                savedCount += 1
                DispatchQueue.main.async { [weak self] in
                    self?.onFileReceived?(destination)
                }
            } catch {
                continue
            }
        }
        return savedCount
    }

    private func respond(on connection: NWConnection, status: String, contentType: String, body: Data) {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let uploadPageHTML = """
    <!DOCTYPE html>
    <html lang="it">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Chunky — Importa fumetti</title>
      <style>
        body { font-family: -apple-system, sans-serif; max-width: 480px; margin: 60px auto; padding: 0 20px; text-align: center; color: #222; }
        h1 { font-size: 22px; }
        input[type=file] { display: block; margin: 24px auto; }
        button { background: #007AFF; color: white; border: none; padding: 12px 24px; border-radius: 8px; font-size: 16px; }
        #status { margin-top: 16px; color: #666; }
      </style>
    </head>
    <body>
      <h1>Importa fumetti in Chunky</h1>
      <p>Scegli uno o più file CBZ, CBR o PDF dal tuo computer.</p>
      <form id="form">
        <input type="file" id="files" name="files" multiple accept=".cbz,.cbr,.pdf">
        <button type="submit">Carica</button>
      </form>
      <div id="status"></div>
      <script>
        document.getElementById('form').addEventListener('submit', async (e) => {
          e.preventDefault();
          const input = document.getElementById('files');
          const status = document.getElementById('status');
          if (!input.files.length) { return; }
          const formData = new FormData();
          for (const file of input.files) { formData.append('files', file); }
          status.textContent = 'Caricamento in corso…';
          try {
            const res = await fetch('/', { method: 'POST', body: formData });
            status.textContent = await res.text();
          } catch (err) {
            status.textContent = 'Errore: ' + err;
          }
        });
      </script>
    </body>
    </html>
    """
}

/// Minimal HTTP/1.1 parser: just enough to read a GET request or a complete
/// multipart/form-data POST (method, headers, body).
enum HTTPRequestParser {
    struct ParsedRequest {
        let method: String
        let headers: [String: String]
        let body: Data
        let isComplete: Bool
    }

    static func parse(_ data: Data) -> ParsedRequest? {
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerEndRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let method = requestLine.components(separatedBy: " ").first ?? "GET"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEndRange.upperBound
        let body = data.subdata(in: bodyStart..<data.endIndex)
        let expectedLength = headers["content-length"].flatMap(Int.init) ?? 0

        return ParsedRequest(method: method, headers: headers, body: body, isComplete: body.count >= expectedLength)
    }
}

/// Extracts the individual parts (filename + content) from a multipart/form-data body.
enum MultipartParser {
    struct Part {
        let filename: String?
        let data: Data
    }

    static func boundary(fromContentType contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=") else { return nil }
        var boundary = String(contentType[range.upperBound...])
        if let semicolon = boundary.firstIndex(of: ";") { boundary = String(boundary[..<semicolon]) }
        return boundary.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }

    static func parse(body: Data, boundary: String) -> [Part] {
        let boundaryMarker = Data("--\(boundary)".utf8)
        let segments = body.split(separator: boundaryMarker)
        var parts: [Part] = []

        for segment in segments {
            guard let headerEndRange = segment.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headerData = segment.subdata(in: segment.startIndex..<headerEndRange.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8),
                  headerString.contains("Content-Disposition") else { continue }

            var filename: String?
            if let range = headerString.range(of: "filename=\"") {
                let rest = headerString[range.upperBound...]
                if let endQuote = rest.firstIndex(of: "\"") {
                    filename = String(rest[..<endQuote])
                }
            }

            var contentEnd = segment.endIndex
            let trailing = Data("\r\n".utf8)
            if segment.count >= trailing.count, segment.suffix(trailing.count) == trailing {
                contentEnd = segment.index(segment.endIndex, offsetBy: -trailing.count)
            }
            guard headerEndRange.upperBound <= contentEnd else { continue }
            let content = segment.subdata(in: headerEndRange.upperBound..<contentEnd)
            parts.append(Part(filename: filename, data: content))
        }
        return parts
    }
}

private extension Data {
    /// Splits the data on a binary separator (not available out-of-the-box on Data).
    func split(separator: Data) -> [Data] {
        var result: [Data] = []
        var searchStart = startIndex
        while let range = self.range(of: separator, in: searchStart..<endIndex) {
            if range.lowerBound > searchStart {
                result.append(subdata(in: searchStart..<range.lowerBound))
            }
            searchStart = range.upperBound
        }
        if searchStart < endIndex {
            result.append(subdata(in: searchStart..<endIndex))
        }
        return result
    }
}
