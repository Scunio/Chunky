import AMSMB2
import Foundation

/// Everything `SMBClient` needs to open a connection, extracted from `RemoteAccountEntity` (or
/// built directly from raw values, e.g. by the "Test di velocità" button before an account
/// exists/is saved) — plain values only, so callers never need a `NSManagedObject` or a Core
/// Data context just to probe a share.
struct SMBConnectionInfo {
    let host: String
    let port: Int32
    let share: String
    let domain: String?
    let username: String?
    let password: String?

    init(host: String, port: Int32, share: String, domain: String? = nil, username: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port
        self.share = share
        self.domain = domain
        self.username = username
        self.password = password
    }

    /// `nil` if the account has no usable host/share (e.g. a WebDAV/OPDS account, which has no
    /// `shareName` at all).
    init?(account: RemoteAccountEntity) {
        let resolvedOverride = account.resolvedAddressOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = (resolvedOverride?.isEmpty == false ? resolvedOverride : account.serverURL?.host) ?? ""
        guard !resolvedHost.isEmpty, let share = account.shareName, !share.isEmpty else { return nil }
        self.init(
            host: resolvedHost,
            port: account.portNumber,
            share: share,
            domain: account.domainOrWorkgroup,
            username: account.username,
            password: account.password
        )
    }
}

/// Result of `SMBClient.measureThroughput`. When the share has no comic file to time a real
/// download against, only `connectLatency` is meaningful — `megabytesPerSecond` stays nil rather
/// than reporting a made-up number.
struct SMBSpeedTestResult {
    let connectLatency: TimeInterval
    let megabytesPerSecond: Double?
}

/// SMB (NAS) client. Connects to a single share (`SMBConnectionInfo.share`) and browses/downloads
/// within it. Unlike WebDAV/OPDS this isn't backed by `URLSession`: every call opens its own
/// `SMB2Manager` connection, does the work, and disconnects — simplest way to stay correct
/// without juggling a shared, possibly-stale connection across browser screens.
final class SMBClient: RemoteBrowsing {
    func listEntries(at url: URL, account: RemoteAccountEntity) async throws -> [RemoteEntry] {
        guard let connection = SMBConnectionInfo(account: account) else { throw RemoteBrowsingError.invalidResponse }
        return try await withConnectedShare(connection) { manager in
            let contents = try await manager.contentsOfDirectory(atPath: self.smbPath(from: url), recursive: false)

            return contents.compactMap { attributes -> RemoteEntry? in
                guard let name = attributes[.nameKey] as? String, name != ".", name != ".." else { return nil }
                let isDirectory = (attributes[.isDirectoryKey] as? NSNumber)?.boolValue ?? false
                let entryURL = self.childURL(of: url, name: name)

                if isDirectory {
                    return RemoteEntry(title: name, isContainer: true, url: entryURL)
                }
                let ext = (name as NSString).pathExtension.lowercased()
                guard remoteComicExtensions.contains(ext) else { return nil }
                return RemoteEntry(title: name, isContainer: false, url: entryURL)
            }
        }
    }

    func download(_ entry: RemoteEntry, account: RemoteAccountEntity) async throws -> URL {
        guard let connection = SMBConnectionInfo(account: account) else { throw RemoteBrowsingError.invalidResponse }
        return try await download(entry, connection: connection)
    }

    func download(_ entry: RemoteEntry, connection: SMBConnectionInfo) async throws -> URL {
        try await withConnectedShare(connection) { manager in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.removeItem(at: destination)
            try await manager.downloadItem(atPath: self.smbPath(from: entry.url), to: destination, progress: nil)

            let finalDestination = FileManager.default.temporaryDirectory.appendingPathComponent(entry.title)
            try? FileManager.default.removeItem(at: finalDestination)
            try FileManager.default.moveItem(at: destination, to: finalDestination)
            return finalDestination
        }
    }

