import Foundation
import Security

/// Minimal wrapper over the Keychain for remote account credentials (WebDAV, OPDS with
/// authentication) and for the parental lock passcode. Passwords are never
/// saved in Core Data.
///
/// Writes go to the plain keychain (no `kSecUseDataProtectionKeychain`), like every
/// normal app: that flag broke reads on some devices (write reported success, read
/// came back empty) with no benefit on iOS. The modern store is still *read* for
/// backward compatibility and used as verified fallback. Never any secret in logs.
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
    /// Scrive nel portachiavi semplice e verifica la rilettura; solo se quello non è
    /// verificabile ripiega sul moderno (con flag data-protection). Mai dati sensibili
    /// nei log, solo lunghezze e status.
    @discardableResult
    static func savePassword(_ password: String, forAccount id: UUID) -> OSStatus {
        let account = id.uuidString
        let plainStatus = store(password, account: account, useDataProtection: false)
        let plainRead = readWithStatus(account: account, useDataProtection: false)
        if plainStatus == errSecSuccess, plainRead.value == password {
            // Solo a scrittura verificata si rimuove l'eventuale copia moderna:
            // era l'unica rimasta e ora è duplicata.
            _ = backend.delete(baseQuery(account: account, useDataProtection: true))
            return errSecSuccess
        }
        DiagnosticLog.log("Keychain: semplice non verificabile (saveStatus \(plainStatus), readStatus \(plainRead.status)), provo moderno")
        let modernStatus = store(password, account: account, useDataProtection: true)
        let modernRead = readWithStatus(account: account, useDataProtection: true)
        if modernStatus == errSecSuccess, modernRead.value == password {
            DiagnosticLog.log("Keychain: salvato nel moderno (len=\(password.count))")
            return errSecSuccess
        }
        DiagnosticLog.log("Keychain: moderno non verificabile (saveStatus \(modernStatus), readStatus \(modernRead.status))")
        DiagnosticLog.log("Keychain: salvataggio fallito (semplice \(plainStatus), moderno \(modernStatus)); copie esistenti conservate")
        return modernStatus != errSecSuccess ? modernStatus : plainStatus
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
        if let password = read(account: account, useDataProtection: false) {
            return password
        }
        // Migration: chi aveva la password nel moderno (vecchie build) la trova qui
        // una volta sola e viene riscritta nel semplice, altrimenti sparirebbe.
        guard let modern = read(account: account, useDataProtection: true) else { return nil }
        savePassword(modern, forAccount: id)
        return modern
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
