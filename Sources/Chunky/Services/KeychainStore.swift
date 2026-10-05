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
        var attributes = baseQuery(account: account, useDataProtection: true)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        // Mai cancellare prima di scrivere: se `add` fallisce (es. build senza
        // l'entitlement data-protection → errSecMissingEntitlement, come in un
        // TestFlight senza keychain-access-groups) la copia esistente deve
        // restare intatta, altrimenti una Modifica con rilettura fallita
        // cancellerebbe la password buona al Salva successivo.
        let status = backend.add(attributes)
        if status == errSecSuccess {
            // Solo a scrittura riuscita si rimuove l'eventuale copia storica:
            // era l'unica rimasta e ora è duplicata.
            _ = backend.delete(baseQuery(account: account, useDataProtection: false))
            return
        }
        if status == errSecDuplicateItem {
            // Sostituzione: l'item esiste già, quindi ricrealo. Se anche il
            // secondo tentativo fallisce, resta il log diagnostico.
            _ = backend.delete(baseQuery(account: account, useDataProtection: true))
            let retry = backend.add(attributes)
            guard retry == errSecSuccess else {
                DiagnosticLog.log("Keychain: sostituzione fallita (OSStatus \(retry))")
                return
            }
            _ = backend.delete(baseQuery(account: account, useDataProtection: false))
            return
        }
        DiagnosticLog.log("Keychain: salvataggio fallito (OSStatus \(status)); copie esistenti conservate")
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