    /// Connects and times the round trip, then — if the share root (or a first-level subfolder)
    /// has a comic file — downloads the smallest one found to estimate throughput. This is a
    /// foreground, one-shot measurement (no guarantee of Wi-Fi stability), meant as a rough
    /// sanity check, not a network-level benchmark. Takes raw connection parameters (not a
    /// `RemoteAccountEntity`): the caller may not have a saved account yet, e.g. when testing the
    /// fields being typed into "Nuovo account" before hitting Salva.
    func measureThroughput(for connection: SMBConnectionInfo) async throws -> SMBSpeedTestResult {
        let connectStart = Date()
        return try await withConnectedShare(connection) { manager in
            let connectLatency = Date().timeIntervalSince(connectStart)

            guard let smallest = try await self.findSmallestComicFile(using: manager) else {
                return SMBSpeedTestResult(connectLatency: connectLatency, megabytesPerSecond: nil)
            }

            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.removeItem(at: destination)
            defer { try? FileManager.default.removeItem(at: destination) }

            let downloadStart = Date()
            try await manager.downloadItem(atPath: smallest.path, to: destination, progress: nil)
            let elapsed = Date().timeIntervalSince(downloadStart)

            guard elapsed > 0 else {
                return SMBSpeedTestResult(connectLatency: connectLatency, megabytesPerSecond: nil)
            }
            let megabytes = Double(smallest.size) / (1024 * 1024)
            return SMBSpeedTestResult(connectLatency: connectLatency, megabytesPerSecond: megabytes / elapsed)
        }
    }

    private func findSmallestComicFile(using manager: SMB2Manager) async throws -> (path: String, size: Int64)? {
        let rootContents = try await manager.contentsOfDirectory(atPath: "", recursive: false)
        var candidates = rootContents.compactMap { comicFileCandidate(from: $0, parentPath: "") }

        if candidates.isEmpty {
            for entry in rootContents {
                guard let name = entry[.nameKey] as? String, name != ".", name != ".." else { continue }
                let isDirectory = (entry[.isDirectoryKey] as? NSNumber)?.boolValue ?? false
                guard isDirectory else { continue }
                let subContents = try? await manager.contentsOfDirectory(atPath: name, recursive: false)
                candidates += (subContents ?? []).compactMap { comicFileCandidate(from: $0, parentPath: name) }
            }
        }

        return candidates.min(by: { $0.size < $1.size })
    }

    private func comicFileCandidate(from attributes: [URLResourceKey: Any], parentPath: String) -> (path: String, size: Int64)? {
        guard let name = attributes[.nameKey] as? String, name != ".", name != ".." else { return nil }
        let isDirectory = (attributes[.isDirectoryKey] as? NSNumber)?.boolValue ?? false
        guard !isDirectory else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        guard remoteComicExtensions.contains(ext) else { return nil }
        guard let size = (attributes[.fileSizeKey] as? NSNumber)?.int64Value else { return nil }
        let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        return (path, size)
    }

    /// Connects to `connection.share`, runs `body`, and always disconnects afterwards — on
    /// success or failure alike — so every call site gets the same connect/work/disconnect
    /// shape instead of repeating it.
    private func withConnectedShare<T>(_ connection: SMBConnectionInfo, _ body: (SMB2Manager) async throws -> T) async throws -> T {
        let manager = try makeManager(for: connection)
        try await manager.connectShare(name: connection.share)
        do {
            let result = try await body(manager)
            try? await manager.disconnectShare()
            return result
        } catch {
            try? await manager.disconnectShare()
            throw error
        }
    }

    private func makeManager(for connection: SMBConnectionInfo) throws -> SMB2Manager {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = connection.host
        components.port = Int(connection.port)
        guard let managerURL = components.url else {
            throw RemoteBrowsingError.invalidResponse
        }

        let credential = URLCredential(
            user: connection.username ?? "",
            password: connection.password ?? "",
            persistence: .none
        )
        guard let manager = SMB2Manager(
            url: managerURL,
            domain: connection.domain ?? "",
            credential: credential
        ) else {
            throw RemoteBrowsingError.invalidResponse
        }
        return manager
    }

    /// The account's root (`listEntries(at: account.serverURL, ...)`) always has an empty path;
    /// subfolder URLs built by `childURL(of:name:)` carry the rest of the path within the share.
    private func smbPath(from url: URL) -> String {
        let path = url.path
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    private func childURL(of parent: URL, name: String) -> URL {
        var components = URLComponents(url: parent, resolvingAgainstBaseURL: false) ?? URLComponents()
        let parentPath = components.path
        components.path = parentPath.isEmpty ? "/\(name)" : "\(parentPath)/\(name)"
        return components.url ?? parent
    }
}
