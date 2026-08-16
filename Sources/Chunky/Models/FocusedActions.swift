import SwiftUI

/// Actions the library exposes to the Mac menu bar via `.focusedSceneValue`.
///
/// The rest of the view doesn't know a menu bar exists: it just publishes what it
/// already does in response to a button tap, and the menu bar (in `Platform/ChunkyCommands.swift`)
/// invokes them with the same effect. The reader items (next/previous page) get the
/// same treatment, but published separately by `ReaderCommandActions` below: favorite and
/// info, on the other hand, remain reachable only from the reader's own interface, not from the menu bar.
struct LibraryCommandActions {
    var importFiles: () -> Void
    var newGroup: () -> Void
    var isGroupedBySeries: Binding<Bool>
    var isTableLayout: Binding<Bool>
}

private struct LibraryCommandActionsKey: FocusedValueKey {
    typealias Value = LibraryCommandActions
}

extension FocusedValues {
    var libraryActions: LibraryCommandActions? {
        get { self[LibraryCommandActionsKey.self] }
        set { self[LibraryCommandActionsKey.self] = newValue }
    }

    var readerActions: ReaderCommandActions? {
        get { self[ReaderCommandActionsKey.self] }
        set { self[ReaderCommandActionsKey.self] = newValue }
    }
}

/// Page change published by the active reader window. `.commands` routes through the
/// normal menu shortcut mechanism: if a text field has focus, it receives Space/arrows
/// first, not the command.
struct ReaderCommandActions {
    var previousPage: () -> Void
    var nextPage: () -> Void
}

private struct ReaderCommandActionsKey: FocusedValueKey {
    typealias Value = ReaderCommandActions
}
