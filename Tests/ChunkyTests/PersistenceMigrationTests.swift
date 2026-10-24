import CoreData
import Foundation
import Testing

@Suite("Migrazione Core Data", .serialized)
struct PersistenceMigrationTests {
    @Test("Il preflight interroga tutti i fumetti come la libreria")
    func libraryPreflightFetchesAllComics() throws {
        let context = try TestStore.makeContext()
        for index in 0..<3 {
            _ = ComicEntity.create(
                title: "Fumetto \(index)",
                relativePath: "fumetto-\(index).cbz",
                format: .cbz,
                in: context
            )
        }
        try context.save()

        let request = PersistenceController.libraryFetchRequest()
        let results = try context.fetch(request)

        #expect(request.fetchLimit == 0)
        #expect(request.resultType == .managedObjectResultType)
        #expect(results.count == 3)
    }

    @MainActor
    @Test("La query sicura aggiorna la libreria senza NSFetchedResultsController")
    func safeComicResultsTracksContextChanges() async throws {
        let context = try TestStore.makeContext()
        let results = SafeComicResults()
        results.start(in: context)
        #expect(results.comics.isEmpty)

        _ = ComicEntity.create(
            title: "Nuovo fumetto",
            relativePath: "nuovo-fumetto.cbz",
            format: .cbz,
            in: context
        )
        try context.save()

        for _ in 0..<20 where results.comics.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(results.error == nil)
        #expect(results.comics.map(\.title) == ["Nuovo fumetto"])
        results.stop()
    }

    @Test("Il preflight traduce le eccezioni Core Data in errori recuperabili")
    func preflightCatchesInvalidFetch() {
        let model = NSManagedObjectModel()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "MissingEntity")

        let error = ObjCExceptionCatcher.preflightFetchRequest(request, in: context)

        #expect(error != nil)
    }

    @Test("Il modello finale è compatibile con il modello ponte e conserva i dati in SQLite")
    func coverMigrationMappingsCanBeInferred() throws {
        guard let modelBundle = (Bundle.allBundles + Bundle.allFrameworks)
            .compactMap({ $0.url(forResource: "Chunky", withExtension: "momd") })
            .first else {
            Issue.record("Bundle del modello Core Data non trovato")
            return
        }

        func model(_ version: String) throws -> NSManagedObjectModel {
            let url = modelBundle.appendingPathComponent("\(version).mom")
            guard let model = NSManagedObjectModel(contentsOf: url) else {
                Issue.record("Modello Core Data \(version) non trovato")
                throw CocoaError(.fileReadCorruptFile)
            }
            return model
        }

        let bridge = try model("Chunky 3.5")
        let current = try model("Chunky 4")
        let history = ["Chunky", "Chunky 2", "Chunky 2.5", "Chunky 2.6", "Chunky 3", "Chunky 3.5", "Chunky 4"]
        for pair in zip(history, history.dropFirst()) {
            _ = try NSMappingModel.inferredMappingModel(
                forSourceModel: model(pair.0),
                destinationModel: model(pair.1)
            )
        }
        _ = try NSMappingModel.inferredMappingModel(
            forSourceModel: model("Chunky 2"),
            destinationModel: bridge
        )
        _ = try NSMappingModel.inferredMappingModel(
            forSourceModel: bridge,
            destinationModel: current
        )

        let cover = try #require(current.entitiesByName["ComicEntity"]?.attributesByName["coverImageDataInline"])
        #expect(!cover.allowsExternalBinaryDataStorage)

        // CloudKit production schemas are additive. Keep the existing synced property in
        // the model as a deprecated field while the new per-device cache stays local-only.
        let legacyCover = try #require(current.entitiesByName["ComicEntity"]?.attributesByName["coverImageData"])
        #expect(legacyCover.allowsExternalBinaryDataStorage)
        #expect(legacyCover.renamingIdentifier == "coverImageData")

        let versionInfoURL = modelBundle.appendingPathComponent("VersionInfo.plist")
        let versionInfoData = try Data(contentsOf: versionInfoURL)
        let versionInfo = try #require(
            PropertyListSerialization.propertyList(from: versionInfoData, format: nil) as? [String: Any]
        )
        let checksums = try #require(
            versionInfo["NSManagedObjectModel_VersionChecksums"] as? [String: String]
        )
        func checksum(_ name: String) throws -> String {
            try #require(checksums[name], "Checksum mancante per \(name)")
        }
        let stagedModelChecksums = try ["Chunky", "Chunky 2", "Chunky 2.5", "Chunky 2.6", "Chunky 3", "Chunky 3.5", "Chunky 4"]
            .map(checksum)
        #expect(Set(stagedModelChecksums).count == stagedModelChecksums.count, "Ogni modello dello staging deve avere un checksum distinto")

        let historicalStage = NSLightweightMigrationStage([
            try checksum("Chunky"),
            try checksum("Chunky 2"),
            try checksum("Chunky 2.5"),
            try checksum("Chunky 2.6"),
            try checksum("Chunky 3")
        ])
        let bridgeReference = NSManagedObjectModelReference(model: bridge, versionChecksum: try checksum("Chunky 3.5"))
        let currentReference = NSManagedObjectModelReference(model: current, versionChecksum: try checksum("Chunky 4"))
        let coverStage = NSCustomMigrationStage(migratingFrom: bridgeReference, to: currentReference)
        _ = NSStagedMigrationManager([historicalStage, coverStage])
    }

    // Run this end-to-end migration in a dedicated xcodebuild invocation. Core Data's
    // historical model versions reuse the app's managed-object classes, which conflict with
    // the other in-memory Core Data stores when Swift Testing runs suites in parallel.
