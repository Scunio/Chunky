import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer
    private(set) var loadError: Error?

    /// Name of the second, local-only store's configuration: entities listed under it in the
    /// model (currently just remote-account-sourced `ComicEntity` rows) live in a store that is
    /// never mirrored to CloudKit — see the comment on the "Local" `<configuration>` in the model.
    static let localOnlyConfigurationName = "Local"

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "Chunky")

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

        let group = DispatchGroup()
        allDescriptions.forEach { _ in group.enter() }
        container.loadPersistentStores { description, error in
            if let error { failures.append((description, error)) }
            group.leave()
        }
        group.wait()

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
            retryGroup.wait()

            if let retryError {
                DiagnosticLog.log("Retry after deleting store also failed: \((retryError as NSError).localizedDescription)")
                if firstError == nil { firstError = retryError }
            }
        }
        container.persistentStoreDescriptions = allDescriptions

        return firstError
    }
}
