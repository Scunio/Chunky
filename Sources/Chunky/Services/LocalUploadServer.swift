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

    #if os(tvOS)
    /// tvOS keeps one server for the app's lifetime instead of one per `LocalUploadView`:
    /// leaving the screen (tab switch, Menu) must not cut an upload in progress — see
    /// `LocalUploadView.server`.
    static let tvOSShared = LocalUploadServer()
    #endif

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
                        DiagnosticLog.log("Local upload server failed: \(error.localizedDescription)")
                        self?.lastError = Self.userFacingStartError(error)
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
            DiagnosticLog.log("Local upload server failed to start: \(error.localizedDescription)")
            lastError = Self.userFacingStartError(error)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        isRunning = false
    }

    private static func userFacingStartError(_ error: Error) -> String {
        if let networkError = error as? NWError,
           case .posix(let code) = networkError,
           code == .EADDRINUSE {
            return AppLocalization.localizedString(
                "Impossibile avviare il server locale: la porta è già in uso.",
                comment: "Local server port is already in use"
            )
        }
        return AppLocalization.userFacingError(error)
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

    /// Largest upload accepted (headers excluded). The whole request body is held in memory
    /// until it's complete, so without a cap a single huge (or malicious) POST from anyone on
    /// the Wi-Fi could exhaust the device's memory. 1.5 GB is well above any real CBZ/CBR.
    static let maximumBodyLength = 1_536 * 1_024 * 1_024

    /// Per-connection receive state. A reference type on purpose: with a `Data` value passed
    /// from one `receive` callback to the next, every `append` copied the entire buffer
    /// (the previous callback still held a reference), and re-parsing the request on every
    /// 1 MB chunk copied the body again — quadratic in the upload size.
    private final class ReceiveState {
        var buffer = Data()
        var header: HTTPRequestParser.Header?
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: key) }
            if case .failed = state { self?.connections.removeValue(forKey: key) }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, state: ReceiveState())
    }

    private func receiveRequest(on connection: NWConnection, state: ReceiveState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data { state.buffer.append(data) }

            // Headers are parsed once, as soon as they're all in; after that only the byte
            // count is compared against Content-Length.
            if state.header == nil {
                state.header = HTTPRequestParser.parseHeader(state.buffer)
                if let header = state.header, header.contentLength > Self.maximumBodyLength {
                    DiagnosticLog.log("Upload rifiutato: \(header.contentLength) byte oltre il limite")
                    self.respondTooLarge(on: connection)
                    return
                }
                // No header terminator after a generous amount of data: not a request we serve.
                if state.header == nil, state.buffer.count > 64 * 1_024 {
                    connection.cancel()
                    return
                }
            }

            if let header = state.header {
                let bodyLength = state.buffer.count - header.bodyOffset
                if bodyLength >= header.contentLength {
                    let request = HTTPRequestParser.ParsedRequest(
                        method: header.method,
                        headers: header.headers,
                        // A slice: shares the buffer's storage instead of copying the body.
                        body: state.buffer[(state.buffer.startIndex + header.bodyOffset)...],
                        isComplete: true
                    )
                    self.handle(request, on: connection)
                    return
                }
                // Content-Length missing/lower than what keeps arriving is caught above
                // (complete as soon as the declared length is reached); this guards a body
                // that keeps growing past the cap anyway.
                if bodyLength > Self.maximumBodyLength {
                    self.respondTooLarge(on: connection)
                    return
                }
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, state: state)
        }
    }

    private func respondTooLarge(on connection: NWConnection) {
        let body = AppLocalization.localizedString(
            "File troppo grande per il caricamento.",
            comment: "Local upload server: request body over the size limit"
        )
        respond(on: connection, status: "413 Payload Too Large", contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    private func handle(_ request: HTTPRequestParser.ParsedRequest, on connection: NWConnection) {
        if request.method == "POST" {
            let savedCount = handleUpload(request)
            let body = AppLocalization.plural(
                savedCount,
                singularKey: "%d file ricevuto.",
                pluralKey: "%d file ricevuti.",
                comment: "Local upload server response"
            )
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
            // Il nome arriva dalla rete: solo l'ultimo componente, mai percorsi relativi,
            // e in una cartella dedicata per upload così nomi uguali non si sovrascrivono.
            let safeName = URL(fileURLWithPath: filename).lastPathComponent
            guard !safeName.isEmpty, safeName != ".", safeName != ".." else { continue }
            let uploadDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ChunkyUpload-\(UUID().uuidString)", isDirectory: true)
            let destination = uploadDirectory.appendingPathComponent(safeName)
            do {
                try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
                try part.data.write(to: destination)
                savedCount += 1
                DispatchQueue.main.async { [weak self] in
                    // The importer deletes the folder once the file is in the library; with
                    // nobody to hand it to (screen closed meanwhile) it would stay in tmp.
                    guard let onFileReceived = self?.onFileReceived else {
                        try? FileManager.default.removeItem(at: uploadDirectory)
                        return
                    }
                    onFileReceived(destination)
                }
            } catch {
                try? FileManager.default.removeItem(at: uploadDirectory)
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

    private static var uploadPageHTML: String {
        let languageCode = AppLanguage.current.languageCode
        let title = AppLocalization.localizedString("Chunky — Importa fumetti", comment: "Local upload web page title")
        let heading = AppLocalization.localizedString("Importa fumetti in Chunky", comment: "Local upload web page heading")
        let instructions = AppLocalization.localizedString("Scegli uno o più file CBZ, CBR o PDF dal tuo computer.", comment: "Local upload web page instructions")
        let upload = AppLocalization.localizedString("Carica", comment: "Local upload web page button")
        let uploading = AppLocalization.localizedString("Caricamento in corso…", comment: "Local upload progress")
        let errorPrefix = AppLocalization.localizedString("Errore:", comment: "Local upload web page error prefix")
        return """
    <!DOCTYPE html>
    <html lang="\(languageCode)">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>\(title)</title>
      <style>
        body { font-family: -apple-system, sans-serif; max-width: 480px; margin: 60px auto; padding: 0 20px; text-align: center; color: #222; }
        h1 { font-size: 22px; }
        input[type=file] { display: block; margin: 24px auto; }
        button { background: #007AFF; color: white; border: none; padding: 12px 24px; border-radius: 8px; font-size: 16px; }
        #status { margin-top: 16px; color: #666; }
      </style>
    </head>
    <body>
      <h1>\(heading)</h1>
      <p>\(instructions)</p>
      <form id="form">
        <input type="file" id="files" name="files" multiple accept=".cbz,.cbr,.pdf">
        <button type="submit">\(upload)</button>
      </form>
      <div id="status" data-uploading="\(uploading)" data-error-prefix="\(errorPrefix)"></div>
      <script>
        document.getElementById('form').addEventListener('submit', async (e) => {
          e.preventDefault();
          const input = document.getElementById('files');
          const status = document.getElementById('status');
          if (!input.files.length) { return; }
          const formData = new FormData();
          for (const file of input.files) { formData.append('files', file); }
          status.textContent = status.dataset.uploading;
          try {
            const res = await fetch('/', { method: 'POST', body: formData });
            status.textContent = await res.text();
          } catch (err) {
            status.textContent = status.dataset.errorPrefix + ' ' + err;
          }
        });
      </script>
    </body>
    </html>
    """
    }
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

    /// Request line + headers, parsed once per connection (see `LocalUploadServer.ReceiveState`).
    struct Header {
        let method: String
        let headers: [String: String]
        /// Offset of the first body byte from the buffer's start.
        let bodyOffset: Int
        let contentLength: Int
    }

    static func parseHeader(_ data: Data) -> Header? {
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let (method, headers) = parseHeaderFields(data[data.startIndex..<headerEndRange.lowerBound]) else { return nil }
        return Header(
            method: method,
            headers: headers,
            bodyOffset: headerEndRange.upperBound - data.startIndex,
            contentLength: headers["content-length"].flatMap(Int.init) ?? 0
        )
    }

    private static func parseHeaderFields(_ headerData: Data) -> (String, [String: String])? {
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
        return (method, headers)
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
            let headerData = segment[segment.startIndex..<headerEndRange.lowerBound]
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
            // Slices (here and in `split`) share the request buffer's storage: a 1 GB upload
            // used to be copied twice more on its way to disk.
            let content = segment[headerEndRange.upperBound..<contentEnd]
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
                result.append(self[searchStart..<range.lowerBound])
            }
            searchStart = range.upperBound
        }
        if searchStart < endIndex {
            result.append(self[searchStart..<endIndex])
        }
        return result
    }
}
