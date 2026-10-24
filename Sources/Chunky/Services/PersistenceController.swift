import CoreData
import Foundation

struct PersistenceController {
    /// `var` (non `let`) per il ripristino dalla schermata d'errore: `resetShared()` lo ricrea
    /// senza rilanciare l'app. Chi legge `.shared` al momento dell'uso (es. i push di
    /// `RemoteProgressSync`) vede sempre l'istanza corrente.
    static var shared = PersistenceController(
        uiTesting: CommandLine.arguments.contains("--uitesting")
    )

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

        // Read the compiled checksums from the model bundle. Asking a freshly loaded model
        // for `versionChecksum` logs that it is still editable and can return an unstable
        // value, which prevents Core Data from matching a store to the staged migration path.
        guard let momdURL = Bundle(for: BundleToken.self).url(forResource: "Chunky", withExtension: "momd"),
              let versionInfoData = try? Data(contentsOf: momdURL.appendingPathComponent("VersionInfo.plist")),
              let versionInfo = try? PropertyListSerialization.propertyList(from: versionInfoData, format: nil)
                as? [String: Any],
              let checksums = versionInfo["NSManagedObjectModel_VersionChecksums"] as? [String: String] else {
            fatalError("Could not load Core Data model version checksums")
        }
        func checksum(_ name: String) -> String {
            guard let value = checksums[name] else {
                fatalError("Could not find Core Data model version checksum for \(name)")
            }
            return value
        }

        let v1 = loadVersion("Chunky")
        let v2 = loadVersion("Chunky 2")
        let bridge = loadVersion("Chunky 2.6")
        let current = loadVersion("Chunky 3")

        let v1ToV2 = NSLightweightMigrationStage([checksum("Chunky")])
        v1ToV2.label = "Chunky 1–2: lightweight migration"

        // Chunky 2.5 was shipped in a TestFlight build. Include it as an accepted
        // source so stores from that build can migrate to the corrected bridge model.
        let v2ToBridge = NSLightweightMigrationStage([
            checksum("Chunky 2"),
            checksum("Chunky 2.5")
        ])
        v2ToBridge.label = "Chunky 2–2.6: lightweight migration"

