import SwiftUI

/// Azioni che la libreria espone alla menu bar del Mac tramite `.focusedSceneValue`.
///
/// Il resto della vista non sa che una menu bar esiste: qui si limita a pubblicare ciò che
/// già fa in risposta al tocco di un pulsante, e la menu bar (in `Platform/ChunkyCommands.swift`)
/// li richiama con lo stesso effetto. Le voci reader (pagina successiva/precedente) hanno lo
/// stesso trattamento, ma pubblicate a parte da `ReaderCommandActions` qui sotto: preferito e
/// info restano invece raggiungibili solo dall'interfaccia del reader, non dalla menu bar.
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

/// Cambio pagina pubblicato dalla finestra reader attiva. `.commands` instrada attraverso il
/// normale meccanismo delle scorciatoie di menu: se un campo di testo ha il focus, è lui a
/// ricevere Spazio/frecce per primo, non il comando.
struct ReaderCommandActions {
    var previousPage: () -> Void
    var nextPage: () -> Void
}

private struct ReaderCommandActionsKey: FocusedValueKey {
    typealias Value = ReaderCommandActions
}
