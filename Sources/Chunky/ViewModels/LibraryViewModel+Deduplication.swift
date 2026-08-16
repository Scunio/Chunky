import Foundation
import CoreData

extension LibraryViewModel {
    /// Collassa i record che puntano allo stesso file. Ne servono due sorgenti: le scansioni
    /// sovrapposte (ora serializzate, ma i duplicati già creati restano) e i due dispositivi —
    /// iPad e Mac creano ciascuno il proprio `ComicEntity` per lo stesso file nel container
    /// iCloud, e CloudKit sincronizza entrambi i record.
    ///
    /// Non tocca MAI i file: il file è uno solo ed è quello che i record duplicati condividono.
    @discardableResult
    func deduplicateComics(in context: NSManagedObjectContext) -> Int {
        var collapsed = 0
        context.performAndWait {
            guard let duplicatePaths = duplicateRelativePaths(in: context), !duplicatePaths.isEmpty else { return }

            let request = ComicEntity.fetchRequest()
            request.predicate = NSPredicate(format: "relativePath IN %@", duplicatePaths)
            // Il contesto di scansione vive quanto l'app e può avere in memoria questi oggetti da
            // una passata precedente: senza forzare il refresh, la fusione leggerebbe i valori
            // vecchi e butterebbe via il progresso di lettura arrivato nel frattempo da CloudKit.
            request.shouldRefreshRefetchedObjects = true
            guard let comics = try? context.fetch(request) else { return }

            for (path, group) in Dictionary(grouping: comics, by: { $0.relativePath ?? "" }) where group.count > 1 {
                let ordered = group.sorted(by: Self.precedesAsSurvivor)
                guard let survivor = ordered.first else { continue }
                for loser in ordered.dropFirst() {
                    Self.merge(loser, into: survivor)
                    context.delete(loser)
                    collapsed += 1
                }
                DiagnosticLog.log("Deduplica: \(group.count) record per \"\(path)\", ne resta 1")
            }

            if collapsed > 0 { try? context.save() }
        }
        if collapsed > 0 {
            DiagnosticLog.log("Deduplica libreria: rimossi \(collapsed) record duplicati")
        }
        return collapsed
    }

    /// Ricalcola la serie dei fumetti che ne sono ancora privi. `seriesName` viene scritto una
    /// volta sola, all'import: senza questa passata, migliorare la deduzione del nome serie non
    /// cambierebbe niente per i fumetti già in libreria, che resterebbero in "Altri fumetti".
    ///
    /// Tocca soltanto i record con serie vuota: chi ha scelto un gruppo a mano (vedi `applyGroup`
    /// in `LibraryView`) ha un `seriesName` valorizzato e non deve essere sovrascritto — mentre
    /// chi ha lasciato "automatico" ha proprio `nil` ed è quello che qui si ricalcola.
    @discardableResult
    func backfillSeriesNames(in context: NSManagedObjectContext) -> Int {
        var filled = 0
        context.performAndWait {
            let request = ComicEntity.fetchRequest()
            request.predicate = NSPredicate(format: "seriesName == nil OR seriesName == %@", "")
            guard let comics = try? context.fetch(request), !comics.isEmpty else { return }

            for comic in comics {
                let fallback = comic.title ?? ((comic.relativePath ?? "") as NSString).deletingPathExtension
                guard let series = Self.deriveSeriesName(fromFallbackTitle: fallback) else { continue }
                comic.seriesName = series
                filled += 1
            }

            if filled > 0 { try? context.save() }
        }
        if filled > 0 {
            DiagnosticLog.log("Serie dedotta per \(filled) fumetti che ne erano privi")
        }
        return filled
    }

    /// Solo i path con più di un record, letti come dizionari: caricare tutti i `ComicEntity`
    /// significherebbe tirare in memoria anche le copertine di tutta la libreria a ogni passata.
    private func duplicateRelativePaths(in context: NSManagedObjectContext) -> [String]? {
        let request = NSFetchRequest<NSDictionary>(entityName: "ComicEntity")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["relativePath"]
        guard let rows = try? context.fetch(request) else { return nil }

        var counts: [String: Int] = [:]
        for row in rows {
            guard let path = row["relativePath"] as? String, !path.isEmpty else { continue }
            counts[path, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.map(\.key)
    }

    /// Ordinamento deterministico: `dateAdded` e `id` sono attributi sincronizzati, quindi iPad e
    /// Mac vedono gli stessi valori e scelgono lo stesso superstite. Se scegliessero record
    /// diversi, ognuno cancellerebbe quello che l'altro tiene e il fumetto sparirebbe da entrambi.
    private static func precedesAsSurvivor(_ lhs: ComicEntity, _ rhs: ComicEntity) -> Bool {
        let leftDate = lhs.dateAdded ?? .distantFuture
        let rightDate = rhs.dateAdded ?? .distantFuture
        if leftDate != rightDate { return leftDate < rightDate }
        return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
    }

    /// Fonde nel superstite quello che c'è di buono nel record scartato: senza questo passaggio la
    /// deduplica si mangerebbe il progresso di lettura fatto sull'altro dispositivo.
    private static func merge(_ source: ComicEntity, into target: ComicEntity) {
        target.lastReadPage = max(target.lastReadPage, source.lastReadPage)
        if target.pageCount <= 0 { target.pageCount = source.pageCount }
        if let opened = source.dateLastOpened, (target.dateLastOpened ?? .distantPast) < opened {
            target.dateLastOpened = opened
        }
        if target.coverImageData == nil { target.coverImageData = source.coverImageData }
        if source.isFavorite { target.isFavorite = true }
        if (target.seriesName ?? "").isEmpty { target.seriesName = source.seriesName }
        if (target.title ?? "").isEmpty { target.title = source.title }
    }
}
