import CoreData

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

        container.persistentStoreDescriptions.append(localDescription)

        loadError = Self.loadStores(in: container)

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
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

            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))

            container.persistentStoreDescriptions = [description]
            var retryError: Error?
            let retryGroup = DispatchGroup()
            retryGroup.enter()
            container.loadPersistentStores { _, error in
                retryError = error
                retryGroup.leave()
            }
            if retryGroup.wait(timeout: .now() + loadTimeout) == .timedOut {
                if firstError == nil { firstError = PersistenceLoadError.timedOut }
                continue
            }

            if let retryError {
                DiagnosticLog.log("Retry after deleting store also failed: \((retryError as NSError).localizedDescription)")
                if firstError == nil { firstError = retryError }
            }
        }
        container.persistentStoreDescriptions = allDescriptions

        return firstError
    }
}

enum PersistenceLoadError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Il caricamento della libreria ha impiegato troppo tempo, probabilmente per un problema di rete con iCloud. Riprova."
    }
}
