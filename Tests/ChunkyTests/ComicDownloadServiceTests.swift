import CoreData
import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Due richieste per lo stesso placeholder remoto mentre la prima è in corso devono
/// condividere un solo trasferimento, e ogni completion deve scattare esattamente una volta.
@Suite("Download placeholder remoto: waiters", .serialized)
@MainActor
struct ComicDownloadServiceTests {
    private struct Boom: Error {}

    /// Client finto: conta i trasferimenti e resta in volo finché il test non lo sblocca.
    private final class GatedBrowser: RemoteBrowsing, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        var shouldFail = false

        var downloadCount: Int { lock.withLock { count } }

        func listEntries(at url: URL, account: RemoteAccountEntity) async throws -> [RemoteEntry] { [] }

        func download(_ entry: RemoteEntry, account: RemoteAccountEntity) async throws -> URL {
            lock.withLock { count += 1 }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    continuation = cont
                    return false
                }
                if resumeNow { cont.resume() }
            }
            if shouldFail { throw Boom() }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Chunky-Remote-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(entry.title)
            try Data("not a real comic".utf8).write(to: file)
            return file
        }

        func release() {
            let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                defer { continuation = nil }
                return continuation
            }
            cont?.resume()
        }
    }

    private func makeComic(in context: NSManagedObjectContext) throws -> ComicEntity {
        let account = RemoteAccountEntity.create(
            kind: .webdav, name: "NAS", serverURLString: "http://192.168.1.10",
            username: nil, password: nil, shareName: nil, in: context
        )
        let name = "WaitersTest-\(UUID().uuidString)"
        let comic = ComicEntity.create(
            title: name,
            relativePath: "\(name).cbz",
            format: .cbz,
            isRemotePlaceholder: true,
            sourceAccountID: account.stableID,
            sourceRelativePath: "http://192.168.1.10/\(name).cbz",
            in: context
        )
        try context.save()
        return comic
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func run(failing: Bool) async throws {
        let browser = GatedBrowser()
        browser.shouldFail = failing
        let previous = ComicDownloadService.makeBrowser
        ComicDownloadService.makeBrowser = { _ in browser }
        defer { ComicDownloadService.makeBrowser = previous }

        let context = try TestStore.makeContext()
        let comic = try makeComic(in: context)
        let relativePath = comic.relativePath ?? ""
        let sourcePath = comic.sourceRelativePath ?? ""
        let accountID = try #require(comic.sourceAccountID)
        // Il download scrive su disco (cache remota dell'account; nelle versioni precedenti la
        // libreria reale, ~/Documents su macOS): va ripulito, altrimenti altri test (es.
        // LibraryRebuildSafetyTests) vedono file "sconosciuti" e li importano.
        defer {
            try? FileManager.default.removeItem(at: LibraryStorage.remoteCacheFolderURL(accountID: accountID))
            try? FileManager.default.removeItem(at: LibraryStorage.fileURL(forRelativePath: relativePath))
            withExtendedLifetime(context) {}
        }

        var results: [String: [Bool]] = [:]   // chiave: chi, valore: un elemento per ogni chiamata (true = errore)
        let first = ComicDownloadService.downloadIfNeeded(comic: comic) { results["first", default: []].append($0 != nil) }
        await waitUntil { browser.downloadCount == 1 }
        let second = ComicDownloadService.downloadIfNeeded(comic: comic) { results["second", default: []].append($0 != nil) }
        // Lascia al secondo task, se ce ne fosse uno, il tempo di partire.
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(first != nil)
        #expect(first === second)
        #expect(browser.downloadCount == 1)
        #expect(results.isEmpty)

        browser.release()
        await waitUntil { results["first"] != nil && results["second"] != nil }
        // Margine per eventuali chiamate doppie.
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(results["first"] == [failing])
        #expect(results["second"] == [failing])
        #expect(browser.downloadCount == 1)
        #expect(DownloadManager.shared.item(forKey: sourcePath) == nil)
    }

    @Test("Due richieste in volo: un solo trasferimento, entrambe le completion una volta")
    func twoCallersShareOneTransfer() async throws {
        try await run(failing: false)
    }

    @Test("Con errore: un solo trasferimento, entrambe le completion ricevono l'errore")
    func twoCallersShareOneFailedTransfer() async throws {
        try await run(failing: true)
    }
}
