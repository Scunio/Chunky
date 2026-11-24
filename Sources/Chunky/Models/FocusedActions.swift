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
///
/// Published only while no text field or overlay of the reader is up (search, page jump,
/// sheets…): a disabled menu item doesn't claim its key equivalent, so the bare
/// Left/Right/Space shortcuts below reach the text field instead of turning the page.
struct ReaderCommandActions {
    /// Left/Right arrows: *visual* direction (in manga the left arrow advances).
    var previousPage: () -> Void
    var nextPage: () -> Void
    #if os(macOS)
    /// Space/Page Down/Page Up: always *reading* order, whatever the reading direction.
    var forwardInReadingOrder: () -> Void = {}
    var firstPage: () -> Void = {}
    var lastPage: () -> Void = {}
    var find: () -> Void = {}
    var goToPage: () -> Void = {}
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var actualSize: () -> Void = {}
    #endif
}

#if os(macOS)
/// Keyboard/menu zoom request for the reader's visible page(s) (⌘+ / ⌘− / ⌘0). A fresh `id`
/// per request so repeating the same command is still a change `PageView` observes.
struct ReaderZoomCommand: Equatable {
    enum Kind { case zoomIn, zoomOut, reset }
    let id: Int
    let kind: Kind
}

private struct ReaderZoomCommandKey: EnvironmentKey {
    static let defaultValue: ReaderZoomCommand? = nil
}

extension EnvironmentValues {
    var readerZoomCommand: ReaderZoomCommand? {
        get { self[ReaderZoomCommandKey.self] }
        set { self[ReaderZoomCommandKey.self] = newValue }
    }
}
#endif

private struct ReaderCommandActionsKey: FocusedValueKey {
    typealias Value = ReaderCommandActions
}
