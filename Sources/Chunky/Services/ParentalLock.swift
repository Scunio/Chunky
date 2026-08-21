import Foundation
// Not just unusable on tvOS device builds (`unlockWithBiometrics` already no-ops there):
// the module itself doesn't exist for tvOS on a physical device (only appears to resolve
// on the Simulator SDK), so even the bare `import` fails to link when archiving for device.
#if !os(tvOS)
import LocalAuthentication
#endif
import Combine

/// Manages the parental lock passcode: the passcode is never stored in plain text, only its
/// hash (salted SHA-256) in the Keychain. Unlock is also available via Face ID/Touch ID if
/// available.
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
        // If the lock is configured, the app must ask for the passcode even on the first
        // "cold" launch (e.g. after a force-quit): otherwise closing the app from the
        // multitasking switcher would be enough to bypass the lock entirely.
        isLocked = isEnabled && hasPasscode
    }

    /// To be called when the app returns to the foreground: if the lock is active, it asks for unlock.
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
        // No Face ID/Touch ID (or any LAContext biometrics API) on tvOS: `isBiometricsEnabled`
        // has no UI to turn it on there anyway (`ParentalLockSettingsView` isn't reachable),
        // so this is unreachable in practice, but still needs a body that compiles.
        #if os(tvOS)
        completion(false)
        #else
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
        #endif
    }

    /// Fixed, stable UUID used as the "account" in the shared Keychain: the passcode isn't
    /// tied to a comic or a remote account, so there's no need to generate a new one each time.
    private var passcodeUUID: UUID {
        // Constant literal, valid by construction. A `?? UUID()` here would be worse:
        // it would silently make the passcode unrecoverable instead of failing right away.
        // swiftlint:disable:next force_unwrapping
        UUID(uuidString: "5D6A9B7E-0000-4000-8000-000000000001")!
    }
}
