import Foundation

/// Minimal application log, persisted to a file, viewable from Settings to understand
/// what happened during a failed import or sync — without having to connect a Mac
/// to read the system console.
enum DiagnosticLog {
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("chunky-diagnostics.log")
    }()

    private static let queue = DispatchQueue(label: "com.scunio.Chunky.DiagnosticLog")
    private static let maxSizeBytes = 512 * 1024

    static func log(_ message: String) {
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
            trimIfNeeded()
        }
    }

    static func readAll() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func trimIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int, size > maxSizeBytes,
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let trimmed = String(content.suffix(maxSizeBytes / 2))
        try? trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
