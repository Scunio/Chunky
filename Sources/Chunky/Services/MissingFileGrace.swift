import Foundation

/// Grace period before the library drops a comic whose file is missing both locally and in
/// iCloud Drive.
///
/// Library records sync across devices through CloudKit, often well before iCloud Drive has
/// delivered the file itself (large CBZ/CBR). A comic just imported on the iPhone can therefore
/// look "gone everywhere" on the Mac for a while: deleting it then would propagate the deletion
/// back to the iPhone, which re-adds it from its file with the progress reset. So a missing comic
/// is only deleted once it's not a recent import *and* it has stayed missing for a while.
///
/// The "missing since" dates are per device (UserDefaults, never synced): each device judges only
/// what it can see itself.
struct MissingFileGrace {
    /// Comics added more recently than this are never deleted for a missing file.
    static let recentImportWindow: TimeInterval = 24 * 60 * 60
    /// How long a comic must stay missing before an automatic pass deletes it.
    static let missingWindow: TimeInterval = 30 * 60
    static let defaultsKey = "libraryMissingFileSince"

    private(set) var missingSince: [String: Date]

    init(missingSince: [String: Date] = [:]) {
        self.missingSince = missingSince
    }

    static func load(from defaults: UserDefaults) -> MissingFileGrace {
        let raw = defaults.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        return MissingFileGrace(missingSince: raw.mapValues { Date(timeIntervalSince1970: $0) })
    }

    func save(to defaults: UserDefaults) {
        if missingSince.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(missingSince.mapValues(\.timeIntervalSince1970), forKey: Self.defaultsKey)
        }
    }

    /// Records `key` as missing (from its first sighting) and says whether it may be deleted now.
    /// `bypassMissingWindow` is for the user-initiated rebuild: it skips the wait, but a recent
    /// import stays protected because that's exactly the cross-device race described above.
    mutating func shouldDelete(key: String, dateAdded: Date?, now: Date, bypassMissingWindow: Bool) -> Bool {
        let since = missingSince[key] ?? now
        if missingSince[key] == nil { missingSince[key] = now }
        if let dateAdded, now.timeIntervalSince(dateAdded) < Self.recentImportWindow {
            return false
        }
        guard bypassMissingWindow || now.timeIntervalSince(since) >= Self.missingWindow else {
            return false
        }
        missingSince[key] = nil
        return true
    }

    /// Forgets every entry not in `keys` (comics that reappeared or no longer exist).
    mutating func prune(keeping keys: Set<String>) {
        missingSince = missingSince.filter { keys.contains($0.key) }
    }
}
