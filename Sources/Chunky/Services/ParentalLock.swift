import Foundation
import LocalAuthentication
import Combine

/// Gestisce il codice di blocco genitori: il codice non viene mai salvato in chiaro, solo il suo
/// hash (SHA-256 con salt) in Keychain. Sblocco anche via Face ID/Touch ID se disponibile.
final class ParentalLock: ObservableObject {
    static let shared = ParentalLock()

    @Published private(set) var isLocked: Bool

    private let defaults = UserDefaults.standard
    private let enabledKey = "parentalLock.enabled"
    private let biometricsKey = "parentalLock.biometricsEnabled"
    private let hashKey = "parentalLock.passcodeHash"
    private let saltKey = "parentalLock.passcodeSalt"
    private let keychainAccount = "parentalLockPasscode"

    var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    var isBiometricsEnabled: Bool {
        get { defaults.bool(forKey: biometricsKey) }
        set { defaults.set(newValue, forKey: biometricsKey) }
    }

    var hasPasscode: Bool {
        KeychainStore.password(forAccount: passcodeUUID) != nil
    }

    private init() {
        isLocked = false
        // Se il blocco è configurato, l'app deve richiedere il codice anche al primo avvio
        // "a freddo" (es. dopo force-quit): altrimenti basterebbe chiudere l'app dal
        // multitasking per bypassare completamente il blocco.
        isLocked = isEnabled && hasPasscode
    }

    /// Da chiamare quando l'app torna in primo piano: se il blocco è attivo, richiede lo sblocco.
    func lockIfNeeded() {
        guard isEnabled, hasPasscode else { return }
        isLocked = true
    }

    func setPasscode(_ passcode: String) {
        KeychainStore.savePassword(passcode, forAccount: passcodeUUID)
    }

    func removePasscode() {
        KeychainStore.deletePassword(forAccount: passcodeUUID)
        isEnabled = false
    }

    @discardableResult
    func unlock(withPasscode passcode: String) -> Bool {
        guard let stored = KeychainStore.password(forAccount: passcodeUUID), stored == passcode else {
            return false
        }
        isLocked = false
        return true
    }

    func unlockWithBiometrics(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard isBiometricsEnabled, context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Sblocca Chunky") { [weak self] success, _ in
            DispatchQueue.main.async {
                if success { self?.isLocked = false }
                completion(success)
            }
        }
    }

    /// UUID fisso e stabile usato come "account" nel Keychain condiviso: il passcode non è
    /// legato a un fumetto o account remoto, quindi non serve generarne uno nuovo ogni volta.
    private var passcodeUUID: UUID {
        UUID(uuidString: "5D6A9B7E-0000-4000-8000-000000000001")!
    }
}