        let bridgeReference = NSManagedObjectModelReference(
            model: bridge,
            versionChecksum: checksum("Chunky 2.6")
        )
        let currentReference = NSManagedObjectModelReference(
            model: current,
            versionChecksum: checksum("Chunky 3")
        )
        let copyCoverData = NSCustomMigrationStage(
            migratingFrom: bridgeReference,
            to: currentReference
        )
        copyCoverData.label = "Chunky 2.6–3: migrate covers into SQLite"
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
                        if let data = ObjCExceptionCatcher.safeBinaryValue(for: comic, key: "coverImageDataExternal") {
                            comic.setValue(data, forKey: "coverImageDataInline")
                            // Remove the external reference before the schema drops the old
                            // attribute. If the migration is retried, the inline copy remains.
                            ObjCExceptionCatcher.clearBinaryValue(for: comic, key: "coverImageDataExternal")
                        } else {
                            // A dangling sidecar is a missing derived cover; the existing
                            // backfill regenerates it from the comic archive after migration.
                            ObjCExceptionCatcher.clearBinaryValue(for: comic, key: "coverImageDataExternal")
                        }
                    }
                    if context.hasChanges { try context.save() }
                }
            } catch {
                DiagnosticLog.log("Migrazione cover Core Data fallita: \(error.localizedDescription)")
                throw error
            }
        }

        return NSStagedMigrationManager([v1ToV2, v2ToBridge, copyCoverData])
    }()

    init(inMemory: Bool = false, uiTesting: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "Chunky", managedObjectModel: Self.model)

        guard let cloudDescription = container.persistentStoreDescriptions.first else {
            fatalError("NSPersistentCloudKitContainer did not create its default store description")
        }

        let localDescription = NSPersistentStoreDescription()
        localDescription.configuration = Self.localOnlyConfigurationName
        // No `cloudKitContainerOptions` here — that's what keeps this store out of CloudKit.

        if inMemory {
            cloudDescription.type = NSInMemoryStoreType
            cloudDescription.cloudKitContainerOptions = nil
            localDescription.type = NSInMemoryStoreType
        } else {
            // UI automation runs without CloudKit entitlements. Use the normal SQLite
            // stores, but omit CloudKit setup and migration work so simulator behavior is
            // deterministic and matches the UI flows the tests exercise.
            if uiTesting {
                cloudDescription.cloudKitContainerOptions = nil
            } else {
                cloudDescription.setOption(
                    Self.stagedMigrationManager,
                    forKey: NSPersistentStoreStagedMigrationManagerOptionKey
                )
            }
            cloudDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            cloudDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            let localStoreURL = NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("ChunkyLocal.sqlite")
            localDescription.url = localStoreURL
            if !uiTesting {
                localDescription.setOption(
                    Self.stagedMigrationManager,
                    forKey: NSPersistentStoreStagedMigrationManagerOptionKey
                )
            }
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

        let storeLoadError = Self.loadStores(in: container)

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        // SwiftUI's @FetchRequest executes its first query while constructing the root
        // navigation stack. Core Data can raise an NSException for a store/query problem
        // instead of returning an NSError; that escapes SwiftUI and terminates the app.
        // Probe the library request here, before the UI is allowed to install its FRC, and
        // show the existing storage-recovery screen if Core Data rejects it.
        loadError = storeLoadError ?? Self.preflightLibraryFetch(in: container.viewContext)

        // Gli account creati prima dell'introduzione di `id` ce l'hanno a nil e senza
        // backfill ogni accesso al Keychain userebbe un UUID diverso (vedi `stableID`).
        // Su main all'avvio: sincrono e una tantum (idempotente).
        if loadError == nil {
            RemoteAccountEntity.backfillMissingIDs(in: container.viewContext)
        }
    }

    private static func preflightLibraryFetch(in context: NSManagedObjectContext) -> Error? {
        let request = libraryFetchRequest()
        if let error = ObjCExceptionCatcher.preflightFetchRequest(request, in: context) {
            DiagnosticLog.log("Query iniziale della libreria non disponibile: \(error.localizedDescription) \((error as NSError).userInfo)")
            return error
        }
        return nil
    }

    /// Keep startup validation aligned with the full object query installed by LibraryView's
    /// `@FetchRequest`. Fetching only one row or only object IDs can miss an error encountered
    /// while Core Data materializes a later comic.
    static func libraryFetchRequest() -> NSFetchRequest<NSFetchRequestResult> {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "ComicEntity")
        request.resultType = .managedObjectResultType
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ComicEntity.title, ascending: true)]
        return request
    }

    /// Loads every store description, waiting for all of them to report in before returning —
    /// `loadPersistentStores`'s completion handler isn't guaranteed synchronous (a CloudKit-backed
    /// store's schema setup can take a moment), so this is the only way to know the real outcome
    /// for every store instead of possibly returning before some completions have even fired.
    ///
    /// A failed store gets one non-destructive retry through `container.loadPersistentStores` —
    /// not `persistentStoreCoordinator.addPersistentStore` directly, which silently drops
    /// `cloudKitContainerOptions` and would leave a recovered CloudKit-backed store never wired
    /// up for sync. Retrying is scoped to just the failed description (`persistentStoreDescriptions`
    /// is narrowed to it for the retry call, then restored) so already-loaded stores aren't
    /// re-attempted. The store files are never deleted automatically: even a corrupt store may
    /// contain recoverable local metadata or unsynced progress, so recovery must preserve it.
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

            // Riprova sullo stesso file: potrebbe essere un errore transitorio. Nessun errore
            // autorizza la cancellazione automatica dello store.
            if let retryError = scopedLoad(container: container, description: description) {
                DiagnosticLog.log("Store conservato dopo il retry fallito: \((retryError as NSError).localizedDescription) \((retryError as NSError).userInfo)")
                if firstError == nil { firstError = retryError }
            } else {
                continue
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

}

enum PersistenceLoadError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Il caricamento della libreria ha impiegato troppo tempo, probabilmente per un problema di rete con iCloud. Riprova."
    }
}
