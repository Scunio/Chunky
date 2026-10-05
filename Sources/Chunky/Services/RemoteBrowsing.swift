import Foundation

/// An entry in a remote account's browsing hierarchy: either a folder to open or
/// a downloadable comic.
struct RemoteEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let isContainer: Bool
    let url: URL
}

/// File extensions recognized as comics when browsing a remote account, shared by every
/// `RemoteBrowsing` implementation (WebDAV, SMB, ...).
let remoteComicExtensions: Set<String> = ["cbz", "cbr", "pdf"]

/// Wraps the continuation for `downloadFile`, connected to the task's completion handler only
/// after the task is created (the completion handler must be passed when the task is created,
/// before the continuation exists). @unchecked Sendable: it's written exactly once before
/// `task.resume()` and read only by the task's completion handler, which URLSession guarantees
/// to invoke at most once — no actual concurrent access even though the type doesn't prove it to the compiler.
private final class ContinuationHolder: @unchecked Sendable {
    var continuation: CheckedContinuation<URL, Error>?
}

enum RemoteBrowsingError: LocalizedError {
    case invalidResponse
    case parsingFailed
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Il server non ha risposto correttamente."
        case .parsingFailed: return "Impossibile interpretare la risposta del server."
        case .unauthorized: return "Credenziali non valide."
        }
    }
}

protocol RemoteBrowsing {
    /// Lists the contents of a remote folder/collection. `url` is the account's root on the
    /// first call, or the URL of a subfolder returned by a previous entry.
    func listEntries(at url: URL, account: RemoteAccountEntity) async throws -> [RemoteEntry]

    /// Downloads a comic locally, returning the temporary URL of the downloaded file.
    func download(_ entry: RemoteEntry, account: RemoteAccountEntity) async throws -> URL
}

extension RemoteBrowsing {
    func authenticatedRequest(for url: URL, account: RemoteAccountEntity) -> URLRequest {
        var request = URLRequest(url: url)
        if let username = account.username, !username.isEmpty, let password = account.password {
            let credentials = "\(username):\(password)"
            if let data = credentials.data(using: .utf8) {
                request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    /// Downloads the contents of `url` into a temporary file, propagating the account's credentials.
    /// Uses the completion-handler API (not URLSession's async one, available only from iOS15/macOS12)
    /// to stay compatible with the app's minimum target (iOS14/macOS11).
    func downloadFile(from url: URL, account: RemoteAccountEntity, suggestedName: String) async throws -> URL {
        let request = authenticatedRequest(for: url, account: account)
        let holder = ContinuationHolder()

        // Sessione condivisa: timeout, attesa connettività e auth Digest/NTLM
        // via challenge (vedi `RemoteSession`). Credenziali lette qui in modo
        // sincrono: dopo il primo `await` l'account non va più toccato.
        let task = RemoteSession.downloadTask(
            with: request,
            username: account.username,
            password: account.password
        ) { location, response, error in
            if let error = error {
                holder.continuation?.resume(throwing: error)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                holder.continuation?.resume(throwing: RemoteBrowsingError.unauthorized)
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let location = location else {
                holder.continuation?.resume(throwing: RemoteBrowsingError.invalidResponse)
                return
            }
            // The file at `location` is deleted right after the completion handler returns:
            // we move it synchronously before resolving the continuation.
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                holder.continuation?.resume(returning: destination)
            } catch {
                holder.continuation?.resume(throwing: error)
            }
        }

        let downloadItem = await MainActor.run { DownloadManager.shared.register(title: suggestedName, task: task) }

        let tempURL: URL
        do {
            tempURL = try await withCheckedThrowingContinuation { continuation in
                holder.continuation = continuation
                task.resume()
            }
        } catch {
            await MainActor.run { DownloadManager.shared.remove(downloadItem) }
            throw error
        }
        await MainActor.run { DownloadManager.shared.remove(downloadItem) }

        let finalDestination = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        try? FileManager.default.removeItem(at: finalDestination)
        try FileManager.default.moveItem(at: tempURL, to: finalDestination)
        return finalDestination
    }
}

extension Error {
    /// A plain error/errno number ("Error code 1") means nothing to someone who isn't reading
    /// source code — this maps the network failures users actually hit while adding an account
    /// (wrong host, server down, no Local Network permission) to what to check, instead of
    /// just restating the failure.
    var chunkyFriendlyDescription: String {
        if let posixError = self as? POSIXError {
            switch posixError.code {
            case .EPERM:
                // EPERM dai socket SMB diretti è AMBIGUO (TN3179): può essere il
                // blocco privacy "Rete locale" di iOS/tvOS, ma anche un rifiuto del
                // server (credenziali, diritti sulla condivisione, guest disabilitato).
                // Non affermare mai solo da qui che è la privacy: la conferma arriva
                // solo dal preflight `LocalNetworkPermission` (PolicyDenied -65570).
                // Il testo cita entrambe le cause così un EPERM del server non porta
                // fuori strada ("attiva Rete locale" anche se è già attiva).
                #if os(tvOS)
                return "Operazione non permessa (controlla credenziali e condivisione). Se sono giusti, apri Impostazioni → App → Chunky e attiva \"Rete locale\", poi riprova."
                #elseif os(iOS)
                return "Operazione non permessa (controlla credenziali e condivisione). Se sono giusti, apri Impostazioni → Privacy e sicurezza → Rete locale e attiva Chunky, poi riprova."
                #elseif os(macOS)
                return "Operazione non permessa (controlla credenziali e condivisione). Se sono giusti, apri Impostazioni di Sistema → Privacy e sicurezza → Rete locale e attiva Chunky, poi riprova."
                #else
                return "Operazione non permessa (controlla credenziali e condivisione). Se sono giusti, attiva l'accesso alla rete locale per Chunky nelle impostazioni, poi riprova."
                #endif
            case .ETIMEDOUT:
                return "Il server non ha risposto in tempo. Verifica che sia acceso e sulla stessa rete."
            case .ECONNREFUSED:
                return "Il server ha rifiutato la connessione. Controlla indirizzo e porta."
            case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN:
                return "Impossibile raggiungere il server. Verifica di essere sulla stessa rete Wi-Fi/LAN."
            default:
                break
            }
        }
        if let urlError = self as? URLError {
            switch urlError.code {
            case .cannotFindHost, .cannotConnectToHost:
                return "Impossibile raggiungere il server. Controlla l'indirizzo e che sia acceso."
            case .timedOut:
                return "Il server non ha risposto in tempo. Verifica che sia acceso e sulla stessa rete."
            case .notConnectedToInternet, .networkConnectionLost:
                return "Nessuna connessione di rete. Verifica il Wi-Fi/LAN."
            default:
                break
            }
        }
        return localizedDescription
    }

    /// SOSPETTO blocco privacy "Rete locale", non conferma: EPERM dai socket SMB
    /// diretti è ambiguo (blocco di sistema OPPURE rifiuto del server). La UI deve
    /// mostrarlo come banner "Apri Impostazioni" solo se anche il preflight
    /// `LocalNetworkPermission.status == .denied` lo conferma; altrimenti mostra
    /// l'errore del server con il suggerimento secondario sulla Rete locale
    /// (vedi `chunkyFriendlyDescription`).
    var isLocalNetworkDenied: Bool {
        (self as? POSIXError)?.code == .EPERM
    }
}

enum RemoteBrowsingFactory {
    static func makeBrowser(for kind: RemoteAccountKind) -> RemoteBrowsing {
        switch kind {
        case .opds: return OPDSClient()
        case .webdav: return WebDAVClient()
        case .smb: return SMBClient()
        }
    }
}
