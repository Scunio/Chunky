import Testing
// Niente `@testable import Chunky`: i test compilano i sorgenti direttamente
// nello stesso modulo (vedi template `ChunkyUnitTest` in project.yml).

@Suite("Permesso Rete locale")
struct LocalNetworkPermissionTests {
    @Test("Il preflight parte da stato sconosciuto")
    @MainActor
    func startsUnknown() {
        let permission = LocalNetworkPermission()
        #expect(permission.status == .unknown)
        permission.stop()
    }
}
