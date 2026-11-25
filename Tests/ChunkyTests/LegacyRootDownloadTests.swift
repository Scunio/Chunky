import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Un fumetto scaricato da un account con una versione vecchia sta nella radice iCloud:
/// gli altri dispositivi lo conoscono come fumetto della libreria, quindi il suo progresso
/// deve viaggiare anche con la chiave iCloud. Una copia nella cache remota invece no.
@Suite("Download remoti nella radice iCloud", .serialized)
struct LegacyRootDownloadTests {
    @Test("La cache remota ha la precedenza sulla radice")
    func remoteCacheWins() {
        #expect(LibraryStorage.resolvesToLegacyRoot(cachedExists: false, rootPresent: true))
        #expect(!LibraryStorage.resolvesToLegacyRoot(cachedExists: true, rootPresent: true))
        #expect(!LibraryStorage.resolvesToLegacyRoot(cachedExists: false, rootPresent: false))
    }

    #if !os(tvOS)
    @Test("File nella radice e non in cache: è un download legacy")
    func fileInRootIsLegacy() throws {
        let name = "LegacyRoot-\(UUID().uuidString).cbz"
        let accountID = UUID()
        let rootFile = LibraryStorage.fileURL(forRelativePath: name)
        let cached = LibraryStorage.remoteCacheFileURL(relativePath: name, accountID: accountID)
        // Dove cache remota e radice coincidono (tvOS, test con sandbox) non esiste un
        // "download legacy": il caso non si pone.
        guard cached.standardizedFileURL != rootFile.standardizedFileURL else { return }
        try Data("x".utf8).write(to: rootFile)
        defer { try? FileManager.default.removeItem(at: rootFile) }

        #expect(LibraryStorage.isLegacyRootDownload(relativePath: name, sourceAccountID: accountID))
        // Fumetto della libreria (nessun account): non è un download remoto.
        #expect(!LibraryStorage.isLegacyRootDownload(relativePath: name, sourceAccountID: nil))

        // Con la copia in cache il file del fumetto è quella, non quello condiviso.
        try Data("x".utf8).write(to: cached)
        defer { try? FileManager.default.removeItem(at: cached) }
        #expect(!LibraryStorage.isLegacyRootDownload(relativePath: name, sourceAccountID: accountID))
    }
    #endif
}
