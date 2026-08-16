import Foundation
import CoreData
import Combine

final class LibraryViewModel: ObservableObject {
    @Published var isImporting = false
    @Published var importError: String?

    func importFiles(_ urls: [URL], into context: NSManagedObjectContext) {
        isImporting = true
        let backgroundContext = makeBackgroundContext(from: context)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for url in urls {
                self?.importSingleFile(url, into: backgroundContext)
            }
            DispatchQueue.main.async {
                self?.isImporting = false
            }
        }
    }

    private func makeBackgroundContext(from context: NSManagedObjectContext) -> NSManagedObjectContext {
        context.persistentStoreCoordinator.map { coordinator -> NSManagedObjectContext in
            let bg = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            bg.persistentStoreCoordinator = coordinator
            bg.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            return bg
        } ?? context
    }

    /// Copia `url` nella cartella della libreria, poi la registra. Usato per file esterni
    /// (picker di sistema, download da account remoto, "apri con").
    private func importSingleFile(_ url: URL, into context: NSManagedObjectContext) {
        let ext = url.pathExtension
        guard let format = ComicFormat(fileExtension: ext) else {
            reportError("Formato non supportato: .\(ext)")
            return
        }

        do {
            let relativePath = try LibraryStorage.importFile(from: url)
            registerComic(relativePath: relativePath, format: format, into: context)
        } catch {
            reportError(error.localizedDescription)
        }
    }

    /// Analizza ed inserisce in Core Data un file GIÀ presente nella cartella della libreria
    /// (nessuna copia). Usato da `rebuildLibrary`, dove il file esiste ma manca il record.
    private func registerComic(relativePath: String, format: ComicFormat, into context: NSManagedObjectContext) {
        let destinationURL = LibraryStorage.fileURL(forRelativePath: relativePath)
        let defaultDirectionRawValue = UserDefaults.standard.string(forKey: "defaultReadingDirection")
        let defaultDirection = ReadingDirection(rawValue: defaultDirectionRawValue ?? "") ?? .leftToRight

        var pageCount = 0
        var coverData: Data?
        var metadata: ComicInfoMetadata?
        if let provider = try? ComicPageProviderFactory.makeProvider(for: destinationURL, format: format) {
            pageCount = provider.pageCount
            if provider.pageCount > 0 {
                let rawCoverData = (try? provider.rawData(atPage: 0)).flatMap { $0 }
                if let rawCoverData = rawCoverData {
                    coverData = ThumbnailGenerator.makeThumbnailData(fromSourceData: rawCoverData)
                } else if let coverImage = try? provider.image(atPage: 0) {
                    coverData = ThumbnailGenerator.makeThumbnailData(from: coverImage)
                }
            }
            if let xml = provider.comicInfoXML {
                metadata = ComicInfoMetadata.parse(from: xml)
            }
        }

        let fallbackTitle = (relativePath as NSString).deletingPathExtension
        let title = metadata?.title ?? metadata?.series.map { series in
            metadata?.number.map { "\(series) #\($0)" } ?? series
        } ?? fallbackTitle

        let seriesName = metadata?.series ?? Self.deriveSeriesName(fromFallbackTitle: fallbackTitle)

        context.performAndWait {
            let comic = ComicEntity.create(
                title: title,
                seriesName: seriesName,
                relativePath: relativePath,
                format: format,
                readingDirection: defaultDirection,
                in: context
            )
            comic.pageCount = Int32(pageCount)
            comic.coverImageData = coverData
            try? context.save()
        }
        DiagnosticLog.log("Importato \"\(title)\" (\(format.rawValue), \(pageCount) pagine)")
    }

    /// Molti CBZ/CBR scansionati non hanno un ComicInfo.xml con la serie: senza un fallback,
    /// finirebbero tutti ammassati in "Altri fumetti" invece che raggruppati per testata. Se il
    /// titolo finisce con un numero (es. "Topolino 3595"), lo togliamo e usiamo il resto come
    /// nome serie ("Topolino").
    static func deriveSeriesName(fromFallbackTitle title: String) -> String? {
        guard let range = title.range(of: #"\s+#?\d+\s*$"#, options: .regularExpression) else { return nil }
        let series = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return series.isEmpty ? nil : series
    }

    private func reportError(_ message: String) {
        DiagnosticLog.log("Errore import: \(message)")
        DispatchQueue.main.async {
            self.importError = message
        }
    }

    func delete(_ comic: ComicEntity, from context: NSManagedObjectContext) {
        LibraryStorage.removeFile(relativePath: comic.relativePath ?? "")
        context.delete(comic)
        try? context.save()
    }

    /// Registra in libreria i fumetti trascinati nella cartella Documents dell'app dal Finder
    /// (`UIFileSharingEnabled`, device collegato via USB → tab "File") o da Files.
    ///
    /// È volutamente separata da `rebuildLibrary`, non un suo caso particolare: quella cancella i
    /// record il cui file non esiste più, e su una libreria iCloud i file non ancora scaricati
    /// possono benissimo non esistere su disco. Questo passaggio invece è solo additivo, quindi
    /// può girare a ogni foreground senza gate su iCloud e senza rischiare di svuotare la libreria.
    func adoptFilesDroppedInDocuments(context: NSManagedObjectContext) {
        let backgroundContext = makeBackgroundContext(from: context)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let candidates = LibraryStorage.adoptFilesDroppedInLocalDocuments()
            guard !candidates.isEmpty else { return }

            var knownPaths: Set<String> = []
            backgroundContext.performAndWait {
                let request = ComicEntity.fetchRequest()
                guard let comics = try? backgroundContext.fetch(request) else { return }
                knownPaths = Set(comics.compactMap { $0.relativePath })
            }

            let newPaths = candidates.filter { !knownPaths.contains($0) }
            guard !newPaths.isEmpty else { return }

            DispatchQueue.main.async { self.isImporting = true }
            for relativePath in newPaths {
                guard let format = ComicFormat(fileExtension: (relativePath as NSString).pathExtension) else { continue }
                self.registerComic(relativePath: relativePath, format: format, into: backgroundContext)
            }
            DiagnosticLog.log("File Sharing: aggiunti \(newPaths.count) fumetti dalla cartella Documents")
            DispatchQueue.main.async { self.isImporting = false }
        }
    }

    /// Strumento di recupero: rimuove dalla libreria i fumetti il cui file non esiste più
    /// (es. cancellato manualmente dal Finder/Files), e registra i file trovati nella cartella
    /// della libreria ma non ancora presenti — utile dopo un ripristino da backup o un problema
    /// di sincronizzazione.
    func rebuildLibrary(context: NSManagedObjectContext) {
        isImporting = true
        let backgroundContext = makeBackgroundContext(from: context)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var removedCount = 0

            var knownPaths: Set<String> = []
            backgroundContext.performAndWait {
                let request = ComicEntity.fetchRequest()
                guard let comics = try? backgroundContext.fetch(request) else { return }
                for comic in comics {
                    let path = comic.relativePath ?? ""
                    let url = LibraryStorage.fileURL(forRelativePath: path)
                    if path.isEmpty || !FileManager.default.fileExists(atPath: url.path) {
                        backgroundContext.delete(comic)
                        removedCount += 1
                    } else {
                        knownPaths.insert(path)
                    }
                }
                try? backgroundContext.save()
            }

            let root = LibraryStorage.rootFolderURL()
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let unknownComicFiles = files.filter { url in
                ComicFormat(fileExtension: url.pathExtension) != nil && !knownPaths.contains(url.lastPathComponent)
            }

            for url in unknownComicFiles {
                guard let format = ComicFormat(fileExtension: url.pathExtension) else { continue }
                self.registerComic(relativePath: url.lastPathComponent, format: format, into: backgroundContext)
            }

            DiagnosticLog.log("Rebuild library: rimossi \(removedCount), ritrovati \(unknownComicFiles.count)")

            DispatchQueue.main.async {
                self.isImporting = false
            }
        }
    }
}
