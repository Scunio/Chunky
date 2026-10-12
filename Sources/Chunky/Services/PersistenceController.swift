import CoreData
import Foundation

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer
    private(set) var loadError: Error?

    /// Name of the second, local-only store's configuration: entities listed under it in the
    /// model (currently just remote-account-sourced `ComicEntity` rows) live in a store that is
    /// never mirrored to CloudKit — see the comment on the "Local" `<configuration>` in the model.
    static let localOnlyConfigurationName = "Local"

    /// Bounds `loadPersistentStores`'s CloudKit round trip: unbounded, a stalled network hung
    /// the whole app on a physical Apple TV before any UI existed.
    private static let loadTimeout: DispatchTimeInterval = .seconds(20)

    /// Anchors `Bundle(for:)` below — any class works, this one exists purely to be that anchor.
    private final class BundleToken {}

    /// `NSPersistentCloudKitContainer(name:)` alone resolves its model via `Bundle.main`. That's
    /// correct for a normally-launched app, but confirmed to break under Xcode's Previews/
    /// RunCodeSnippet JIT execution (`__preview.dylib` injected): there, `Bundle.main` resolves
    /// to the injected dylib wrapper, not the bundle actually containing `Chunky.momd`, so the
    /// container silently loads zero entities and every fetch crashes with "must have an
    /// entity". `Bundle(for:)` finds the bundle containing this module's own compiled code
    /// instead, which is reliable in both contexts — a real launch behaves identically either way.
    private static let model: NSManagedObjectModel = {
        guard let modelURL = Bundle(for: BundleToken.self).url(forResource: "Chunky", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Could not locate/load the Chunky Core Data model")
        }
        return model
    }()

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "Chunky", managedObjectModel: Self.model)

        guard let cloudDescription = container.persistentStoreDescriptions.first else {
            fatalError("NSPersistentCloudKitContainer did not create its default store description")
        }

        let localDescription = NSPersistentStoreDescription()
        localDescription.configuration = Self.localOnlyConfigurationName
        // No `cloudKitContainerOptions` here — that's what keeps this store out of CloudKit.

        if inMemory {
            cloudDescription.type = NSInMemoryStoreType
            localDescription.type = NSInMemoryStoreType
        } else {
            cloudDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            cloudDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            let localStoreURL = NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("ChunkyLocal.sqlite")
            localDescription.url = localStoreURL
        }
        // Migrazione leggera esplicita (v2→v3: vincolo di unicità su `ComicEntity.relativePath`):
        // i default sarebbero già `true`, ma la migrazione è esattamente ciò da cui dipende
        // l'avvio dopo questo aggiornamento, quindi meglio non affidarla a un default implicito.
        // Il vincolo non tocca lo schema CloudKit (è solo locale): nessun passaggio lato server.
        cloudDescription.shouldMigrateStoreAutomatically = true
        cloudDescription.shouldInferMappingModelAutomatically = true
        localDescription.shouldMigrateStoreAutomatically = true
        localDescription.shouldInferMappingModelAutomatically = true

        container.persistentStoreDescriptions.append(localDescription)

        loadError = Self.loadStores(in: container)

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        // Gli account creati prima dell'introduzione di `id` ce l'hanno a nil e senza
        // backfill ogni accesso al Keychain userebbe un UUID diverso (vedi `stableID`).
        // Su main all'avvio: sincrono e una tantum (idempotente).
        RemoteAccountEntity.backfillMissingIDs(in: container.viewContext)
    }

    /// Loads every store description, waiting for all of them to report in before returning —
    /// `loadPersistentStores`'s completion handler isn't guaranteed synchronous (a CloudKit-backed
    /// store's schema setup can take a moment), so this is the only way to know the real outcome
    /// for every store instead of possibly returning before some completions have even fired.
    ///
    /// If a store fails (e.g. corrupted archive or incompatible schema), its files are deleted
    /// and it's retried through `container.loadPersistentStores` again — not
    /// `persistentStoreCoordinator.addPersistentStore` directly, which silently drops
    /// `cloudKitContainerOptions` and would leave a recovered CloudKit-backed store never wired
    /// up for sync. Retrying is scoped to just the failed description (`persistentStoreDescriptions`
    /// is narrowed to it for the retry call, then restored) so already-loaded stores aren't
    /// re-attempted, which fails.
    private static func loadStores(in container: NSPersistentCloudKitContainer) -> Error? {
        let allDescriptions = container.persistentStoreDescriptions
        var failures: [(NSPersistentStoreDescription, Error)] = []
        // `loadPersistentStores` can invoke its completion for different store descriptions
        // concurrently on different queues — this serializes the appends into `failures`.
        let failuresLock = NSLock()

        let group = DispatchGroup()
        allDescriptions.forEach { _ in group.enter() }
        container.loadPersistentStores { description, error in
            if let error {
                failuresLock.lock()
                failures.append((description, error))
                failuresLock.unlock()
            }
            group.leave()
        }
        if group.wait(timeout: .now() + loadTimeout) == .timedOut {
            return PersistenceLoadError.timedOut
        }

        guard !failures.isEmpty else { return nil }

        var firstError: Error?
        for (description, error) in failures {
            DiagnosticLog.log("loadPersistentStores failed: \((error as NSError).localizedDescription) \((error as NSError).userInfo)")

            guard let url = description.url, url.isFileURL else {
                if firstError == nil { firstError = error }
                continue
            }

            // Rete di sicurezza prima del fallback distruttivo qui sotto: uno store v2 con duplicati
            // preesistenti fallisce la migrazione v3 (vincolo di unicità su `relativePath`) e senza
            // questo passaggio verrebbe cancellato con tutto il progresso. Collassa i duplicati col
            // modello legacy — stesso LWW della dedup, quindi ogni device sceglie lo stesso superstite —
            // e riprova: se lo store non è v2 o la causa è un'altra, il cleanup non fa nulla e si
            // prosegue col fallback esistente.
            if collapseDuplicatesWithLegacyModel(storeURL: url) {
                let retryError = scopedLoad(container: container, description: description)
                if retryError == nil {
                    DiagnosticLog.log("Migrazione riuscita dopo la pulizia dei duplicati preesistenti")
                    continue
                }
                // Timeout, non fallimento: come nel codice originale, niente cancellazione —
                // lo store è intatto, è solo la rete/CloudKit ad essere lenta.
                // (`PersistenceLoadError` ha il solo caso `.timedOut`.)
                if let retryError, retryError is PersistenceLoadError {
                    if firstError == nil { firstError = retryError }
                    continue
                }
            }

            deleteStoreFiles(at: url)

            if let retryError = scopedLoad(container: container, description: description) {
                DiagnosticLog.log("Retry after deleting store also failed: \((retryError as NSError).localizedDescription)")
                if firstError == nil { firstError = retryError }
            }
        }
        container.persistentStoreDescriptions = allDescriptions

        return firstError
    }

    /// Carica la sola `description` (gli store già caricati non vengono ritentati) e ritorna
    /// l'eventuale errore. Usato sia dal retry post-cleanup che dal fallback post-cancellazione.
    private static func scopedLoad(
        container: NSPersistentCloudKitContainer,
        description: NSPersistentStoreDescription
    ) -> Error? {
        container.persistentStoreDescriptions = [description]
        var retryError: Error?
        let retryGroup = DispatchGroup()
        retryGroup.enter()
        container.loadPersistentStores { _, error in
            retryError = error
            retryGroup.leave()
        }
        if retryGroup.wait(timeout: .now() + loadTimeout) == .timedOut {
            return PersistenceLoadError.timedOut
        }
        return retryError
    }

    private static func deleteStoreFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
    }

    /// Collassa i duplicati per `relativePath` aprendo `storeURL` col modello v2 (senza vincolo di
    /// unicità) e applicando lo stesso last-writer-wins della dedup (`ComicEntity.absorbLoser`).
    /// Ritorna true se il cleanup è stato eseguito (store apribile come v2), false se non applicabile
    /// (store già migrato, corrotto o inesistente: il chiamante prosegue per la sua strada).
    /// Idempotente e sicuro: senza duplicati apre, non trova nulla e salva niente.
    @discardableResult
    static func collapseDuplicatesWithLegacyModel(storeURL: URL) -> Bool {
        guard let momd = Bundle(for: BundleToken.self).url(forResource: "Chunky", withExtension: "momd"),
              let legacyModel = NSManagedObjectModel(contentsOf: momd.appendingPathComponent("Chunky 2.mom"))
        else { return false }
        let container = NSPersistentContainer(name: "Chunky", managedObjectModel: legacyModel)
        // Senza migrazione, di proposito: deve aprire solo uno store già v2.
        // Uno store v3 o corrotto fallisce qui e il cleanup è correttamente non applicabile.
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldMigrateStoreAutomatically = false
        description.shouldInferMappingModelAutomatically = false
        container.persistentStoreDescriptions = [description]
        // Niente CloudKit: tocca solo righe `ComicEntity`, i metadati del mirror restano intatti
        // e al prossimo avvio riuscito esportano le tombstone dei perdenti.
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        guard loadError == nil else { return false }

        let context = container.viewContext
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        var collapsed = 0
        context.performAndWait {
            let pathsRequest = NSFetchRequest<NSDictionary>(entityName: "ComicEntity")
            pathsRequest.resultType = .dictionaryResultType
            pathsRequest.propertiesToFetch = ["relativePath"]
            guard let rows = try? context.fetch(pathsRequest) else { return }
            var counts: [String: Int] = [:]
            for row in rows {
                guard let path = row["relativePath"] as? String, !path.isEmpty else { continue }
                counts[path, default: 0] += 1
            }
            let dupPaths = counts.filter { $0.value > 1 }.map(\.key)
            guard !dupPaths.isEmpty else { return }

            let request = ComicEntity.fetchRequest()
            request.predicate = NSPredicate(format: "relativePath IN %@", dupPaths)
            guard let comics = try? context.fetch(request) else { return }
            for (_, group) in Dictionary(grouping: comics, by: { $0.relativePath ?? "" }) where group.count > 1 {
                let ordered = group.sorted(by: ComicEntity.precedesAsSurvivor)
                guard let survivor = ordered.first else { continue }
                for loser in ordered.dropFirst() {
                    survivor.absorbLoser(loser)
                    let identifier = loser.objectID.uriRepresentation().absoluteString
                    context.delete(loser)
                    collapsed += 1
                    ComicTextIndex.deleteIndex(forComicIdentifier: identifier)
                }
            }
            if collapsed > 0 { try? context.save() }
        }
        DiagnosticLog.log("Pulizia pre-migrazione: collassati \(collapsed) record duplicati")
        return true
    }
}

enum PersistenceLoadError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Il caricamento della libreria ha impiegato troppo tempo, probabilmente per un problema di rete con iCloud. Riprova."
    }
}
