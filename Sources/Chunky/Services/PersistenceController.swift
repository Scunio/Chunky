import CoreData
import Foundation

struct PersistenceController {
    /// `var` (non `let`) per il ripristino dalla schermata d'errore: `resetShared()` lo ricrea
    /// senza rilanciare l'app. Chi legge `.shared` al momento dell'uso (es. i push di
    /// `RemoteProgressSync`) vede sempre l'istanza corrente.
    static var shared = PersistenceController()

    /// Ricrea da zero container e store (rilancia caricamento ed eventuale migrazione).
    /// Pesante e bloccante: chiamare fuori dal main (lo fa `StorageErrorView`).
    static func resetShared() {
        shared = PersistenceController()
    }

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

    /// `coverImageData` used external binary storage, which can leave a dangling reference if
    /// SQLite and Core Data's sidecar files are restored or synced at different times. Migrate
    /// through an inline temporary attribute, copy each readable blob while the old model is
    /// active, then rename the inline attribute back to `coverImageData`.
    private static let stagedMigrationManager: NSStagedMigrationManager = {
        func loadVersion(_ name: String) -> NSManagedObjectModel {
            guard let momdURL = Bundle(for: BundleToken.self).url(forResource: "Chunky", withExtension: "momd") else {
                fatalError("Could not locate the Chunky Core Data model bundle")
            }
            let modelURL = momdURL.appendingPathComponent("\(name).mom")
            guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
                fatalError("Could not load Core Data model version \(name)")
            }
            return model
        }

        let v1 = loadVersion("Chunky")
        let v2 = loadVersion("Chunky 2")
        let bridge = loadVersion("Chunky 2.5")
        let current = loadVersion("Chunky 3")

        let lightweight = NSLightweightMigrationStage([
            v1.versionChecksum,
            v2.versionChecksum,
            bridge.versionChecksum
        ])
        lightweight.label = "Chunky 1–2.5: prepare inline cover storage"

        let bridgeReference = NSManagedObjectModelReference(
            model: bridge,
            versionChecksum: bridge.versionChecksum
        )
        let currentReference = NSManagedObjectModelReference(
            model: current,
            versionChecksum: current.versionChecksum
        )
        let copyCoverData = NSCustomMigrationStage(
            migratingFrom: bridgeReference,
            to: currentReference
        )
        copyCoverData.label = "Chunky 2.5–3: migrate covers into SQLite"
        copyCoverData.willMigrateHandler = { migrationManager, _ in
            guard let migrationContainer = migrationManager.container else {
                throw NSError(
                    domain: "com.scunio.chunky.persistence",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Contesto di migrazione Core Data non disponibile"]
                )
            }
            let context = migrationContainer.newBackgroundContext()
            do {
                try context.performAndWait {
                    let request = NSFetchRequest<NSManagedObject>(entityName: "ComicEntity")
                    let comics = try context.fetch(request)
                    for comic in comics {
                        if let data = ObjCExceptionCatcher.safeBinaryValue(for: comic, key: "coverImageData") {
                            comic.setValue(data, forKey: "coverImageDataInline")
                            // Remove the external reference before the schema drops the old
                            // attribute. If the migration is retried, the inline copy remains.
                            ObjCExceptionCatcher.clearBinaryValue(for: comic, key: "coverImageData")
                        } else {
                            // A dangling sidecar is a missing derived cover; the existing
                            // backfill regenerates it from the comic archive after migration.
                            ObjCExceptionCatcher.clearBinaryValue(for: comic, key: "coverImageData")
                        }
                    }
                    if context.hasChanges { try context.save() }
                }
            } catch {
                DiagnosticLog.log("Migrazione cover Core Data fallita: \(error.localizedDescription)")
                throw error
            }
        }

        return NSStagedMigrationManager([lightweight, copyCoverData])
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
            cloudDescription.setOption(
                Self.stagedMigrationManager,
                forKey: NSPersistentStoreStagedMigrationManagerOptionKey
            )
            cloudDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            cloudDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            let localStoreURL = NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("ChunkyLocal.sqlite")
            localDescription.url = localStoreURL
            localDescription.setOption(
                Self.stagedMigrationManager,
                forKey: NSPersistentStoreStagedMigrationManagerOptionKey
            )
        }
        // Migrazione leggera esplicita: i default sarebbero già `true`, ma da una migrazione
        // dipende potenzialmente l'avvio dopo un aggiornamento, quindi meglio non affidarla a un
        // default implicito. (Nota: vincoli di unicità sulle entity mirrorate sono vietati da
        // CloudKit — errore 134060 — quindi niente constraint su `relativePath`: i duplicati
        // restano compito della dedup convergente.)
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

            // Prima di qualunque recupero, riprova sullo stesso file: potrebbe essere un
            // timeout o un errore transitorio. Gli errori di migrazione non devono mai attivare
            // il fallback distruttivo: il database resta intatto per poter correggere la
            // migrazione e riprovare senza perdere dati locali non ancora sincronizzati.
            if let retryError = scopedLoad(container: container, description: description) {
                // Timeout, non fallimento: come nel codice originale, niente cancellazione —
                // lo store è intatto, è solo la rete/CloudKit ad essere lenta.
                // (`PersistenceLoadError` ha il solo caso `.timedOut`.)
                if retryError is PersistenceLoadError {
                    if firstError == nil { firstError = retryError }
                    continue
                }
                if Self.isMigrationFailure(retryError) {
                    DiagnosticLog.log("Store conservato dopo errore di migrazione: \((retryError as NSError).localizedDescription)")
                    if firstError == nil { firstError = retryError }
                    continue
                }
            } else {
                continue
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
    /// l'eventuale errore. Usato dal retry non distruttivo e dal fallback post-cancellazione.
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

    /// Core Data migration failures are recoverable by a later app build; deleting the store
    /// here would silently discard local library metadata and unsynced reading progress.
    private static func isMigrationFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           (134100...134190).contains(nsError.code) || [134505, 134506].contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMigrationFailure(underlying)
        }
        if let detailedErrors = nsError.userInfo[NSDetailedErrorsKey] as? [Error],
           detailedErrors.contains(where: isMigrationFailure) {
            return true
        }
        return false
    }
}

enum PersistenceLoadError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Il caricamento della libreria ha impiegato troppo tempo, probabilmente per un problema di rete con iCloud. Riprova."
    }
}
