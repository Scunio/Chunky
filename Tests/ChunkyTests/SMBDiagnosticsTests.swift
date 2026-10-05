import CoreData
import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Regressione per i log reali del 2026-10-05 (Testo-AB7F5D23391C-1.txt):
/// tutti con `preflight=granted`, quindi MAI blocco privacy "Rete locale",
/// e tutti gli account salvati con `pass=no` + `EPERM=true` (Error code 1)
/// = "Accesso negato dal NAS", non bug dell'app.
@Suite("Diagnostica SMB dai log reali", .serialized)
struct SMBDiagnosticsTests {
    private func withFakeKeychain(_ body: (FakeKeychain) throws -> Void) rethrows {
        let fake = FakeKeychain()
        let previous = KeychainStore.backend
        KeychainStore.backend = fake
        defer { KeychainStore.backend = previous }
        try body(fake)
    }

    @Test("Usa l'override risolto quando presente")
    func usesResolvedOverride() throws {
        try withFakeKeychain { _ in
            let context = try TestStore.makeContext()
            let account = RemoteAccountEntity.create(
                kind: .smb,
                name: "NAS",
                serverURLString: "smb://NAS07BE7B.local",
                username: "Lorenzo",
                password: "secret",
                portNumber: 445,
                shareName: "Public",
                resolvedAddressOverride: "192.168.1.10",
                in: context
            )
            let info = try #require(SMBConnectionInfo(account: account))
            #expect(info.host == "192.168.1.10")
            #expect(info.share == "Public")
            #expect(info.port == 445)
            #expect(info.username == "Lorenzo")
            #expect(info.password == "secret")
        }
    }

    @Test("Senza override usa l'host dell'URL, anche con spazi e &")
    func fallsBackToURLHost() throws {
        try withFakeKeychain { _ in
            let context = try TestStore.makeContext()
            let account = RemoteAccountEntity.create(
                kind: .smb,
                name: "NAS",
                serverURLString: "smb://192.168.1.10",
                username: "lorenzo",
                password: "secret",
                shareName: "Fumetti & Graphic Novel",
                in: context
            )
            let info = try #require(SMBConnectionInfo(account: account))
            #expect(info.host == "192.168.1.10")
            #expect(info.share == "Fumetti & Graphic Novel")
        }
    }

    @Test("Ritorna nil senza share o senza host")
    func nilWithoutShareOrHost() throws {
        try withFakeKeychain { _ in
            let context = try TestStore.makeContext()
            let noShare = RemoteAccountEntity.create(
                kind: .smb, name: "X", serverURLString: "smb://192.168.1.10",
                username: nil, password: nil, shareName: nil, in: context
            )
            #expect(SMBConnectionInfo(account: noShare) == nil)

            let noHost = RemoteAccountEntity.create(
                kind: .smb, name: "Y", serverURLString: "",
                username: nil, password: nil, shareName: "Public", in: context
            )
            #expect(SMBConnectionInfo(account: noHost) == nil)
        }
    }

    @Test("EPERM con preflight granted non è blocco privacy")
    func epermWithGrantedPreflightIsNASDenial() {
        // Replica le 4 righe `EPERM=true preflight=granted err=Error code 1`:
        // il socket dice EPERM ma il preflight NWBrowser dice granted,
        // quindi la UI deve mostrare "Accesso negato dal NAS", mai il banner Rete locale.
        let error = POSIXError(.EPERM)
        #expect(error.isLocalNetworkDenied) // flag EPERM= nei log resta true
        #expect(error.chunkyFriendlyDescription == "Accesso negato dal NAS. Controlla condivisione, nome utente e password (Account → Modifica).")
    }

    @Test("Timeout e DNS dei log reali mappano al messaggio giusto")
    func timeoutAndDNSMapCorrectly() {
        #expect(POSIXError(.ETIMEDOUT).chunkyFriendlyDescription.contains("stessa rete"))
        #expect(!POSIXError(.ETIMEDOUT).isLocalNetworkDenied)

        // `Error code 5: Invalid address ... Can not resolve` = il .local non si risolve:
        // non è EPERM, non è privacy, è "controlla indirizzo / usa IP".
        let dns = URLError(.cannotFindHost)
        #expect(!dns.isLocalNetworkDenied)
        #expect(dns.chunkyFriendlyDescription.contains("Controlla l'indirizzo"))
    }

    @Test("Account salvato senza password è la causa più probabile di EPERM")
    func missingPasswordIsLikelyCauseOfEPERM() throws {
        // Tutti i log reali hanno `pass=no`: l'account nel Keychain è vuoto.
        try withFakeKeychain { _ in
            let context = try TestStore.makeContext()
            let account = RemoteAccountEntity.create(
                kind: .smb,
                name: "NAS",
                serverURLString: "smb://192.168.1.10",
                username: "lorenzo",
                password: nil, // come nei log: pass=no
                shareName: "Fumetti & Graphic Novel",
                in: context
            )
            #expect(account.password == nil)
            let info = try #require(SMBConnectionInfo(account: account))
            #expect(info.password == nil)
            // Con password nil contro share protetta il NAS risponde EPERM (Error code 1).
            #expect(POSIXError(.EPERM).chunkyFriendlyDescription.contains("password"))
        }
    }
}
