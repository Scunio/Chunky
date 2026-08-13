import Foundation
import Security

/// Portachiavi in memoria per i test. Distingue gli elementi in base a
/// `kSecUseDataProtectionKeychain`, perché è esattamente la differenza che la migrazione
/// deve saper attraversare: legge dal portachiavi storico e riscrive in quello moderno.
final class FakeKeychain: KeychainAccessing {
    private struct Key: Hashable {
        let service: String
        let account: String
        let dataProtection: Bool
    }

    private var items: [Key: Data] = [:]
    private(set) var addCount = 0

    /// Simula un portachiavi che rifiuta le scritture, come accade in una build priva
    /// dell'entitlement data-protection.
    var addStatusOverride: OSStatus?

    private func key(from dictionary: [String: Any]) -> Key {
        Key(
            service: dictionary[kSecAttrService as String] as? String ?? "",
            account: dictionary[kSecAttrAccount as String] as? String ?? "",
            dataProtection: dictionary[kSecUseDataProtectionKeychain as String] as? Bool ?? false
        )
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        guard let data = items[key(from: query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        if let addStatusOverride { return addStatusOverride }
        let itemKey = key(from: attributes)
        guard items[itemKey] == nil else { return errSecDuplicateItem }
        items[itemKey] = attributes[kSecValueData as String] as? Data
        addCount += 1
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        items.removeValue(forKey: key(from: query)) == nil ? errSecItemNotFound : errSecSuccess
    }

    // MARK: - Utilità per i test

    /// Scrive direttamente nel portachiavi "storico", simulando un'installazione precedente
    /// all'introduzione di `kSecUseDataProtectionKeychain`.
    func seedLegacy(service: String, account: String, password: String) {
        items[Key(service: service, account: account, dataProtection: false)] = Data(password.utf8)
    }

    func value(service: String, account: String, dataProtection: Bool) -> String? {
        items[Key(service: service, account: account, dataProtection: dataProtection)]
            .flatMap { String(data: $0, encoding: .utf8) }
    }
}
