import CoreGraphics

/// Se una spread a doppia pagina ha senso nello spazio disponibile.
///
/// Due pagine verticali affiancate in una finestra stretta lasciano un vuoto enorme sopra e
/// sotto (l'immagine combinata è troppo larga rispetto all'altezza disponibile): la doppia
/// pagina ha senso solo con più spazio orizzontale che verticale.
enum DoublePagePolicy {
    /// - Parameters:
    ///   - viewportSize: dimensione misurata dell'area di lettura. `.zero` finché non è
    ///     ancora stata misurata (primo layout) — in quel caso si assume di sì, per non
    ///     negare la doppia pagina solo perché il layout non è ancora avvenuto.
    ///   - isCompactWidth: `true` su iPhone in verticale (size class compatta): lì la doppia
    ///     pagina non ha mai senso indipendentemente dalle proporzioni misurate. Su iPad e
    ///     su Mac, dove non esiste una size class compatta, si passa `false` e la decisione
    ///     dipende solo dalle proporzioni.
    static func isAllowed(viewportSize: CGSize, isCompactWidth: Bool) -> Bool {
        guard !isCompactWidth else { return false }
        guard viewportSize.width > 0, viewportSize.height > 0 else { return true }
        return viewportSize.width > viewportSize.height
    }
}
