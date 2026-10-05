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

    /// Ritorna l'OSStatus così il form può mostrare l'errore invece di far finta di aver salvato.
    /// Verifica la rilettura dopo la scrittura: su alcuni device il portachiavi moderno
    /// accetta la scrittura (`errSecSuccess`) ma la rilettura torna vuota — in quel caso
    /// ripiega sullo storico (senza `kSecUseDataProtectionKeychain`), che `password(for:)`
    /// legge già come seconda scelta. Mai dati sensibili nei log, solo lunghezze e status.
    @discardableResult
    static func savePassword(_ password: String, forAccount id: UUID) -> OSStatus {
        let account = id.uuidString
        let modernStatus = store(password, account: account, useDataProtection: true)
        let modernRead = readWithStatus(account: account, useDataProtection: true)
        if modernStatus == errSecSuccess, modernRead.value == password {
            // Solo a scrittura verificata si rimuove l'eventuale copia storica:
            // era l'unica rimasta e ora è duplicata.
            _ = backend.delete(baseQuery(account: account, useDataProtection: false))
            return errSecSuccess
        }
        DiagnosticLog.log("Keychain: moderno non verificabile (saveStatus \(modernStatus), readStatus \(modernRead.status)), provo storico")
        let legacyStatus = store(password, account: account, useDataProtection: false)
        let legacyRead = readWithStatus(account: account, useDataProtection: false)
        if legacyStatus == errSecSuccess, legacyRead.value == password {
            DiagnosticLog.log("Keychain: salvato nello storico (len=\(password.count))")
            return errSecSuccess
        }
        DiagnosticLog.log("Keychain: storico non verificabile (saveStatus \(legacyStatus), readStatus \(legacyRead.status))")
        DiagnosticLog.log("Keychain: salvataggio fallito (moderno \(modernStatus), storico \(legacyStatus)); copie esistenti conservate")
        return legacyStatus != errSecSuccess ? legacyStatus : modernStatus
    }

    /// Scrive (o sostituisce) nel portachiavi indicato, senza mai cancellare prima di
    /// aver scritto: se `add` fallisce (es. build senza l'entitlement data-protection →
    /// errSecMissingEntitlement) la copia esistente deve restare intatta, altrimenti una
    /// Modifica con scrittura fallita cancellerebbe la password buona al Salva successivo.
    private static func store(_ password: String, account: String, useDataProtection: Bool) -> OSStatus {
        var attributes = baseQuery(account: account, useDataProtection: useDataProtection)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = backend.add(attributes)
        if status == errSecSuccess { return errSecSuccess }
        if status == errSecDuplicateItem {
            // Sostituzione: l'item esiste già, quindi ricrealo.
            _ = backend.delete(baseQuery(account: account, useDataProtection: useDataProtection))
            let retry = backend.add(attributes)
            guard retry == errSecSuccess else {
                DiagnosticLog.log("Keychain: sostituzione fallita (OSStatus \(retry))")
                return retry
            }
            return errSecSuccess
        }
        return status
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
        readWithStatus(account: account, useDataProtection: useDataProtection).value
    }

    /// Come `read`, ma riporta anche lo status così i log dicono PERCHÉ la lettura
    /// fallisce (-25300 non trovato, -25308 bloccato, -25291 non disponibile, ...).
    private static func readWithStatus(account: String, useDataProtection: Bool) -> (value: String?, status: OSStatus) {
        var query = baseQuery(account: account, useDataProtection: useDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, data) = backend.copyMatching(query)
        if let data, let string = String(data: data, encoding: .utf8), status == errSecSuccess {
            return (string, errSecSuccess)
        }
        return (nil, status == errSecSuccess ? errSecItemNotFound : status)
    }

}
