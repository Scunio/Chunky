import CoreData
import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Quando un account viene eliminato, i suoi segnaposto mai scaricati devono
/// sparire (orfani che non potrebbero più scaricarsi), quelli scaricati restare.
/// `Ricostruisci libreria` deve fare lo stesso per gli orfani rimasti indietro.
@Suite("Pulizia segnaposto orfani", .serialized)
struct OrphanPlaceholderTests {
    private func makeAccount(name: String, in context: NSManagedObjectContext) throws -> RemoteAccountEntity {
        let account = RemoteAccountEntity.create(
            kind: .smb,
            name: name,
            serverURLString: "smb://192.168.1.10",
            username: "lorenzo",
            password: nil,
            shareName: "Public",
            in: context
        )
        try context.save()
        return account
    }

    private func makeComic(title: String, accountID: UUID?, placeholder: Bool, in context: NSManagedObjectContext) throws {
        ComicEntity.create(
            title: title,
            relativePath: "\(title).cbz",
            format: .cbz,
            isRemotePlaceholder: placeholder,
            sourceAccountID: accountID,
            sourceRelativePath: accountID == nil ? nil : "smb://192.168.1.10/Public/\(title).cbz",
            in: context
        )
        try context.save()
    }

    private func titles(in context: NSManagedObjectContext) throws -> [String] {
        let request = ComicEntity.fetchRequest()
        return try context.fetch(request).compactMap(\.title).sorted()
    }

    @Test("Eliminare l'account toglie i suoi placeholder, tiene gli scaricati")
    func deleteAccountRemovesOnlyItsPlaceholders() throws {
        let context = try TestStore.makeContext()
        let account = try makeAccount(name: "NAS", in: context)
        let other = try makeAccount(name: "Altro", in: context)
        try makeComic(title: "DaScaricare", accountID: account.stableID, placeholder: true, in: context)
        try makeComic(title: "Scaricato", accountID: account.stableID, placeholder: false, in: context)
        try makeComic(title: "AltroAccount", accountID: other.stableID, placeholder: true, in: context)

        #expect(ComicEntity.deleteOrphanPlaceholders(ofAccountID: account.stableID, in: context) == 1)
        try context.save()
        #expect(try titles(in: context) == ["AltroAccount", "Scaricato"])
    }

    @Test("Ricostruisci toglie i placeholder di account inesistenti")
    func rebuildRemovesPlaceholdersWithMissingAccount() throws {
        let context = try TestStore.makeContext()
        let account = try makeAccount(name: "NAS", in: context)
        try makeComic(title: "Suo", accountID: account.stableID, placeholder: true, in: context)
        try makeComic(title: "Orfano", accountID: UUID(), placeholder: true, in: context)
        try makeComic(title: "Locale", accountID: nil, placeholder: false, in: context)

        #expect(ComicEntity.deletePlaceholdersWithMissingAccount(in: context) == 1)
        try context.save()
        #expect(try titles(in: context) == ["Locale", "Suo"])
    }
}
