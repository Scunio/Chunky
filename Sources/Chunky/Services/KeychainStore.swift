import Foundation
import Security

/// Wrapper minimale sul Keychain per le credenziali degli account remoti (WebDAV, OPDS con
/// autenticazione) e per il passcode del blocco genitori. Le password non vengono mai
/// salvate in Core Data.
///
/// Tutte le query usano `kSecUseDataProtectionKeychain`. Senza questa chiave, su macOS gli
/// elementi finiscono nel portachiavi "file-based" storico invece che in quello moderno
/// condiviso con iOS: comportamento diverso tra le due piattaforme e nessuna protezione
/// legata allo sblocco del dispositivo. Su iOS la chiave è ininfluente.
/// Le tre operazioni Keychain usate dall'app, isolate dietro un protocollo.
///
/// Serve a rendere verificabile la migrazione dal portachiavi storico: i test non possono
/// usare il portachiavi reale, perché l'entitlement data-protection appartiene al processo
/// ospite e un bundle di test non firmato non ce l'ha. Senza questa cucitura, l'unico pezzo
/// di logica che può davvero regredire resterebbe senza test.
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

    /// Sostituibile nei test. In produzione resta sempre il portachiavi di sistema.
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
        // Cancella da entrambi i portachiavi: se l'elemento esisteva nel vecchio, lasciarlo lì
        // creerebbe due valori divergenti per lo stesso account.
        // L'ordine conta: prima si scrive nel portachiavi moderno, e solo se la scrittura
        // riesce si cancella la copia storica. Cancellando per primo, un `add` fallito
        // (build senza l'entitlement data-protection) distruggerebbe l'unica copia
        // esistente della password o del passcode genitori, in silenzio.
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
        // Migrazione: gli utenti Mac che avevano già salvato una password la trovano nel
        // portachiavi storico. La si rilegge una volta e la si riscrive in quello moderno,
        // altrimenti l'aggiornamento farebbe sparire credenziali e passcode genitori.
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
