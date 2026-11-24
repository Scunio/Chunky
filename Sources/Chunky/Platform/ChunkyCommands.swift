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

        // On the Mac the Tools panel's wrench opens Settings directly (see `openTools`), so
        // its one extra entry — feedback — lives in the Help menu, where Mac users look.
        CommandGroup(after: .help) {
            Button("Feedback / Segnala un problema") {
                ToolsPanelView.sendFeedbackEmail()
            }
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

            // Space advances in *reading* order (in manga that's the left page, not the right
            // arrow's direction), like Page Down below.
            Button("Pagina successiva (Spazio)") {
                readerActions?.forwardInReadingOrder()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(readerActions == nil)
            // Not needed in the menu, only as a shortcut: the right arrow above is enough
            // to make it discoverable.
            .accessibilityHidden(true)

            Divider()

            Button("Prima pagina") {
                readerActions?.firstPage()
            }
            .keyboardShortcut(.home, modifiers: [])
            .disabled(readerActions == nil)

            Button("Ultima pagina") {
                readerActions?.lastPage()
            }
            .keyboardShortcut(.end, modifiers: [])
            .disabled(readerActions == nil)

            Button("Vai a pagina...") {
                readerActions?.goToPage()
            }
            .keyboardShortcut("g", modifiers: [.command, .option])
            .disabled(readerActions == nil)

            Divider()

            Button("Cerca nel fumetto") {
                readerActions?.find()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(readerActions == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Ingrandisci") {
                readerActions?.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(readerActions == nil)

            Button("Riduci") {
                readerActions?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(readerActions == nil)

            Button("Dimensioni reali") {
                readerActions?.actualSize()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(readerActions == nil)
        }

        // `replacing`, not `after`: this drops the system "New Window" (⌘N). Every extra
        // library window ran its own ContentView — its own 3-minute rescan, remote-account
        // scan and progress-sync loops — against the same store. Closing the library window
        // and clicking the Dock icon still brings one back.
        CommandGroup(replacing: .newItem) {
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
