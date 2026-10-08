import CoreData
import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Chiavi deterministiche per la sincronizzazione dei progressi remoti (stile Infuse):
/// tutto puro, niente rete, niente Keychain.
@Suite("Chiavi di sync dei progressi remoti")
struct RemoteProgressSyncKeyTests {
    private func smbAccount(
        in context: NSManagedObjectContext,
        serverURLString: String = "smb://NAS.local",
        shareName: String? = "Fumetti",
        username: String? = "Lorenzo",
        portNumber: Int32 = 445,
        resolvedAddressOverride: String? = nil
    ) -> RemoteAccountEntity {
        RemoteAccountEntity.create(
            kind: .smb,
            name: "NAS",
            serverURLString: serverURLString,
            username: username,
            password: nil,
            portNumber: portNumber,
            shareName: shareName,
            resolvedAddressOverride: resolvedAddressOverride,
            in: context
        )
    }

    @Test("SMB: host, share e utente normalizzati in minuscolo")
    func smbKeyIsNormalized() throws {
        let context = try TestStore.makeContext()
        let account = smbAccount(in: context, serverURLString: "smb://NAS.Local", shareName: "FUMETTI", username: "LORENZO")
        let descriptor = try #require(RemoteProgressSyncKey.descriptor(for: account))
        #expect(RemoteProgressSyncKey.accountSyncKey(for: descriptor) == "smb/nas.local/fumetti/445/lorenzo")
    }

    @Test("SMB: l'override risolto vince sull'host dell'URL")
    func smbKeyUsesResolvedOverride() throws {
        let context = try TestStore.makeContext()
        let account = smbAccount(
            in: context, serverURLString: "smb://NAS.local",
            resolvedAddressOverride: "192.168.1.10"
        )
        let descriptor = try #require(RemoteProgressSyncKey.descriptor(for: account))
        #expect(RemoteProgressSyncKey.accountSyncKey(for: descriptor) == "smb/192.168.1.10/fumetti/445/lorenzo")
    }

    @Test("SMB: due utenti sullo stesso share hanno chiavi diverse")
    func smbKeySeparatesUsers() throws {
        let context = try TestStore.makeContext()
        let alice = try #require(RemoteProgressSyncKey.descriptor(for: smbAccount(in: context, username: "alice")))
        let bob = try #require(RemoteProgressSyncKey.descriptor(for: smbAccount(in: context, username: "bob")))
        #expect(RemoteProgressSyncKey.accountSyncKey(for: alice) != RemoteProgressSyncKey.accountSyncKey(for: bob))
    }

    @Test("SMB senza share non ha identità sincronizzabile")
    func smbWithoutShareHasNoDescriptor() throws {
        let context = try TestStore.makeContext()
        #expect(RemoteProgressSyncKey.descriptor(for: smbAccount(in: context, shareName: nil)) == nil)
    }

    @Test("WebDAV/OPDS: porta di default dalla scheme e base path normalizzato")
    func webdavKeyDefaults() throws {
        let context = try TestStore.makeContext()
        let account = RemoteAccountEntity.create(
            kind: .webdav, name: "Web", serverURLString: "https://Cloud.Example.com/remote.php/dav/",
            username: nil, password: nil, in: context
        )
        let descriptor = try #require(RemoteProgressSyncKey.descriptor(for: account))
        #expect(RemoteProgressSyncKey.accountSyncKey(for: descriptor) == "webdav/cloud.example.com/443/remote.php/dav/")
    }

    @Test("Il nome account non fa parte della chiave: rinominare non rompe il sync")
    func displayNameExcludedFromKey() throws {
        let context = try TestStore.makeContext()
        let first = smbAccount(in: context)
        first.name = "NAS di casa"
        let second = smbAccount(in: context)
        second.name = "Totally different name"
        let key1 = RemoteProgressSyncKey.accountSyncKey(for: try #require(RemoteProgressSyncKey.descriptor(for: first)))
        let key2 = RemoteProgressSyncKey.accountSyncKey(for: try #require(RemoteProgressSyncKey.descriptor(for: second)))
        #expect(key1 == key2)
    }

    @Test("serverPath: estrae il percorso nello share, host case-insensitive")
    func serverPathExtraction() throws {
        #expect(RemoteProgressSyncKey.serverPath(
            rootAbsoluteString: "smb://nas.local/Fumetti",
            sourceAbsoluteString: "smb://NAS.local/Fumetti/Topolino/3620.cbz"
        ) == "/Topolino/3620.cbz")
    }

