import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer
    private(set) var loadError: Error?

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "Chunky")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else {
            container.persistentStoreDescriptions.first?.setOption(
                true as NSNumber,
                forKey: NSPersistentHistoryTrackingKey
            )
            container.persistentStoreDescriptions.first?.setOption(
                true as NSNumber,
                forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey
            )
        }

        loadError = Self.loadStores(in: container)

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Carica lo store; se fallisce (es. archivio corrotto o schema incompatibile) lo elimina
    /// e riprova una volta, così un dato locale danneggiato non impedisce mai l'avvio dell'app.
    private static func loadStores(in container: NSPersistentCloudKitContainer) -> Error? {
        var firstError: Error?
        var didRetry = false

        func attempt() {
            container.loadPersistentStores { description, error in
                guard let error = error else { return }
                DiagnosticLog.log("loadPersistentStores failed: \((error as NSError).localizedDescription) \((error as NSError).userInfo)")
                if !didRetry, let url = description.url {
                    didRetry = true
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
                    try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
                    attempt()
                } else if firstError == nil {
                    firstError = error
                }
            }
        }

        attempt()
        return firstError
    }
}
