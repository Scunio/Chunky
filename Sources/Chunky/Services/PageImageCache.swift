import CoreGraphics
import Foundation

/// Cache di immagini pagina già elaborate (ritaglio, upscaling, tint), con prefetch attorno
/// a un indice.
///
/// Esiste per risolvere un problema specifico del pager macOS: senza cache, ogni cambio di
/// pagina ricrea la view e ridecodifica da disco (spinner a ogni pagina), perché
/// `provider.image(atPage:)` non ha memoria propria — ogni chiamata ri-estrae e ridecodifica.
/// Con la cache, il prefetch attorno alla pagina corrente arriva quasi sempre prima che
/// l'utente giri pagina, quindi la richiesta successiva trova il risultato già pronto.
///
/// `PlatformImage` (`UIImage`/`NSImage`) non è `Sendable`; l'attraversamento del confine
/// dell'actor è comunque sicuro perché non c'è mutazione condivisa (ogni immagine viene creata
/// una volta e mai più modificata), ma il compilatore non può saperlo da solo.
actor PageImageCache {
    struct ProcessingOptions: Equatable {
        var autoCrop: Bool
        var autoTintContrast: Bool
        var upscaleTargetSize: CGSize?

        static func == (lhs: ProcessingOptions, rhs: ProcessingOptions) -> Bool {
            lhs.autoCrop == rhs.autoCrop
                && lhs.autoTintContrast == rhs.autoTintContrast
                && lhs.upscaleTargetSize == rhs.upscaleTargetSize
        }
    }

    private struct Entry {
        let image: PlatformImage
        let options: ProcessingOptions
    }

    private let provider: ComicPageProvider
    private var entries: [Int: Entry] = [:]
    private var accessOrder: [Int] = []
    private let capacity: Int

    init(provider: ComicPageProvider, capacity: Int = 8) {
        self.provider = provider
        self.capacity = capacity
    }

    /// Le opzioni fanno parte della chiave, non solo l'indice: `prefetchAroundCurrentPage` e
    /// `PageView.loadImage` calcolano `upscaleTargetSize` da due dimensioni diverse (l'intero
    /// viewport contro il riquadro della singola pagina, che in doppia pagina è circa la metà).
    /// Senza questo confronto, un hit di cache poteva restituire un'immagine elaborata per una
    /// dimensione diversa da quella richiesta — sbagliata, non solo non aggiornata.
    func image(at index: Int, options: ProcessingOptions) -> PlatformImage? {
        if let cached = entries[index], cached.options == options {
            touch(index)
            return cached.image
        }
        guard let processed = process(index: index, options: options) else { return nil }
        store(index: index, image: processed, options: options)
        return processed
    }

    /// Elabora in anticipo le pagine entro `radius` da `index`, saltando quelle già in cache
    /// con le stesse opzioni.
    func prefetch(around index: Int, radius: Int, pageCount: Int, options: ProcessingOptions) async {
        guard pageCount > 0 else { return }
        let lower = max(0, index - radius)
        let upper = min(pageCount - 1, index + radius)
        guard lower <= upper else { return }
        for candidate in lower...upper {
            // `.task(id: currentPage)` in ReaderView cancella il batch precedente a ogni
            // cambio pagina, ma un attore non interrompe da sé una chiamata già in corso:
            // senza questo controllo, sfogliare rapidamente accoda più batch da 5 pagine
            // ciascuno per posizioni già superate, che finiscono comunque per essere
            // elaborati prima della richiesta `image(at:)` della pagina su cui si è arrivati.
            guard !Task.isCancelled else { return }
            if let existing = entries[candidate], existing.options == options { continue }
            guard let processed = process(index: candidate, options: options) else { continue }
            store(index: candidate, image: processed, options: options)
            // Un attore serializza le chiamate: senza cedere il turno qui, un prefetch da 5
            // pagine terrebbe in coda la richiesta `image(at:)` della pagina su cui l'utente
            // è appena arrivato per tutta la durata del batch, invece dei pochi millisecondi
            // di una singola pagina già pronta.
            await Task.yield()
        }
    }

    /// Da chiamare quando cambiano le impostazioni di elaborazione (ritaglio, tint, upscaling):
    /// le voci in cache sono state processate con le opzioni precedenti.
    func purge() {
        entries.removeAll()
        accessOrder.removeAll()
    }

    /// Da chiamare prima di ritentare una pagina la cui lettura è fallita: non toglie nulla se
    /// non c'è nulla in cache (un fallimento non arriva mai a `store`), ma un secondo tentativo
    /// dopo un fallimento parziale — es. l'archivio era temporaneamente irraggiungibile da
    /// iCloud — non deve trovare un'eventuale voce stantia e restituirla senza riprovare.
    func invalidate(_ index: Int) {
        entries.removeValue(forKey: index)
        accessOrder.removeAll { $0 == index }
    }

    private func process(index: Int, options: ProcessingOptions) -> PlatformImage? {
        guard var loaded = try? provider.image(atPage: index) else { return nil }
        if options.autoCrop {
            loaded = ImageProcessing.autoCropWhiteBorders(loaded)
        }
        if options.autoTintContrast {
            loaded = ImageProcessing.autoTintAndContrast(loaded)
        }
        if let targetSize = options.upscaleTargetSize {
            loaded = ImageProcessing.upscaleIfNeeded(loaded, targetSize: targetSize)
        }
        return loaded
    }

    private func store(index: Int, image: PlatformImage, options: ProcessingOptions) {
        entries[index] = Entry(image: image, options: options)
        touch(index)
        while entries.count > capacity, let oldest = accessOrder.first {
            entries.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }

    private func touch(_ index: Int) {
        accessOrder.removeAll { $0 == index }
        accessOrder.append(index)
    }
}
