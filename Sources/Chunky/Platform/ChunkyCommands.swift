#if os(macOS)
import SwiftUI

/// Menu bar items added by Chunky. Reads the actions published by `LibraryView` via
/// `.focusedSceneValue`: if no library window has focus (e.g. a reader window,
/// or Preferences), the items stay present but disabled — a menu bar whose items keep
/// appearing and disappearing would be more annoying to read than a grayed-out item.
struct ChunkyCommands: Commands {
    @FocusedValue(\.libraryActions) private var libraryActions: LibraryCommandActions?
    @FocusedValue(\.readerActions) private var readerActions: ReaderCommandActions?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Preferences is a `Window("Impostazioni", id: "settings")` instead of the system
        // `Settings` scene (see ChunkyApp.swift): the menu item and the ⌘, shortcut,
        // which `Settings` would have added on its own, need to be recreated by hand.
        CommandGroup(replacing: .appSettings) {
            Button("Impostazioni…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Vai") {
            Button("Pagina precedente") {
                readerActions?.previousPage()
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(readerActions == nil)

            Button("Pagina successiva") {
                readerActions?.nextPage()
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(readerActions == nil)

            // Same effect as the right arrow: the space bar must advance a page
            // just like the right arrow.
            Button("Pagina successiva (Spazio)") {
                readerActions?.nextPage()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(readerActions == nil)
            // Not needed in the menu, only as a shortcut: the right arrow above is enough
            // to make it discoverable.
            .accessibilityHidden(true)
        }

        CommandGroup(after: .newItem) {
            Button("Importa fumetti…") {
                libraryActions?.importFiles()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(libraryActions == nil)

            Button("Nuovo gruppo…") {
                libraryActions?.newGroup()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(libraryActions == nil)
        }

        CommandMenu("Libreria") {
            Toggle("Raggruppa per serie", isOn: libraryActions?.isGroupedBySeries ?? .constant(true))
                .disabled(libraryActions == nil)

            Divider()

            Button("Griglia") {
                libraryActions?.isTableLayout.wrappedValue = false
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(libraryActions == nil)

            Button("Lista") {
                libraryActions?.isTableLayout.wrappedValue = true
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(libraryActions == nil)
        }
    }
}
#endif
