import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

@Suite("Messaggi di errore per gli account remoti")
struct RemoteBrowsingErrorTests {
    @Test("Nessun permesso di Rete locale indica dove attivarlo (per piattaforma)")
    func localNetworkPermissionDenied() {
        let error = POSIXError(.EPERM)
        #expect(error.chunkyFriendlyDescription.contains("Rete locale"))
        #expect(error.isLocalNetworkDenied)
        #if os(tvOS)
        #expect(error.chunkyFriendlyDescription.contains("App"))
        #elseif os(iOS)
        #expect(error.chunkyFriendlyDescription.contains("Privacy e sicurezza"))
        #elseif os(macOS)
        #expect(error.chunkyFriendlyDescription.contains("Impostazioni di Sistema"))
        #endif
    }

    @Test("Altri errori non sono blocco Rete locale")
    func otherErrorsAreNotLocalNetworkDenied() {
        #expect(!POSIXError(.ETIMEDOUT).isLocalNetworkDenied)
        #expect(!URLError(.timedOut).isLocalNetworkDenied)
    }

    @Test("Timeout indica di verificare che il server sia acceso")
    func connectionTimedOut() {
        let error = POSIXError(.ETIMEDOUT)
        #expect(error.chunkyFriendlyDescription == "Il server non ha risposto in tempo. Verifica che sia acceso e sulla stessa rete.")
    }

    @Test("Connessione rifiutata indica di controllare indirizzo e porta")
    func connectionRefused() {
        let error = POSIXError(.ECONNREFUSED)
        #expect(error.chunkyFriendlyDescription == "Il server ha rifiutato la connessione. Controlla indirizzo e porta.")
    }

    @Test("Rete irraggiungibile indica di verificare di essere sulla stessa rete", arguments: [
        POSIXErrorCode.ENETUNREACH, .EHOSTUNREACH, .ENETDOWN
    ])
    func networkUnreachable(code: POSIXErrorCode) {
        let error = POSIXError(code)
        #expect(error.chunkyFriendlyDescription == "Impossibile raggiungere il server. Verifica di essere sulla stessa rete Wi-Fi/LAN.")
    }

    @Test("Un codice POSIX non mappato ricade sulla descrizione di sistema")
    func unmappedPOSIXErrorFallsBackToLocalizedDescription() {
        let error = POSIXError(.EACCES)
        #expect(error.chunkyFriendlyDescription == error.localizedDescription)
    }

    @Test("Host non trovato indica di controllare l'indirizzo", arguments: [
        URLError.Code.cannotFindHost, .cannotConnectToHost
    ])
    func hostUnreachable(code: URLError.Code) {
        let error = URLError(code)
        #expect(error.chunkyFriendlyDescription == "Impossibile raggiungere il server. Controlla l'indirizzo e che sia acceso.")
    }

    @Test("Timeout via URLError indica di verificare che il server sia acceso")
    func urlErrorTimedOut() {
        let error = URLError(.timedOut)
        #expect(error.chunkyFriendlyDescription == "Il server non ha risposto in tempo. Verifica che sia acceso e sulla stessa rete.")
    }

    @Test("Assenza di rete indica di verificare Wi-Fi/LAN", arguments: [
        URLError.Code.notConnectedToInternet, .networkConnectionLost
    ])
    func noNetwork(code: URLError.Code) {
        let error = URLError(code)
        #expect(error.chunkyFriendlyDescription == "Nessuna connessione di rete. Verifica il Wi-Fi/LAN.")
    }

    @Test("Un codice URLError non mappato ricade sulla descrizione di sistema")
    func unmappedURLErrorFallsBackToLocalizedDescription() {
        let error = URLError(.badURL)
        #expect(error.chunkyFriendlyDescription == error.localizedDescription)
    }

    @Test("Un errore di un tipo diverso ricade sulla descrizione di sistema")
    func unrelatedErrorTypeFallsBackToLocalizedDescription() {
        let error = RemoteBrowsingError.unauthorized
        #expect(error.chunkyFriendlyDescription == error.localizedDescription)
    }
}
