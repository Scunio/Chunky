import CoreData
import CryptoKit
import Foundation

/// Deterministic cross-device identity for remote-library progress sync (Infuse-style:
/// files stay on the share, only reading progress travels via CloudKit).
///
/// Two problems make the existing identifiers unusable across devices, so both levels are
/// derived from connection parameters instead:
/// - `RemoteAccountEntity.id` is a random UUID created independently on each device
///   (`RemoteAccountEntity+Extensions.swift`), so it can never match elsewhere.
/// - `ComicEntity.sourceRelativePath` is the remote file's `absoluteString`
///   (`RemoteAccountScanner.swift`), which embeds the host exactly as typed on that
///   device (`NAS.local` vs `192.168.1.10` describe the same file with different strings).
///
/// Everything here is pure (plain values in, plain values out) so it unit-tests without
/// Core Data or network — see `RemoteProgressSyncKeyTests`.
enum RemoteProgressSyncKey {
    /// Minimum data needed to derive an account's sync key. Mapped from
    /// `RemoteAccountEntity` by `descriptor(for:)` so the derivation itself stays free of
    /// managed objects and directly testable.
    struct AccountDescriptor {
        let kind: RemoteAccountKind
        let host: String
        let port: Int32
        /// Share name for SMB (`shareName`); URL path of `serverURL` for WebDAV/OPDS.
        let rootPath: String
        let username: String?
    }

    /// Maps an account to its descriptor, or nil when the account has no usable identity
    /// (e.g. an SMB account without host/share). The host rule mirrors `SMBConnectionInfo`:
    /// `resolvedAddressOverride` (SMB-only field) wins when set, otherwise `serverURL.host`.
    static func descriptor(for account: RemoteAccountEntity) -> AccountDescriptor? {
        switch account.kind {
        case .smb:
            guard let share = account.shareName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !share.isEmpty
            else { return nil }
            let override = account.resolvedAddressOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = (override?.isEmpty == false ? override : account.serverURL?.host) ?? ""
            guard !host.isEmpty else { return nil }
            return AccountDescriptor(
                kind: .smb, host: host, port: account.portNumber,
                rootPath: share, username: account.username
            )
        case .webdav, .opds:
            guard let url = account.serverURL,
                  let host = url.host, !host.isEmpty
            else { return nil }
            let port = Int32(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))
            return AccountDescriptor(
                kind: account.kind, host: host, port: port,
                rootPath: url.path, username: account.username
            )
        }
    }

    /// Manual pairing key: when non-blank it replaces the derived key verbatim (after
    /// the same trim+lowercase normalization, so "Casa" and "casa" can't diverge).
    /// The `custom/` namespace keeps manual keys disjoint from derived ones even if the
    /// user types something shaped like one. This is what makes two differently-spelled
    /// accounts (IP on one device, `.local` hostname on another) match: same string
    /// here on every device, and the in-share layout does the rest.
    static func effectiveAccountSyncKey(descriptor: AccountDescriptor, override: String?) -> String {
        let manual = (override ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !manual.isEmpty else { return accountSyncKey(for: descriptor) }
        return "custom/" + manual
    }

    /// Identifies a share identically on every device. Deliberately excludes the account's
    /// display name (renaming must not break sync) and its random `id`, and includes the
    /// username (two users on the same share must not share progress).
    ///
    /// DHCP caveat: an IP-based host and a `.local` hostname for the same NAS produce
    /// different keys — prefer mDNS hostnames when adding the account on each device.
    static func accountSyncKey(for descriptor: AccountDescriptor) -> String {
        let user = (descriptor.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch descriptor.kind {
        case .smb:
            return "smb/\(descriptor.host.lowercased())/\(descriptor.rootPath.lowercased())/\(descriptor.port)/\(user)"
        case .webdav, .opds:
            return "\(descriptor.kind.rawValue)/\(descriptor.host.lowercased())/\(descriptor.port)\(normalizedBasePath(descriptor.rootPath))/\(user)"
        }
    }

    /// Path of a file within its share, derived by stripping the account-root prefix from
    /// the stored absolute URL string. The host part compares case-insensitively (same
    /// server spelled differently per device); the in-share path keeps its original case
    /// (both devices list it live from the same server, so the spelling is identical).
    /// Returns nil when `sourceAbsoluteString` doesn't belong to this root — fail-closed.
    static func serverPath(rootAbsoluteString: String, sourceAbsoluteString: String) -> String? {
        let root = rootAbsoluteString.hasSuffix("/") ? String(rootAbsoluteString.dropLast()) : rootAbsoluteString
        guard root.count < sourceAbsoluteString.count,
              sourceAbsoluteString.lowercased().hasPrefix(root.lowercased())
        else { return nil }
        let rest = String(sourceAbsoluteString.dropFirst(root.count))
        // "smb://nas/share2/x.cbz" must not match root "smb://nas/share".
        guard rest.hasPrefix("/") else { return nil }
        return rest
    }

    /// Full cross-device identity of one comic's progress. The newline separator can't
    /// collide: neither component can contain it (single-line host/share/path values).
    static func progressKey(accountSyncKey: String, serverPath: String) -> String {
        accountSyncKey + "\n" + serverPath
    }

    /// Deterministic CloudKit `recordName` for a progress key: same key on every device
    /// addresses the same record, so push is idempotent and records can never duplicate
    /// (no server query needed before writing).
    static func recordName(forProgressKey progressKey: String) -> String {
        let digest = SHA256.hash(data: Data(progressKey.utf8))
        return "rp_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Last-writer-wins: a remote record applies only when strictly newer than the local
    /// clock. `nil` local time (never opened / explicitly marked unread before any push)
    /// loses to any remote record; strict `>` (not `>=`) keeps our own just-pushed record
    /// from flapping back when it arrives via fetch.
    static func shouldApply(remoteUpdatedAt: Date, localDateLastOpened: Date?) -> Bool {
        remoteUpdatedAt > (localDateLastOpened ?? .distantPast)
    }

    private static func normalizedBasePath(_ path: String) -> String {
        if path.isEmpty || path == "/" { return "" }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
