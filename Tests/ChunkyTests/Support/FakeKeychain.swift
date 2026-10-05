import Foundation
import Security

/// In-memory keychain for tests. Distinguishes items based on
/// `kSecUseDataProtectionKeychain`, because that's exactly the distinction the migration
/// needs to be able to cross: it reads from the legacy keychain and rewrites into the modern one.
final class FakeKeychain: KeychainAccessing {
    private struct Key: Hashable {
        let service: String
        let account: String
        let dataProtection: Bool
    }

    private var items: [Key: Data] = [:]
    private(set) var addCount = 0

    /// Simulates a keychain that rejects writes, as happens in a build lacking the
    /// data-protection entitlement.
    var addStatusOverride: OSStatus?
    /// Simulates a keychain whose modern (data-protection) store is broken while the
    /// legacy one works: writes there report success but reads find nothing.
    /// `nil` = modern behaves normally; `.some(errSecSuccess)` = modern add succeeds
    /// but modern reads stay empty; any other status = modern add fails with it.
    var modernWriteBlackhole = false
    var modernAddStatusOverride: OSStatus?

    private func key(from dictionary: [String: Any]) -> Key {
        Key(
            service: dictionary[kSecAttrService as String] as? String ?? "",
            account: dictionary[kSecAttrAccount as String] as? String ?? "",
            dataProtection: dictionary[kSecUseDataProtectionKeychain as String] as? Bool ?? false
        )
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        let k = key(from: query)
        if modernWriteBlackhole, k.dataProtection { return (errSecItemNotFound, nil) }
        guard let data = items[k] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        if let addStatusOverride { return addStatusOverride }
        if key(from: attributes).dataProtection, let modernAddStatusOverride {
            return modernAddStatusOverride
        }
        let itemKey = key(from: attributes)
        guard items[itemKey] == nil else { return errSecDuplicateItem }
        items[itemKey] = attributes[kSecValueData as String] as? Data
        addCount += 1
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        items.removeValue(forKey: key(from: query)) == nil ? errSecItemNotFound : errSecSuccess
    }

    // MARK: - Test utilities

    /// Writes directly into the "legacy" keychain, simulating an installation that predates
    /// the introduction of `kSecUseDataProtectionKeychain`.
    func seedLegacy(service: String, account: String, password: String) {
        items[Key(service: service, account: account, dataProtection: false)] = Data(password.utf8)
    }

    /// Writes directly into the modern (data-protection) keychain.
    func seedModern(service: String, account: String, password: String) {
        items[Key(service: service, account: account, dataProtection: true)] = Data(password.utf8)
    }

    func value(service: String, account: String, dataProtection: Bool) -> String? {
        items[Key(service: service, account: account, dataProtection: dataProtection)]
            .flatMap { String(data: $0, encoding: .utf8) }
    }
}