    @Test("serverPath: la root con slash finale e il prefisso-share parziale")
    func serverPathEdgeCases() throws {
        // Root con slash finale.
        #expect(RemoteProgressSyncKey.serverPath(
            rootAbsoluteString: "smb://nas.local/Fumetti/",
            sourceAbsoluteString: "smb://nas.local/Fumetti/x.cbz"
        ) == "/x.cbz")
        // "share2/..." non deve matchare la root ".../share" (fail-closed).
        #expect(RemoteProgressSyncKey.serverPath(
            rootAbsoluteString: "smb://nas.local/share",
            sourceAbsoluteString: "smb://nas.local/share2/x.cbz"
        ) == nil)
        // Host diverso: altro server.
        #expect(RemoteProgressSyncKey.serverPath(
            rootAbsoluteString: "smb://nas.local/Fumetti",
            sourceAbsoluteString: "smb://altro.local/Fumetti/x.cbz"
        ) == nil)
    }

    @Test("recordName: deterministico, con prefisso, senza caratteri problematici")
    func recordNameIsDeterministic() throws {
        let key = "smb/nas.local/fumetti/445/lorenzo\n/Topolino/3620.cbz"
        let first = RemoteProgressSyncKey.recordName(forProgressKey: key)
        let second = RemoteProgressSyncKey.recordName(forProgressKey: key)
        #expect(first == second)
        #expect(first.hasPrefix("rp_"))
        #expect(first.count == 3 + 64)
        #expect(first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
        #expect(RemoteProgressSyncKey.recordName(forProgressKey: key + "x") != first)
    }

    @Test("Override vuoto o assente: vale la chiave derivata")
    func emptyOverrideFallsBackToDerived() throws {
        let context = try TestStore.makeContext()
        let descriptor = try #require(RemoteProgressSyncKey.descriptor(for: smbAccount(in: context)))
        let derived = RemoteProgressSyncKey.accountSyncKey(for: descriptor)
        #expect(RemoteProgressSyncKey.effectiveAccountSyncKey(descriptor: descriptor, override: nil) == derived)
        #expect(RemoteProgressSyncKey.effectiveAccountSyncKey(descriptor: descriptor, override: "") == derived)
        #expect(RemoteProgressSyncKey.effectiveAccountSyncKey(descriptor: descriptor, override: "   ") == derived)
    }

    @Test("Override impostato: sostituisce la derivata, normalizzato")
    func overrideReplacesDerived() throws {
        let context = try TestStore.makeContext()
        let descriptor = try #require(RemoteProgressSyncKey.descriptor(for: smbAccount(in: context)))
        let derived = RemoteProgressSyncKey.accountSyncKey(for: descriptor)
        let effective = RemoteProgressSyncKey.effectiveAccountSyncKey(descriptor: descriptor, override: "  NAS-Casa ")
        #expect(effective == "custom/nas-casa")
        #expect(effective != derived)
    }

    @Test("Stesso override su account diversi: stessa chiave effettiva")
    func sameOverrideUnifiesDifferentAccounts() throws {
        let context = try TestStore.makeContext()
        // Stesso NAS fisico, scritto in due modi diversi (IP vs hostname).
        let viaIP = try #require(RemoteProgressSyncKey.descriptor(for: smbAccount(
            in: context, serverURLString: "smb://192.168.1.10", resolvedAddressOverride: nil
        )))
        let viaName = try #require(RemoteProgressSyncKey.descriptor(for: smbAccount(
            in: context, serverURLString: "smb://NAS.local", resolvedAddressOverride: nil
        )))
        // Senza override divergono...
        #expect(RemoteProgressSyncKey.accountSyncKey(for: viaIP) != RemoteProgressSyncKey.accountSyncKey(for: viaName))
        // ...con lo stesso override coincidono.
        #expect(
            RemoteProgressSyncKey.effectiveAccountSyncKey(descriptor: viaIP, override: "casa")
                == RemoteProgressSyncKey.effectiveAccountSyncKey(descriptor: viaName, override: "casa")
        )
    }

    @Test("Override in UserDefaults: roundtrip e rimozione con stringa vuota")
    func overrideDefaultsRoundtrip() throws {
        let id = UUID()
        defer { RemoteProgressSync.clearSyncKeyOverride(forAccountID: id) }
        RemoteProgressSync.setSyncKeyOverride("Casa", forAccountID: id)
        #expect(RemoteProgressSync.syncKeyOverride(forAccountID: id) == "Casa")
        RemoteProgressSync.setSyncKeyOverride("  ", forAccountID: id)
        #expect(RemoteProgressSync.syncKeyOverride(forAccountID: id) == "")
    }

    @Test("shouldApply: vince solo il record strettamente più recente")
    func lastWriterWins() throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        #expect(RemoteProgressSyncKey.shouldApply(remoteUpdatedAt: new, localDateLastOpened: old))
        #expect(!RemoteProgressSyncKey.shouldApply(remoteUpdatedAt: old, localDateLastOpened: new))
        // Uguale = eco del nostro stesso push: non riapplicare (niente flap).
        #expect(!RemoteProgressSyncKey.shouldApply(remoteUpdatedAt: new, localDateLastOpened: new))
        // Mai aperto qui: qualsiasi record remoto si applica.
        #expect(RemoteProgressSyncKey.shouldApply(remoteUpdatedAt: old, localDateLastOpened: nil))
    }
}
