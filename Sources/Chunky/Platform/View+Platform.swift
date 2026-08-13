import SwiftUI

/// Confine tra le due piattaforme per le presentazioni: le viste di contenuto restano
/// agnostiche, e chiedono qui "mostrami come si conviene" invece di ramificarsi da sole.
extension View {
    /// Un foglio senza dimensioni esplicite resta, su Mac, un modale piccolo e fisso — non
    /// il pannello a piena altezza che ci si aspetta. Su iOS non serve: il sistema decide già
    /// bene la dimensione dei fogli.
    func sheetSized() -> some View {
        #if os(macOS)
        self.frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 620)
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
