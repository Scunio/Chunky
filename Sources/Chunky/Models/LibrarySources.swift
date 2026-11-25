import Foundation

/// Source-aware filtering and folder grouping for the library.
///
/// The library mixes two kinds of comics: the iCloud library (`sourceAccountID == nil`, the
/// base, synced everywhere) and those of remote accounts (NAS/WebDAV/OPDS — local to the device
/// that scanned them). Importing a 300-comic NAS folder shouldn't bury the iCloud library, so
/// "Tutti" leaves remote comics out unless the user asks for them, and each account gets its own
/// page grouped by its server folders. Pure logic, so it's testable; the views only call it.
enum LibrarySources {
    /// Whether "Tutti i fumetti" also lists remote-account comics. Off by default.
    static let includeRemoteInAllKey = "libraryIncludesRemoteInAll"
    /// Whether an account page groups by server folder (on) or by series (off).
    static let groupRemoteByFolderKey = "libraryGroupsRemoteByFolder"

    static func isReading(_ comic: ComicEntity) -> Bool {
        comic.lastReadPage > 0 && !comic.isFinished
    }

    /// The comics a selection shows (before the "downloaded only" and search filters).
    static func filter(_ comics: [ComicEntity], selection: LibrarySelection, includeRemoteInAll: Bool) -> [ComicEntity] {
        switch selection {
        case .all:
            return includeRemoteInAll ? comics : comics.filter { $0.sourceAccountID == nil }
        case .favorites:
            return comics.filter(\.isFavorite)
        case .reading:
            return comics.filter(isReading)
        case .group(let title):
            let pool = includeRemoteInAll ? comics : comics.filter { $0.sourceAccountID == nil }
            return pool.filter { ($0.seriesName ?? LibraryGrouping.ungroupedTitle) == title }
        case .source(let accountID):
            return comics.filter { $0.sourceAccountID == accountID }
        }
    }

    /// Folder of a remote comic relative to its account root, decoded and without the file name:
    /// "Fumetti › Topolino" for `smb://nas/share/Fumetti/Topolino/3618.cbr` with root
    /// `smb://nas/share`. Empty for a file directly in the root; nil when the comic's URL isn't
    /// under the root (account edited since the scan).
    static func remoteFolder(sourceAbsoluteString: String, rootAbsoluteString: String) -> String? {
        guard let serverPath = RemoteProgressSyncKey.serverPath(
            rootAbsoluteString: rootAbsoluteString, sourceAbsoluteString: sourceAbsoluteString
        ) else { return nil }
        let components = serverPath.split(separator: "/").dropLast().map { component in
            String(component).removingPercentEncoding ?? String(component)
        }
        return components.joined(separator: " › ")
    }

    /// Title of the section for files directly in the account root.
    static var rootFolderTitle: String {
        AppLocalization.localizedString("Cartella principale", comment: "Library section: files at the root of a remote account")
    }

    /// An account page grouped by server folder: folders sorted like Finder, the root first,
    /// comics by title inside each. Comics whose folder can't be derived go with the root.
    static func folderSections(for comics: [ComicEntity], rootAbsoluteString: String) -> [LibraryGrouping.Section] {
        let rootTitle = rootFolderTitle
        let groups = Dictionary(grouping: comics) { comic -> String in
            guard let source = comic.sourceRelativePath,
                  let folder = remoteFolder(sourceAbsoluteString: source, rootAbsoluteString: rootAbsoluteString),
                  !folder.isEmpty
            else { return rootTitle }
            return folder
        }
        return groups.keys.sorted { lhs, rhs in
            if lhs == rootTitle { return true }
            if rhs == rootTitle { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { key in
            LibraryGrouping.Section(
                title: key,
                comics: (groups[key] ?? []).sorted { ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending }
            )
        }
    }
}
