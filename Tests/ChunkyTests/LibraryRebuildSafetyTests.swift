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
    @discardableResult
    private func makeLocalComic(title: String, addedDaysAgo: Double = 0, in context: NSManagedObjectContext) throws -> ComicEntity {
        let comic = ComicEntity.create(
            title: title,
            relativePath: "\(title).cbz",
            format: .cbz,
            isRemotePlaceholder: false,
            sourceAccountID: nil,
            sourceRelativePath: nil,
            in: context
        )
        comic.dateAdded = Date().addingTimeInterval(-addedDaysAgo * 24 * 60 * 60)
        try context.save()
        return comic
    }

    /// Isolated defaults per test: the "missing since" record must not leak between tests or
    /// into the app's real preferences.
    private func freshDefaults() -> UserDefaults {
        let suite = "LibraryRebuildSafetyTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return .standard }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func titles(in context: NSManagedObjectContext) throws -> [String] {
        let request = ComicEntity.fetchRequest()
        return try context.fetch(request).compactMap(\.title).sorted()
    }

    #if os(macOS)
    /// Il rebuild scansiona la cartella della libreria: nei test deve essere la sandbox
    /// temporanea (`LibraryStorage.uiTestingSandboxURL`), mai `~/Documents` o iCloud Drive reali.
    @Test("I test usano una cartella libreria temporanea")
    func libraryRootIsTemporarySandbox() throws {
        let root = LibraryStorage.rootFolderURL().standardizedFileURL.path
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(root.hasPrefix(temp))
        #expect(LibraryStorage.localDocumentsURL.standardizedFileURL.path.hasPrefix(temp))
        #expect(LibraryStorage.remoteCacheFolderURL(accountID: UUID()).standardizedFileURL.path.hasPrefix(temp))
    }
    #endif

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

    @Test("Con stato noto vuoto rimuove i file spariti da almeno 30 minuti")
    func knownEmptyCloudStateRemovesMissingFilesAfterGrace() throws {
        let context = try TestStore.makeContext()
        try makeLocalComic(title: "RebuildSafetyRimosso", addedDaysAgo: 3, in: context)
        let viewModel = LibraryViewModel()
        let defaults = freshDefaults()
        let start = Date()

        // Prima volta che manca: si annota, non si cancella.
        viewModel.performRebuildLibrary(in: context, cloudKnownPaths: [], now: start, graceDefaults: defaults)
        #expect(try titles(in: context) == ["RebuildSafetyRimosso"])

        // Ancora mancante dopo l'attesa: via.
        let later = start.addingTimeInterval(MissingFileGrace.missingWindow + 60)
        viewModel.performRebuildLibrary(in: context, cloudKnownPaths: [], now: later, graceDefaults: defaults)
        #expect(try titles(in: context) == [])
    }

    @Test("Ricostruisci libreria a mano non aspetta i 30 minuti")
    func userInitiatedRebuildSkipsMissingWindow() throws {
        let context = try TestStore.makeContext()
        try makeLocalComic(title: "RebuildSafetyManuale", addedDaysAgo: 3, in: context)
        let viewModel = LibraryViewModel()

        viewModel.performRebuildLibrary(in: context, cloudKnownPaths: [], bypassMissingGrace: true, graceDefaults: freshDefaults())
        #expect(try titles(in: context) == [])
    }

    @Test("Un fumetto aggiunto da poco non si cancella, nemmeno a mano")
    func recentImportIsNeverDeleted() throws {
        let context = try TestStore.makeContext()
        // Il record arriva da CloudKit prima che iCloud Drive consegni il file: sembra sparito.
        try makeLocalComic(title: "RebuildSafetyAppenaImportato", in: context)
        let viewModel = LibraryViewModel()
        let defaults = freshDefaults()

        viewModel.performRebuildLibrary(in: context, cloudKnownPaths: [], bypassMissingGrace: true, graceDefaults: defaults)
        let later = Date().addingTimeInterval(MissingFileGrace.missingWindow + 60)
        viewModel.performRebuildLibrary(in: context, cloudKnownPaths: [], now: later, graceDefaults: defaults)
        #expect(try titles(in: context) == ["RebuildSafetyAppenaImportato"])
    }

    @Test("Un fumetto ricomparso riparte da zero")
    func reappearedComicResetsCountdown() throws {
        let context = try TestStore.makeContext()
        try makeLocalComic(title: "RebuildSafetyRicomparso", addedDaysAgo: 3, in: context)
        let viewModel = LibraryViewModel()
        let defaults = freshDefaults()
        let start = Date()

        viewModel.performRebuildLibrary(in: context, cloudKnownPaths: [], now: start, graceDefaults: defaults)
        // Il file ricompare in iCloud: il conto alla rovescia si azzera.
        viewModel.performRebuildLibrary(in: context, cloudKnownPaths: ["RebuildSafetyRicomparso.cbz"], now: start.addingTimeInterval(60), graceDefaults: defaults)
        // Sparisce di nuovo: dopo l'attesa *dalla prima volta* non basta, si riparte da qui.
        let afterFirstWindow = start.addingTimeInterval(MissingFileGrace.missingWindow + 60)
        viewModel.performRebuildLibrary(in: context, cloudKnownPaths: [], now: afterFirstWindow, graceDefaults: defaults)
        #expect(try titles(in: context) == ["RebuildSafetyRicomparso"])
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
