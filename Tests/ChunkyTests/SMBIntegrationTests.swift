import Foundation
import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

/// Integrazione contro NAS vero, skippata in CI.
///
/// Uso locale:
/// ```
/// SMB_TEST_HOST=192.168.1.10 SMB_TEST_SHARE="Fumetti & Graphic Novel" \
/// SMB_TEST_USER=lorenzo SMB_TEST_PASS=xxx SMB_TEST_PORT=445 \
/// xcodebuild test -project Chunky.xcodeproj -scheme Chunky_macOS \
///   -destination "platform=macOS,arch=arm64" \
///   -only-testing:ChunkyTests_macOS/SMBRealServerTests
/// ```
/// Senza `SMB_TEST_HOST` i test ritornano subito (verdi, senza rete):
/// la CI non ha credenziali né NAS, quindi non deve fallire.
@Suite("SMB contro NAS reale", .serialized)
struct SMBRealServerTests {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private var host: String? {
        env["SMB_TEST_HOST"].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    @Test("Sfoglia condivisioni sul NAS reale")
    func browseRealShares() async throws {
        guard let host else { return } // skip in CI
        let port = Int32(env["SMB_TEST_PORT"] ?? "") ?? 445
        let user = env["SMB_TEST_USER"].flatMap { $0.isEmpty ? nil : $0 }
        let pass = env["SMB_TEST_PASS"].flatMap { $0.isEmpty ? nil : $0 }

        let shares = try await withTimeout(seconds: 30) {
            try await SMBClient().listShares(host: host, port: port, username: user, password: pass)
        }
        #expect(!shares.isEmpty, "il NAS non ha restituito condivisioni: credenziali o permessi?")
        if let expected = env["SMB_TEST_SHARE"], !expected.isEmpty {
            #expect(
                shares.map(\.name).contains(expected),
                "share attesa '\(expected)' assente. Trovate: \(shares.map(\.name).joined(separator: ", "))"
            )
        }
    }

    @Test("Connessione alla share reale (rileva EPERM da password errata)")
    func connectRealShare() async throws {
        guard let host else { return } // skip in CI
        guard let share = env["SMB_TEST_SHARE"], !share.isEmpty else { return } // serve la share
        let port = Int32(env["SMB_TEST_PORT"] ?? "") ?? 445
        let user = env["SMB_TEST_USER"].flatMap { $0.isEmpty ? nil : $0 }
        let pass = env["SMB_TEST_PASS"].flatMap { $0.isEmpty ? nil : $0 }

        let connection = SMBConnectionInfo(host: host, port: port, share: share, username: user, password: pass)
        do {
            _ = try await withTimeout(seconds: 60) {
                try await SMBClient().measureThroughput(for: connection)
            }
        } catch {
            // Errore utile subito: EPERM = credenziali/share, timeout = rete/NAS spento.
            Issue.record("Connessione a \(host)/\(share) fallita: \(error.chunkyFriendlyDescription) (\(error.localizedDescription))")
            throw error
        }
    }

    /// Timeout esplicito: senza, un NAS spento farebbe hangare la suite fino al
    /// timeout globale di xcodebuild invece di fallire in 30s con un messaggio chiaro.
    private func withTimeout<T: Sendable>(seconds: UInt64, _ body: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else { throw URLError(.timedOut) }
            group.cancelAll()
            return result
        }
    }
}
