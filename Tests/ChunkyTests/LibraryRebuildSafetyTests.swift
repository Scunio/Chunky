import CoreData
import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Dopo un aggiornamento di iOS iCloud impiega un po' a riconciliare il container:
/// un rebuild lanciato in quella finestra vedeva `cloudKnownPaths` vuoto e cancellava
/// l'intera libreria, e un rebuild accodato mentre la coda era occupata lasciava il
/// banner "Ricostruzione libreria…" acceso per sempre (token mai spento).
@Suite("Rebuild dopo aggiornamento iOS", .serialized)
struct LibraryRebuildSafetyTests {
    private func makeLocalComic(title: String, in context: NSManagedObjectContext) throws {
        ComicEntity.create(
            title: title,
            relativePath: "\(title).cbz",
            format: .cbz,
            isRemotePlaceholder: false,
            sourceAccountID: nil,
            sourceRelativePath: nil,
            in: context
        )
        try context.save()
    }

    private func titles(in context: NSManagedObjectContext) throws -> [String] {
        let request = ComicEntity.fetchRequest()
        return try context.fetch(request).compactMap(\.title).sorted()
    }

    @Test("Con stato iCloud sconosciuto non cancella, solo aggiunge")
    func unknownCloudStateNeverDeletes() throws {
        let context = try TestStore.makeContext()
        try makeLocalComic(title: "RebuildSafetyTenuto", in: context)
        let viewModel = LibraryViewModel()

        // Il file non esiste davvero su disco e non è in cloud: con un set noto
        // verrebbe rimosso, con `nil` (query ancora in gathering) deve restare.
        viewModel.performRebuildLibrary(in: context, cloudKnownPaths: nil)
        #expect(try titles(in: context) == ["RebuildSafetyTenuto"])
    }

    @Test("Con stato noto vuoto rimuove i file davvero spariti")
    func knownEmptyCloudStateRemovesMissingFiles() throws {
        let context = try TestStore.makeContext()
        try makeLocalComic(title: "RebuildSafetyRimosso", in: context)
        let viewModel = LibraryViewModel()

        viewModel.performRebuildLibrary(in: context, cloudKnownPaths: [])
        #expect(try titles(in: context) == [])
    }

    @Test("Con stato sconosciuto gli orfani di account eliminati si puliscono comunque")
    func unknownCloudStateStillCleansOrphanPlaceholders() throws {
        let context = try TestStore.makeContext()
        ComicEntity.create(
            title: "RebuildSafetyOrfano",
            relativePath: "RebuildSafetyOrfano.cbz",
            format: .cbz,
            isRemotePlaceholder: true,
            sourceAccountID: UUID(),
            sourceRelativePath: "smb://192.168.1.10/Public/RebuildSafetyOrfano.cbz",
            in: context
        )
        try context.save()
        let viewModel = LibraryViewModel()

        // Pulizia per account (non per file): sicura anche senza stato cloud.
        viewModel.performRebuildLibrary(in: context, cloudKnownPaths: nil)
        #expect(try titles(in: context) == [])
    }
}
