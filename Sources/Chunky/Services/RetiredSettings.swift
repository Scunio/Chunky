import Foundation

/// Settings that no longer exist, cleaned out of `UserDefaults` at launch so a value someone
/// set years ago can't keep steering behaviour with no control left to change it.
enum RetiredSettings {
    /// Gone with no replacement: kiosk mode, the idle reset to page 1, the progress-sync and
    /// crash-report toggles (both always on now), motion blur, the reversed one-handed side.
    static let removedKeys = [
        "kioskModeEnabled",
        "readerIdleResetSeconds",
        "remoteProgressSyncEnabled",
        "crashReportingEnabled",
        "motionBlurEnabled",
        "oneHandedZonesReversed"
    ]

    static func clean(_ defaults: UserDefaults = .standard) {
        // "Modalità una mano" and "Avanza al tocco sui bordi" did the same thing: whoever had
        // the first one keeps the behaviour through the second.
        if defaults.bool(forKey: "oneHandedMode") {
            defaults.set(true, forKey: "tapToPanEnabled")
        }
        defaults.removeObject(forKey: "oneHandedMode")
        for key in removedKeys {
            defaults.removeObject(forKey: key)
        }
        #if !os(macOS)
        // The backup toggle is Mac-only now: iPhone/iPad go back to the default (excluded).
        defaults.removeObject(forKey: "includeInBackup")
        #endif
    }
}
