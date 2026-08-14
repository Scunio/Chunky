import SwiftUI
#if os(iOS)
import UIKit

extension UIScreen {
    /// `UIScreen.main` è deprecato in un mondo multi-scena: la luminosità va letta/scritta
    /// sullo schermo della scena attiva, non su un main screen implicito.
    static var current: UIScreen? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
    }
}
#endif

/// Confine tra le due piattaforme per le presentazioni: le viste di contenuto restano
/// agnostiche, e chiedono qui "mostrami come si conviene" invece di ramificarsi da sole.
extension View {
    /// Un foglio senza dimensioni esplicite resta, su Mac, un modale piccolo e fisso — non
    /// il pannello a piena altezza che ci si aspetta. Su iOS non serve: il sistema decide già
    /// bene la dimensione dei fogli.
    ///
    /// La larghezza minima è quella che serve a `ToolsPanelView`/`SettingsView` perché
    /// un'etichetta come "Colore evidenziazione" non venga tagliata — anche per i form più
    /// semplici (AddAccountView, ComicInfoSheet), che restano comunque leggibili più larghi.
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
    /// traslucido lascerebbe intravedere il contenuto che dovrebbe nascondere.
    func lockScreenBackground() -> some View {
        self.background(.background, ignoresSafeAreaEdges: .all)
    }
}
