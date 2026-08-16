import Foundation

/// Scarica da iCloud un fumetto che sul dispositivo è ancora solo un segnaposto, registrandolo
/// in `DownloadManager` così da comparire nella schermata Downloads con progresso reale e
/// possibilità di annullarlo.
///
/// Esiste come punto unico perché il download parte da due strade diverse — l'apertura nel
/// lettore e il comando esplicito nel menu contestuale della libreria — e devono agganciarsi
/// allo stesso trasferimento invece di aprirne due: la deduplica di `DownloadManager` è per
/// chiave, e la chiave (il percorso del file) va scelta allo stesso modo da entrambe.
enum ComicDownloadService {
    /// Va chiamata dalla coda principale (`DownloadManager` è osservato dall'interfaccia).
    /// Restituisce l'item registrato, che il chiamante può usare per annullare; `nil` se il file
    /// era già in locale e non c'era niente da scaricare.
    ///
    /// `onProgress` (0...1) e `completion` arrivano sulla coda principale. `completion` riceve
    /// `nil` se il fumetto è ora leggibile, altrimenti l'errore — compreso l'annullamento.
    @discardableResult
    static func downloadIfNeeded(
        title: String,
        at url: URL,
        onProgress: ((Double) -> Void)? = nil,
        completion: ((Error?) -> Void)? = nil
    ) -> DownloadItem? {
        // Nessun `onProgress` qui: un file già in locale non ha mai avuto un download, e
        // pubblicare un avanzamento del 100% farebbe lampeggiare per un istante l'overlay di
        // download del lettore su un fumetto che si apre subito.
        guard LibraryStorage.isPendingDownload(url) else {
            completion?(nil)
            return nil
        }

        // La chiave è il percorso del file: riaprire lo stesso fumetto mentre scarica si aggancia
        // al download già in corso invece di aprirne un secondo.
        let item = DownloadManager.shared.register(title: title, key: url.path)
        onProgress?(item.fractionCompleted)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try LibraryStorage.downloadIfNeeded(url, isCancelled: { item.isCancelled }) { progress in
                    // Questo `onProgress` arriva dalla coda principale durante il download ma da
                    // quella di background nel caso "già scaricato": non si può toccare
                    // l'interfaccia senza rimbalzare esplicitamente sul main.
                    DispatchQueue.main.async {
                        item.updateProgress(progress)
                        onProgress?(progress)
                    }
                }
                finish(item, error: nil, completion: completion)
            } catch {
                finish(item, error: error, completion: completion)
            }
        }
        return item
    }

    /// Comodità per i chiamanti che hanno il record di libreria sottomano.
    @discardableResult
    static func downloadIfNeeded(
        comic: ComicEntity,
        onProgress: ((Double) -> Void)? = nil,
        completion: ((Error?) -> Void)? = nil
    ) -> DownloadItem? {
        let url = LibraryStorage.fileURL(forRelativePath: comic.relativePath ?? "")
        return downloadIfNeeded(
            title: comic.title ?? "Fumetto",
            at: url,
            onProgress: onProgress,
            completion: completion
        )
    }

    /// La riga va tolta da `DownloadManager` in ogni esito, riuscita o fallimento: lasciarla
    /// significherebbe una voce ferma in Downloads e, peggio, un item già annullato in cache che
    /// farebbe fallire subito il tentativo successivo sullo stesso fumetto.
    private static func finish(_ item: DownloadItem, error: Error?, completion: ((Error?) -> Void)?) {
        DispatchQueue.main.async {
            DownloadManager.shared.remove(item)
            completion?(error)
        }
    }
}
