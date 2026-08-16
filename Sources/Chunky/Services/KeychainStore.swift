import Foundation
import Security

/// Minimal wrapper over the Keychain for remote account credentials (WebDAV, OPDS with
/// authentication) and for the parental lock passcode. Passwords are never
/// saved in Core Data.
///
/// All queries use `kSecUseDataProtectionKeychain`. Without this key, on macOS
/// items end up in the legacy "file-based" keychain instead of the modern one
/// shared with iOS: different behavior between the two platforms and no protection
/// tied to device unlock. On iOS the key has no effect.
/// The three Keychain operations used by the app, isolated behind a protocol.
///
/// This exists to make the migration away from the legacy keychain testable: tests can't
/// use the real keychain, because the data-protection entitlement belongs to the host
/// process and an unsigned test bundle doesn't have it. Without this seam, the one piece
/// of logic that could actually regress would be left without tests.
protocol KeychainAccessing {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychain: KeychainAccessing {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainStore {
    private static let service = "com.scunio.Chunky.remoteAccounts"

    /// Replaceable in tests. In production it's always the system keychain.
    static var backend: KeychainAccessing = SystemKeychain()

    private static func baseQuery(account: String, useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    static func savePassword(_ password: String, forAccount id: UUID) {
        let account = id.uuidString
        // Delete from both keychains: if the item existed in the old one, leaving it
        // there would create two diverging values for the same account.
        // Order matters: first write to the modern keychain, and only if the write
        // succeeds delete the legacy copy. Deleting first, a failed `add`
        // (a build without the data-protection entitlement) would silently destroy
        // the only existing copy of the password or of the parental passcode.
        _ = backend.delete(baseQuery(account: account, useDataProtection: true))

        var attributes = baseQuery(account: account, useDataProtection: true)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = backend.add(attributes)
        guard status == errSecSuccess else {
            DiagnosticLog.log("Keychain: salvataggio fallito (OSStatus \(status)); copia storica conservata")
            return
        }
        _ = backend.delete(baseQuery(account: account, useDataProtection: false))
    }

    static func password(forAccount id: UUID) -> String? {
        let account = id.uuidString
        if let password = read(account: account, useDataProtection: true) {
            return password
        }
        // Migration: Mac users who had already saved a password find it in the
        // legacy keychain. It's read once here and rewritten to the modern one,
        // otherwise the update would make credentials and the parental passcode disappear.
        guard let legacy = read(account: account, useDataProtection: false) else { return nil }
        savePassword(legacy, forAccount: id)
        return legacy
    }

    static func deletePassword(forAccount id: UUID) {
        let account = id.uuidString
        _ = backend.delete(baseQuery(account: account, useDataProtection: true))
        _ = backend.delete(baseQuery(account: account, useDataProtection: false))
    }

    private static func read(account: String, useDataProtection: Bool) -> String? {
        var query = baseQuery(account: account, useDataProtection: useDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, data) = backend.copyMatching(query)
        guard status == errSecSuccess, let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

}
