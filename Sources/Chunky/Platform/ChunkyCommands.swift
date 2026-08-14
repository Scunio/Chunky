#if os(macOS)
import SwiftUI

/// Voci di menu bar aggiunte da Chunky. Legge le azioni pubblicate da `LibraryView` tramite
/// `.focusedSceneValue`: se nessuna finestra libreria ha il focus (es. una finestra reader,
/// o le Preferenze), le voci restano presenti ma disabilitate — una menu bar che fa sparire
/// e ricomparire le proprie voci sarebbe più fastidiosa da leggere che una voce grigia.
struct ChunkyCommands: Commands {
    @FocusedValue(\.libraryActions) private var libraryActions: LibraryCommandActions?
    @FocusedValue(\.readerActions) private var readerActions: ReaderCommandActions?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Le Preferenze sono una `Window("Impostazioni", id: "settings")` invece della scena
        // `Settings` di sistema (vedi ChunkyApp.swift): serve ricreare a mano la voce di menu
        // e la scorciatoia ⌘, che `Settings` avrebbe aggiunto da sola.
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

            // Stesso effetto della freccia destra: nell'app originale la barra spaziatrice
            // avanzava di pagina esattamente come la freccia destra (vedi il vecchio
            // `KeyEventMonitor`, `case .rightArrow, .space`).
            Button("Pagina successiva (Spazio)") {
                readerActions?.nextPage()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(readerActions == nil)
            // Non serve nel menu, solo come scorciatoia: la freccia destra sopra basta a
            // renderla scopribile.
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
