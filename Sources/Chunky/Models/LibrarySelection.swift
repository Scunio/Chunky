import Foundation

/// What the main window is showing: the whole library, a cross-source view (favorites, now
/// reading), a single series, or a single source (the iCloud library or one remote account).
///
/// Lives outside the views because it's the state shared between the sidebar and the grid,
/// and it's what lets the grid stay in the main window instead of ending up inside the sidebar.
enum LibrarySelection: Hashable {
    case all
    case favorites
    /// Started and not finished, from every source: a NAS comic being read must be findable
    /// even when NAS comics are kept out of "Tutti" (see `LibrarySources.includeRemoteInAllKey`).
    case reading
    case group(String)
    /// `nil` = the iCloud library, otherwise the remote account with that id.
    case source(UUID?)

    var groupTitle: String? {
        if case .group(let title) = self { return title }
        return nil
    }
}
