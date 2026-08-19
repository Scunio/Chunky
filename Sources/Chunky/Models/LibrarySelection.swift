import Foundation

/// What the main window is showing: the whole library or a single series.
///
/// Lives outside the views because it's the state shared between the Mac sidebar and the
/// grid, and it's what lets the grid stay in the main window instead of
/// ending up inside the sidebar.
enum LibrarySelection: Hashable {
    case all
    case favorites
    case group(String)

    var groupTitle: String? {
        if case .group(let title) = self { return title }
        return nil
    }
}
