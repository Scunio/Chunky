import Foundation

/// Aritmetica di paginazione del reader: quali pagine formano ogni spread, come riallinearsi
/// quando cambia il passo (1 o 2 pagine), e come si muove `currentPage` con LTR/RTL.
///
/// Pura e senza SwiftUI apposta: è la parte del reader più delicata da toccare (l'inversione
/// di direzione nei manga in particolare) e la meno verificabile finché vive dentro
/// `ReaderView`.
struct ReaderPagination: Sendable, Equatable {
    let pageCount: Int
    let pageStep: Int
    let isRightToLeft: Bool
    /// Se vera, la prima pagina (la copertina) è sempre uno spread a sé — anche quando
    /// `pageStep == 2` — e l'accoppiamento a due pagine riprende dalla seconda. Senza questo,
    /// la copertina finiva appaiata alla pagina 2 come qualunque altro spread.
    var coverIsAlone: Bool = false

    enum StepOutcome: Equatable {
        case page(Int)
        /// Il passo supererebbe l'ultima pagina. `triggersNextComic` è vero quando ci si
        /// sta muovendo in avanti nella direzione di lettura — nei manga questo può
        /// corrispondere a un `direction` negativo, da cui la distinzione da `direction`.
        case endReached(triggersNextComic: Bool)
        /// Il passo andrebbe prima della prima pagina: nessuna azione.
        case beginningReached
    }

    /// Indici di inizio di ogni spread. Con `pageStep == 1` è ogni pagina. Con `pageStep == 2`
    /// sono coppie, tranne la prima se `coverIsAlone` — in quel caso la copertina è da sola e
    /// l'accoppiamento riprende dalla pagina successiva (spread di larghezza non uniforme,
    /// per questo `step(from:direction:)` cammina per indice di spread e non per aritmetica
    /// a passo fisso).
    var spreadStarts: [Int] {
        guard pageCount > 0, pageStep > 0 else { return [0] }
        guard pageStep > 1, coverIsAlone else {
            return Array(stride(from: 0, to: pageCount, by: pageStep))
        }
        guard pageCount > 1 else { return [0] }
        return [0] + Array(stride(from: 1, to: pageCount, by: pageStep))
    }

    /// Riallinea una pagina a un inizio-spread valido. Serve quando cambia il passo (es. da
    /// pagina dispari a passo 2): l'indice corrente potrebbe non essere più un inizio-spread,
    /// e senza riallineamento il tag della pagina non troverebbe corrispondenza.
    func realigned(_ current: Int) -> Int {
        spreadStarts.last(where: { $0 <= current }) ?? 0
    }

    /// Indice dello spread che contiene `page`, per lo slider e il jump-to-page.
    func spreadIndex(containing page: Int) -> Int {
        let starts = spreadStarts
        return starts.lastIndex(where: { $0 <= page }) ?? 0
    }

    /// Un passo di lettura. `direction` è la direzione dell'input (destra=avanti,
    /// sinistra=indietro): con lettura RTL viene invertita internamente, così il chiamante
    /// non deve mai ragionare sulla direzione di lettura.
    ///
    /// Cammina per indice di spread (non per aritmetica su `pageStep`) perché con
    /// `coverIsAlone` gli spread non hanno tutti la stessa larghezza: un salto di `pageStep`
    /// posizioni non individuerebbe più in modo affidabile lo spread successivo/precedente.
    func step(from current: Int, direction: Int) -> StepOutcome {
        let starts = spreadStarts
        guard let currentSpreadIndex = starts.lastIndex(where: { $0 <= current }) else {
            return .beginningReached
        }
        let effectiveDirection = isRightToLeft ? -direction : direction
        let targetSpreadIndex = currentSpreadIndex + effectiveDirection
        if targetSpreadIndex >= starts.count {
            return .endReached(triggersNextComic: effectiveDirection > 0)
        }
        guard targetSpreadIndex >= 0 else { return .beginningReached }
        return .page(starts[targetSpreadIndex])
    }
}
