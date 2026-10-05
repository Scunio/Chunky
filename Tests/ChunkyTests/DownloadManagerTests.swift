import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Due tap ravvicinati sullo stesso placeholder (o pre-cache + tap) devono
/// agganciarsi al download in corso, non avviarne un secondo (era il "Topolino 1").
@Suite("Dedup download concorrenti")
struct DownloadManagerTests {
    @Test("Stessa chiave due volte dà lo stesso item e una sola riga")
    @MainActor
    func sameKeyReturnsExistingItem() {
        let manager = DownloadManager.shared
        let key = "test-dedup-\(UUID().uuidString)"
        let before = manager.activeDownloads.count
        let first = manager.register(title: "Fumetto", key: key)
        let second = manager.register(title: "Fumetto", key: key)
        #expect(first.id == second.id)
        #expect(manager.activeDownloads.count == before + 1)
        manager.remove(first)
        #expect(manager.activeDownloads.count == before)
    }

    @Test("Dopo remove si può registrare di nuovo")
    @MainActor
    func canRegisterAgainAfterRemove() {
        let manager = DownloadManager.shared
        let key = "test-rereg-\(UUID().uuidString)"
        let first = manager.register(title: "Fumetto", key: key)
        manager.remove(first)
        let second = manager.register(title: "Fumetto", key: key)
        #expect(first.id != second.id)
        manager.remove(second)
    }
}
