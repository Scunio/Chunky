import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

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
        /// Byte occupati dal bitmap decodificato, misurati una volta sola qui: su macOS
        /// `cgImageRepresentation` rirenderizza a ogni accesso, quindi non va chiamato in
        /// continuazione.
        let cost: Int
    }

    private let provider: ComicPageProvider
    private var entries: [Int: Entry] = [:]
    private var accessOrder: [Int] = []
    /// Tetto in byte, non in numero di pagine: una pagina decodificata occupa
    /// larghezza × altezza × 4, quindi 8 pagine sono ~100 MB su iPhone e più del doppio su un
    /// iPad Pro. Contarle non dice niente sulla memoria davvero impegnata.
    private let costLimit: Int
    /// Sotto questa soglia non si sfratta comunque: con pagine enormi il tetto in byte
    /// ridurrebbe la cache a una voce sola, facendola rileggere in continuazione.
    private let minimumEntries: Int
    /// Limite di sicurezza sul numero di voci, per non far crescere il dizionario senza freno
    /// quando le pagine sono piccolissime.
    private let maximumEntries: Int
    private var totalCost = 0
    private var memoryWarningObserver: (any NSObjectProtocol)?

    /// Registrato alla prima richiesta e non nell'init: `init` non è isolato sull'attore, quindi
    /// non può toccare le sue proprietà (in Swift 6 è un errore). Qui siamo già dentro l'attore.
    private func startObservingMemoryWarningsIfNeeded() {
        #if canImport(UIKit)
        guard memoryWarningObserver == nil else { return }
        // Il tetto in byte è una stima: se il sistema chiede memoria si molla tutto tranne la
        // pagina in uso, invece di aspettare che sia iOS a chiudere l'app.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.dropAllButMostRecent() }
        }
        #endif
    }

    init(
        provider: ComicPageProvider,
        costLimit: Int = PageImageCache.defaultCostLimit(),
        minimumEntries: Int = 3,
        maximumEntries: Int = 64
    ) {
        self.provider = provider
        self.costLimit = costLimit
        self.minimumEntries = minimumEntries
        self.maximumEntries = maximumEntries
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// Una frazione prudente della RAM del dispositivo. Non è la memoria *disponibile*: iOS
    /// termina le app molto prima di esaurirla, quindi la frazione è bassa e con un tetto fisso
    /// sopra, per non arrivare a impegnare centinaia di MB su un iPad solo perché ne ha tanta.
    static func defaultCostLimit() -> Int {
        let physical = ProcessInfo.processInfo.physicalMemory
        let share = Int(min(physical / 24, UInt64(Int.max)))
        return min(max(share, 64 * 1024 * 1024), 192 * 1024 * 1024)
    }

    /// Le opzioni fanno parte della chiave, non solo l'indice: `prefetchAroundCurrentPage` e
    /// `PageView.loadImage` calcolano `upscaleTargetSize` da due dimensioni diverse (l'intero
    /// viewport contro il riquadro della singola pagina, che in doppia pagina è circa la metà).
    /// Senza questo confronto, un hit di cache poteva restituire un'immagine elaborata per una
    /// dimensione diversa da quella richiesta — sbagliata, non solo non aggiornata.
    func image(at index: Int, options: ProcessingOptions) -> PlatformImage? {
        startObservingMemoryWarningsIfNeeded()
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
        startObservingMemoryWarningsIfNeeded()
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
        totalCost = 0
    }

    /// Risposta a un avviso di memoria: si tiene solo la pagina usata più di recente, che è
    /// quella a schermo, e si lascia che il prefetch ricostruisca il resto.
    func dropAllButMostRecent(_ keep: Int = 1) {
        guard accessOrder.count > keep else { return }
        for index in accessOrder.dropLast(keep) {
            if let removed = entries.removeValue(forKey: index) { totalCost -= removed.cost }
        }
        accessOrder = Array(accessOrder.suffix(keep))
    }

    /// Da chiamare prima di ritentare una pagina la cui lettura è fallita: non toglie nulla se
    /// non c'è nulla in cache (un fallimento non arriva mai a `store`), ma un secondo tentativo
    /// dopo un fallimento parziale — es. l'archivio era temporaneamente irraggiungibile da
    /// iCloud — non deve trovare un'eventuale voce stantia e restituirla senza riprovare.
    func invalidate(_ index: Int) {
        if let removed = entries.removeValue(forKey: index) { totalCost -= removed.cost }
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
        if let previous = entries[index] { totalCost -= previous.cost }
        let cost = Self.cost(of: image)
        entries[index] = Entry(image: image, options: options, cost: cost)
        totalCost += cost
        touch(index)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while totalCost > costLimit || entries.count > maximumEntries {
            guard entries.count > minimumEntries, let oldest = accessOrder.first else { return }
            if let removed = entries.removeValue(forKey: oldest) { totalCost -= removed.cost }
            accessOrder.removeFirst()
        }
    }

    /// `bytesPerRow * height` e non `width * height * 4`: è l'allocazione vera, allineamento
    /// di riga compreso. Se il bitmap non è raggiungibile si assume una pagina grande, così
    /// una stima sbagliata pecca per prudenza invece che gonfiare la cache.
    private static func cost(of image: PlatformImage) -> Int {
        guard let bitmap = image.cgImageRepresentation else { return 16 * 1024 * 1024 }
        return max(bitmap.bytesPerRow * bitmap.height, 1)
    }

    private func touch(_ index: Int) {
        accessOrder.removeAll { $0 == index }
        accessOrder.append(index)
    }
}