#if CHUNKY_RUN_PERSISTENCE_MIGRATION_TESTS
    @Test("La migrazione SQLite reale conserva la copertina e i manager degli store sono distinti")
    func stagedMigrationCopiesExternalCoverInSQLite() throws {
        let firstManager = PersistenceController.makeStagedMigrationManager()
        let secondManager = PersistenceController.makeStagedMigrationManager()
        #expect(firstManager !== secondManager)

        let modelBundle = try #require(
            (Bundle.allBundles + Bundle.allFrameworks)
                .compactMap { $0.url(forResource: "Chunky", withExtension: "momd") }
                .first
        )
        let currentModel = try #require(NSManagedObjectModel(contentsOf: modelBundle))
        var randomState: UInt64 = 0x9E3779B97F4A7C15
        let expectedCover = Data((0..<(2 * 1024 * 1024)).map { _ in
            randomState ^= randomState << 13
            randomState ^= randomState >> 7
            randomState ^= randomState << 17
            return UInt8(truncatingIfNeeded: randomState)
        })
        let migrationCases = [
            "Chunky",
            "Chunky 2",
            "Chunky 2.5",
            "Chunky 2.6",
            "Chunky 3"
        ]
        for sourceVersion in migrationCases {
            let oldModelURL = modelBundle.appendingPathComponent("\(sourceVersion).mom")
            let oldModel = try #require(NSManagedObjectModel(contentsOf: oldModelURL))
            let storeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("StagedMigration-\(UUID().uuidString).sqlite")
            defer {
                for url in [storeURL, storeURL.appendingPathExtension("shm"), storeURL.appendingPathExtension("wal")] {
                    try? FileManager.default.removeItem(at: url)
                }
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "_SUPPORT"))
            }

            do {
                let source = NSPersistentContainer(name: "Chunky", managedObjectModel: oldModel)
                let description = NSPersistentStoreDescription(url: storeURL)
                if oldModel.configurations.contains("Local") {
                    description.configuration = "Local"
                }
                source.persistentStoreDescriptions = [description]
                try Self.loadStores(source)

                let comic = NSEntityDescription.insertNewObject(
                    forEntityName: "ComicEntity",
                    into: source.viewContext
                )
                comic.setValue("Migrazione copertina", forKey: "title")
                comic.setValue("migrazione.cbz", forKey: "relativePath")
                let sourceCoverKey = sourceVersion == "Chunky 2.6" ? "coverImageDataExternal" : "coverImageData"
                comic.setValue(expectedCover, forKey: sourceCoverKey)
                try source.viewContext.save()
                #expect(comic.value(forKey: sourceCoverKey) as? Data == expectedCover)

                source.viewContext.reset()
                if let store = source.persistentStoreCoordinator.persistentStores.first {
                    try source.persistentStoreCoordinator.remove(store)
                }
            }

            let destination = NSPersistentContainer(name: "Chunky", managedObjectModel: currentModel)
            let description = NSPersistentStoreDescription(url: storeURL)
            if oldModel.configurations.contains("Local") {
                description.configuration = "Local"
            }
            description.setOption(
                PersistenceController.makeStagedMigrationManager(),
                forKey: NSPersistentStoreStagedMigrationManagerOptionKey
            )
            destination.persistentStoreDescriptions = [description]
            do {
                try Self.loadStores(destination)
            } catch {
                throw NSError(
                    domain: "PersistenceMigrationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Migrazione da \(sourceVersion) fallita: \(error.localizedDescription)"]
                )
            }

            let request = NSFetchRequest<NSManagedObject>(entityName: "ComicEntity")
            let migratedComics = try destination.viewContext.fetch(request)
            #expect(migratedComics.count == 1)
            #expect(
                migratedComics.first?.value(forKey: "coverImageDataInline") as? Data
                    == expectedCover,
                "Versione sorgente: \(sourceVersion)"
            )
            #expect(try destination.viewContext.fetch(PersistenceController.libraryFetchRequest()).count == 1)

            destination.viewContext.reset()
            if let store = destination.persistentStoreCoordinator.persistentStores.first {
                // Core Data may still be finishing SQLite maintenance after the load callback;
                // a cleanup-only detach failure must not mask the migration/data assertions.
                try? destination.persistentStoreCoordinator.remove(store)
            }
        }
    }

    private static func loadStores(_ container: NSPersistentContainer) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var storeError: Error?
        container.loadPersistentStores { _, error in
            storeError = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + .seconds(15)) == .success else {
            throw PersistenceLoadError.timedOut
        }
        if let storeError { throw storeError }
    }
#endif
}
