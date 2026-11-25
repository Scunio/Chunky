#if DEBUG
import CoreData
import Foundation

/// DEBUG builds only: inserts one comic and one account whose attributes cover the CloudKit fields
/// missing from the Production schema, so the Development environment creates them just in time
/// when Core Data exports these rows. The schema can then be deployed to Production from CloudKit
/// Console. Launched with `--debug-seed-cloudkit-schema` on a simulator signed into iCloud.
///
/// Deliberately not `NSPersistentCloudKitContainer.initializeCloudKitSchema()`: that creates every
/// attribute of the model, including `sourceAccountID`/`sourceRelativePath`, which must never reach
/// CloudKit (remote-account comics live in the local-only store). Here only the fields that should
/// sync get a value:
/// - `ComicEntity.coverImageDataInline` (the extracted cover — Core Data exports it despite
///   `syncable="NO"`, and Production refused it with invalidArguments);
/// - `RemoteAccountEntity.domainOrWorkgroup` and `resolvedAddressOverride`.
enum CloudKitSchemaSeed {
    static let launchArgument = "--debug-seed-cloudkit-schema"
    static let markerName = "Schema seed CloudKit (da eliminare)"

    static func seedIfRequested(in context: NSManagedObjectContext) {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        let request = RemoteAccountEntity.fetchRequest()
        request.predicate = NSPredicate(format: "name == %@", markerName)
        guard ((try? context.count(for: request)) ?? 0) == 0 else {
            DiagnosticLog.log("Schema seed: già presente, niente da fare")
            return
        }
        RemoteAccountEntity.create(
            kind: .smb,
            name: markerName,
            serverURLString: "smb://schema-seed.invalid",
            username: nil,
            password: nil,
            shareName: "seed",
            domainOrWorkgroup: "WORKGROUP",
            resolvedAddressOverride: "192.0.2.1",
            autoScanEnabled: false,
            in: context
        )
        let comic = ComicEntity.create(
            title: markerName,
            relativePath: "schema-seed-\(UUID().uuidString).cbz",
            format: .cbz,
            in: context
        )
        // A tiny real PNG (1×1): the field's type is what matters, not the picture.
        comic.coverImageDataInline = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")
        do {
            try context.save()
            DiagnosticLog.log("Schema seed: account e fumetto inseriti, in attesa dell'export verso Development")
        } catch {
            DiagnosticLog.log("Schema seed: salvataggio fallito: \(error.localizedDescription)")
        }
    }
}
#endif
