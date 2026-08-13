import SwiftUI

/// Confine tra le due piattaforme per le presentazioni: le viste di contenuto restano
/// agnostiche, e chiedono qui "mostrami come si conviene" invece di ramificarsi da sole.
extension View {
    /// Un foglio senza dimensioni esplicite resta, su Mac, un modale piccolo e fisso — non
    /// il pannello a piena altezza che ci si aspetta. Su iOS non serve: il sistema decide già
    /// bene la dimensione dei fogli.
    ///
    /// 480pt di larghezza minima sembrava ragionevole per un form semplice (AddAccountView,
    /// ComicInfoSheet), ma `ToolsPanelView` e `SettingsView` sono un `NavigationView` a due
    /// colonne (sidebar + dettaglio) su Mac: a quella larghezza un'etichetta come "Colore
    /// evidenziazione" veniva tagliata dal bordo della colonna di dettaglio. Allargato per
    /// tutti i chiamanti — anche un form semplice più largo resta comunque leggibile, mentre
    /// il testo tagliato non lo è.
    func sheetSized() -> some View {
        #if os(macOS)
        self.frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 680)
        #else
        self
        #endif
    }
}

extension View {
    /// Sfondo della schermata di blocco genitori, condiviso da tutte le finestre in cui
    /// compare (libreria, reader, Preferenze su Mac). Deve restare OPACO: un materiale
    /// traslucido lascerebbe intravedere il contenuto che dovrebbe nascondere. Centralizzato
    /// qui perché prima era ripetuto identico in tre punti — facile aggiornarne due su tre e
    /// lasciarne uno traslucido per sbaglio.
    func lockScreenBackground() -> some View {
        self.background(.background, ignoresSafeAreaEdges: .all)
    }
}
