import Foundation
import Network

/// Stato del permesso privacy "Rete locale" (iOS/tvOS).
enum LocalNetworkStatus: Equatable {
    case unknown
    case granted
    case denied
}

/// Rileva lo stato del permesso "Rete locale" e, se è ancora indeciso, fa
/// comparire il prompt di sistema — non esiste un'API per chiederlo in modo
/// esplicito, il sistema mostra l'alert da solo alla prima operazione di rete
/// locale (TN3179). Per questo il controllo va lanciato nel momento in cui
/// serve davvero (apertura del form SMB), non all'avvio dell'app.
///
/// Usa un `NWBrowser` per `_smb._tcp` (già dichiarato in `NSBonjourServices`,
/// lo stesso della scoperta NAS): non genera traffico e non interferisce con
/// la `SMBDiscoveryService` già in corso.
@MainActor
final class LocalNetworkPermission: ObservableObject {
    @Published private(set) var status: LocalNetworkStatus = .unknown

    private var browser: NWBrowser?
    private var confirmTask: Task<Void, Never>?

    /// Avvia il controllo. Se il permesso è indeciso, iOS/tvOS mostra qui il
    /// prompt di sistema; l'esito arriva negli handler e aggiorna `status`.
    /// Chiamate ripetute mentre è già in corso sono ignorate.
    func check() {
        guard browser == nil else { return }
        status = .unknown
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: "local."), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in self.handle(state: state) }
        }
        browser.browseResultsChangedHandler = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.settled(.granted) }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        confirmTask?.cancel()
        confirmTask = nil
    }

    private func handle(state: NWBrowser.State) {
        switch state {
        case .ready:
            // `.ready` scatta anche prima che l'utente risponda al prompt —
            // conferma in ritardo, così un `PolicyDenied` arrivato dopo può
            // ancora annullarla e non si mostra un falso "concesso".
            confirmTask?.cancel()
            confirmTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                if self.status == .unknown { self.settled(.granted) }
            }
        case .waiting(let error), .failed(let error):
            if isPolicyDenied(error) {
                confirmTask?.cancel()
                settled(.denied)
            }
        default:
            break
        }
    }

    private func settled(_ status: LocalNetworkStatus) {
        self.status = status
        if status != .unknown {
            browser?.cancel()
            browser = nil
        }
    }

    /// `kDNSServiceErr_PolicyDenied` (-65570): il sistema nega l'accesso alla
    /// rete locale a questa app (TN3179). Confronto sul valore grezzo per non
    /// tirare dentro altri framework oltre Network.
    private func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == -65570
        }
        return false
    }
}
