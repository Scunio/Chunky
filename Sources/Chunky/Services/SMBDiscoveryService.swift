import Foundation
import Network

/// A NAS/SMB server found on the local network via Bonjour.
struct DiscoveredSMBServer: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let host: String
}

/// Finds SMB servers on the local network via Bonjour (`_smb._tcp`). Not every NAS advertises
/// itself this way (some only speak NetBIOS/WSD) — callers must always keep manual entry
/// available alongside this, never gated behind a successful discovery.
@MainActor
final class SMBDiscoveryService: ObservableObject {
    @Published private(set) var servers: [DiscoveredSMBServer] = []

    private var browser: NWBrowser?
    /// Keyed by service name so a result that reappears on a later `browseResultsChangedHandler`
    /// firing (normal Bonjour churn) doesn't open a second connection to a server already
    /// resolved or still being resolved, and so a settled connection can be removed by name
    /// instead of accumulating here for as long as discovery runs.
    private var resolvers: [String: NWConnection] = [:]

    func start() {
        stop()

        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: "local."), using: .tcp)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in
                self.resolve(results: results)
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        servers.removeAll()
    }

    private func resolve(results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            guard resolvers[name] == nil, !servers.contains(where: { $0.name == name }) else { continue }

            let connection = NWConnection(to: result.endpoint, using: .tcp)
            resolvers[name] = connection

            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                        let hostString = Self.hostString(from: host)
                        Task { @MainActor in
                            self.addServer(name: name, host: hostString)
                            self.settle(name: name, connection: connection)
                        }
                    }
                case .failed, .cancelled:
                    Task { @MainActor in
                        self.settle(name: name, connection: connection)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    private func addServer(name: String, host: String) {
        guard !servers.contains(where: { $0.name == name }) else { return }
        servers.append(DiscoveredSMBServer(name: name, host: host))
    }

    /// Cancels and removes the entry for `name` — only if it's still the connection that
    /// registered it, so a resolve started after a `stop()`/`start()` cycle can't be torn down
    /// by a stale callback from the previous one.
    private func settle(name: String, connection: NWConnection) {
        guard resolvers[name] === connection else { return }
        connection.cancel()
        resolvers.removeValue(forKey: name)
    }

    private nonisolated static func hostString(from host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _): return name
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        @unknown default: return ""
        }
    }
}
