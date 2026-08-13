import Foundation

/// Cosa la finestra principale sta mostrando: tutta la libreria o una singola serie.
///
/// Vive fuori dalle viste perché è lo stato condiviso tra la sidebar del Mac e la griglia,
/// ed è ciò che permette alla griglia di restare nella finestra principale invece di
/// finire dentro la sidebar.
enum LibrarySelection: Hashable {
    case all
    case group(String)

    var groupTitle: String? {
        if case .group(let title) = self { return title }
        return nil
    }
}
