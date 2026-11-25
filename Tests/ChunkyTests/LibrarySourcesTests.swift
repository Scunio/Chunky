import CoreData
import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Libreria divisa per sorgente: iCloud è la base, i fumetti di un NAS (anche 300 importati in
/// blocco) stanno nella pagina del loro account e in "Tutti" solo se l'utente lo chiede.
@Suite("Sorgenti della libreria")
struct LibrarySourcesTests {
    private let nasID = UUID()
    private let root = "smb://nas.local/Fumetti"

    private func makeComics(in context: NSManagedObjectContext) -> (cloud: ComicEntity, nas: ComicEntity, reading: ComicEntity) {
        let cloud = ComicEntity.create(title: "Topolino 3618", seriesName: "Topolino", relativePath: "Topolino 3618.cbr", format: .cbr, in: context)
        let nas = ComicEntity.create(
            title: "Dylan Dog 1", seriesName: "Dylan Dog", relativePath: "Dylan Dog 1.cbz", format: .cbz,
            isRemotePlaceholder: true, sourceAccountID: nasID,
            sourceRelativePath: "\(root)/Bonelli/Dylan%20Dog/Dylan%20Dog%201.cbz", in: context
        )
        let reading = ComicEntity.create(
            title: "Dylan Dog 2", seriesName: "Dylan Dog", relativePath: "Dylan Dog 2.cbz", format: .cbz,
            sourceAccountID: nasID, sourceRelativePath: "\(root)/Dylan%20Dog%202.cbz", in: context
        )
        reading.pageCount = 100
        reading.lastReadPage = 40
        nas.isFavorite = true
        return (cloud, nas, reading)
    }

    @Test("«Tutti» mostra solo iCloud, a meno che l'utente non includa gli account")
    func allExcludesRemoteByDefault() throws {
        let context = try TestStore.makeContext()
        let comics = makeComics(in: context)
        let all = [comics.cloud, comics.nas, comics.reading]

        #expect(LibrarySources.filter(all, selection: .all, includeRemoteInAll: false) == [comics.cloud])
        #expect(LibrarySources.filter(all, selection: .all, includeRemoteInAll: true).count == 3)
        // Le serie seguono la stessa regola: "Dylan Dog" non compare se gli account sono esclusi.
        #expect(LibrarySources.filter(all, selection: .group("Dylan Dog"), includeRemoteInAll: false).isEmpty)
    }

    @Test("Preferiti e In lettura attraversano tutte le sorgenti")
    func crossSourceViews() throws {
        let context = try TestStore.makeContext()
        let comics = makeComics(in: context)
        let all = [comics.cloud, comics.nas, comics.reading]

        #expect(LibrarySources.filter(all, selection: .favorites, includeRemoteInAll: false) == [comics.nas])
        #expect(LibrarySources.filter(all, selection: .reading, includeRemoteInAll: false) == [comics.reading])
    }

    @Test("La pagina di una sorgente mostra solo i suoi fumetti")
    func sourcePages() throws {
        let context = try TestStore.makeContext()
        let comics = makeComics(in: context)
        let all = [comics.cloud, comics.nas, comics.reading]

        #expect(LibrarySources.filter(all, selection: .source(nil), includeRemoteInAll: false) == [comics.cloud])
        #expect(Set(LibrarySources.filter(all, selection: .source(nasID), includeRemoteInAll: false)) == [comics.nas, comics.reading])
        #expect(LibrarySources.filter(all, selection: .source(UUID()), includeRemoteInAll: true).isEmpty)
    }

    @Test("Cartella ricavata dall'URL: decodificata, senza nome file, vuota nella radice")
    func remoteFolderDerivation() {
        #expect(LibrarySources.remoteFolder(sourceAbsoluteString: "\(root)/Bonelli/Dylan%20Dog/1.cbz", rootAbsoluteString: root) == "Bonelli › Dylan Dog")
        #expect(LibrarySources.remoteFolder(sourceAbsoluteString: "\(root)/1.cbz", rootAbsoluteString: root + "/") == "")
        #expect(LibrarySources.remoteFolder(sourceAbsoluteString: "smb://altro/1.cbz", rootAbsoluteString: root) == nil)
    }

    @Test("Sezioni per cartella: prima la radice, poi le cartelle in ordine")
    func folderSectionsOrder() throws {
        let context = try TestStore.makeContext()
        let comics = makeComics(in: context)
        let sections = LibrarySources.folderSections(for: [comics.nas, comics.reading], rootAbsoluteString: root)

        #expect(sections.map(\.title) == [LibrarySources.rootFolderTitle, "Bonelli › Dylan Dog"])
        #expect(sections.first?.comics == [comics.reading])
    }
}
