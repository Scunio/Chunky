import Foundation

/// Una voce nella navigazione di un account remoto: una cartella da aprire oppure
/// un fumetto scaricabile.
struct RemoteEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let isContainer: Bool
    let url: URL
}

/// Incapsula la continuation di `downloadFile`, collegata al completion handler del task solo
/// dopo la sua creazione (il completion handler va passato alla creazione del task, prima che
/// la continuation esista). @unchecked Sendable: viene scritta una sola volta prima di
/// `task.resume()` e letta solo dal completion handler del task, che URLSession garantisce
/// invocare al più una volta — nessun accesso concorrente reale nonostante il tipo non lo dimostri al compilatore.
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
    /// Elenca il contenuto di una cartella/collezione remota. `url` è la root dell'account
    /// alla prima chiamata, o l'URL di una sottocartella restituito da una entry precedente.
    func listEntries(at url: URL, account: RemoteAccountEntity) async throws -> [RemoteEntry]

    /// Scarica un fumetto in locale, restituendo l'URL temporaneo del file scaricato.
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

    /// Scarica il contenuto di `url` in un file temporaneo, propagando le credenziali dell'account.
    /// Usa l'API a completion-handler (non quella async di URLSession, disponibile solo da iOS15/macOS12)
    /// per restare compatibili con il target minimo dell'app (iOS14/macOS11).
    func downloadFile(from url: URL, account: RemoteAccountEntity, suggestedName: String) async throws -> URL {
        let request = authenticatedRequest(for: url, account: account)
        let holder = ContinuationHolder()

        let task = URLSession.shared.downloadTask(with: request) { location, response, error in
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
            // Il file a `location` viene eliminato subito dopo il ritorno del completion handler:
            // lo spostiamo sincronamente prima di risolvere la continuation.
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

enum RemoteBrowsingFactory {
    static func makeBrowser(for kind: RemoteAccountKind) -> RemoteBrowsing {
        switch kind {
        case .opds: return OPDSClient()
        case .webdav: return WebDAVClient()
        }
    }
}
