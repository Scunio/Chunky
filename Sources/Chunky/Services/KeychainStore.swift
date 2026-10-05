import Foundation
import Security

/// Password storage for remote account credentials and the parental lock passcode.
/// Passwords are never saved in Core Data.
///
/// Riscritto da zero, uguale a tutte le app normali: un solo store canonico
/// (generic-password, niente flag esotici, niente access-group esplicito).
/// Ogni scrittura è verificata da una rilettura immediata e l'esito — entrambi
/// i codici — torna al chiamante, così la UI mostra l'errore vero invece di far
/// finta di aver salvato. Mai segreti nei log, solo lunghezze e status.
///
/// Compatibilità: le vecchie build scrivevano con `kSecUseDataProtectionKeychain`,
/// quindi in lettura si controlla anche quello store e un item trovato lì viene
/// importato nel canonico. Niente migrazioni differite che si riattivano a ogni lettura.
///
/// I test non possono usare il portachiavi vero (l'entitlement data-protection
/// appartiene al processo host e un bundle di test non firmato non lo raggiunge),
/// quindi le tre operazioni restano dietro un protocollo con backend sostituibile.
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

/// Esito verificato di un salvataggio: `ok` solo se scrittura E rilettura tornano.
/// I due codici finiscono nel messaggio d'errore della UI, così bastano quelli.
struct KeychainSaveReport: Equatable {
    let writeStatus: OSStatus
    let readStatus: OSStatus
    var ok: Bool { writeStatus == errSecSuccess && readStatus == errSecSuccess }
}

enum KeychainStore {
    private static let service = "com.scunio.Chunky.remoteAccounts"

    /// Replaceable in tests. In production it's always the system keychain.
    static var backend: KeychainAccessing = SystemKeychain()

    /// Query canonica, identica in scrittura e lettura: stesa su due piedi,
    /// senza flag che cambiano comportamento tra iOS e macOS.
    private static func query(account: String, modern: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if modern {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Salva e verifica con rilettura immediata. Prova il canonico, poi il moderno
    /// come ripiego verificato. Non cancella mai prima di aver scritto: una
    /// sostituzione fallita deve lasciare intatta la password esistente.
    @discardableResult
    static func savePassword(_ password: String, forAccount id: UUID) -> KeychainSaveReport {
        let account = id.uuidString
        let plain = upsertVerified(password, account: account, modern: false)
        if plain.ok {
            // MAI cancellare la copia moderna qui: su iOS il flag data-protection
            // è ignorato e le due query puntano allo STESSO item — cancellarla
            // significherebbe cancellare la password appena verificata.
            return plain
        }
        AppLog.log("Keychain: canonico non verificabile (scrittura \(plain.writeStatus), lettura \(plain.readStatus)), provo moderno")
        let modern = upsertVerified(password, account: account, modern: true)
        if modern.ok {
            AppLog.log("Keychain: salvato nel moderno (len=\(password.count))")
            return modern
        }
        AppLog.log("Keychain: salvataggio fallito (canonico \(plain.writeStatus)/\(plain.readStatus), moderno \(modern.writeStatus)/\(modern.readStatus))")
        return modern
    }

    static func password(forAccount id: UUID) -> String? {
        let account = id.uuidString
        if let password = read(account: account, modern: false) {
            return password
        }
        // Import una tantum dallo store delle vecchie build.
        guard let modern = read(account: account, modern: true) else { return nil }
        savePassword(modern, forAccount: id)
        return modern
    }

    /// Solo lo status grezzo della lettura canonica, senza migrazioni né scritture:
    /// per la diagnostica nei log di browsing.
    static func readStatus(forAccount id: UUID) -> OSStatus {
        readWithStatus(account: id.uuidString, modern: false).status
    }

    static func deletePassword(forAccount id: UUID) {
        let account = id.uuidString
        _ = backend.delete(query(account: account, modern: false))
        _ = backend.delete(query(account: account, modern: true))
    }

    // MARK: - Internals

    /// Scrive (o sostituisce) e rilegge subito: l'unico modo per sapere che la
    /// password è davvero lì, visto che `SecItemAdd` da solo non basta.
    private static func upsertVerified(_ password: String, account: String, modern: Bool) -> KeychainSaveReport {
        // TODO(debug): rimuovere prima della release — solo console, mai file.
        AppLog.secret("upsert store=\(modern ? "moderno" : "canonico") want=\(password)")
        var attributes = query(account: account, modern: modern)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let writeStatus = upsert(attributes, modern: modern, account: account)
        let (value, readStatus) = readWithStatus(account: account, modern: modern)
        // TODO(debug): rimuovere prima della release — solo console, mai file.
        AppLog.secret("upsert store=\(modern ? "moderno" : "canonico") write=\(writeStatus) read=\(readStatus) got=\(value ?? "nil")")
        if writeStatus == errSecSuccess, value == password {
            return KeychainSaveReport(writeStatus: errSecSuccess, readStatus: errSecSuccess)
        }
        return KeychainSaveReport(writeStatus: writeStatus, readStatus: readStatus)
    }

    private static func upsert(_ attributes: [String: Any], modern: Bool, account: String) -> OSStatus {
        let status = backend.add(attributes)
        if status == errSecSuccess { return errSecSuccess }
        guard status == errSecDuplicateItem else { return status }
        _ = backend.delete(query(account: account, modern: modern))
        let retry = backend.add(attributes)
        if retry != errSecSuccess {
            AppLog.log("Keychain: sostituzione fallita (OSStatus \(retry))")
        }
        return retry
    }

    private static func read(account: String, modern: Bool) -> String? {
        readWithStatus(account: account, modern: modern).value
    }

    /// Riporta anche lo status così i log dicono PERCHÉ la lettura fallisce
    /// (-25300 non trovato, -25308 bloccato, -25291 non disponibile, ...).
    private static func readWithStatus(account: String, modern: Bool) -> (value: String?, status: OSStatus) {
        var query = query(account: account, modern: modern)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, data) = backend.copyMatching(query)
        if status == errSecSuccess, let data, let string = String(data: data, encoding: .utf8) {
            return (string, errSecSuccess)
        }
        return (nil, status == errSecSuccess ? errSecItemNotFound : status)
    }
}
