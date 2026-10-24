import CoreData
import Foundation
import Testing

@Suite("Migrazione Core Data")
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

    @Test("I modelli storici migrano attraverso il ponte senza copiare il riferimento esterno")
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

        let bridge = try model("Chunky 2.6")
        for sourceVersion in ["Chunky 2", "Chunky 2.5"] {
            let source = try model(sourceVersion)
            _ = try NSMappingModel.inferredMappingModel(
                forSourceModel: source,
                destinationModel: bridge
            )
        }

        let current = try model("Chunky 3")
        _ = try NSMappingModel.inferredMappingModel(
            forSourceModel: bridge,
            destinationModel: current
        )

        let cover = try #require(current.entitiesByName["ComicEntity"]?.attributesByName["coverImageData"])
        #expect(!cover.allowsExternalBinaryDataStorage)

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

        let firstStage = NSLightweightMigrationStage([try checksum("Chunky")])
        let bridgeStage = NSLightweightMigrationStage([
            try checksum("Chunky 2"),
            try checksum("Chunky 2.5")
        ])
        let bridgeReference = NSManagedObjectModelReference(model: bridge, versionChecksum: try checksum("Chunky 2.6"))
        let currentReference = NSManagedObjectModelReference(model: current, versionChecksum: try checksum("Chunky 3"))
        let coverStage = NSCustomMigrationStage(migratingFrom: bridgeReference, to: currentReference)
        _ = NSStagedMigrationManager([firstStage, bridgeStage, coverStage])
    }
}
