import Foundation

/// Sessioni HTTP per i client remoti (WebDAV, OPDS, download file). Tre cose che
/// `URLSession.shared` non dà:
/// - timeout espliciti (30s per risposta, 300s per risorsa): senza, un NAS
///   appeso lascia il task in attesa a tempo indeterminato;
/// - `waitsForConnectivity`: aspetta che la rete torni (o che l'utente risponda
///   al prompt "Rete locale") invece di fallire subito;
/// - risposta alle sfide di autenticazione HTTP: l'header Basic preimpostato da
///   `authenticatedRequest` resta com'è (zero round-trip in più per i server
///   Basic), ma se il server risponde 401 chiedendo Digest/NTLM/Negotiate il
///   delegate fornisce le credenziali dell'account invece di arrendersi.
///
/// La sessione è effimera per operazione e trattenuta in vita finché il task
/// non completa: una `URLSession` deallocata cancella i suoi task.
enum RemoteSession {
    private static let lock = NSLock()
    private static var liveSessions = Set<URLSession>()

    /// Username/password come valori semplici, letti dal chiamante in modo
    /// sincrono prima del primo `await` (stesso pattern dei client: l'account è
    /// confinato al main context e non va toccato dopo una sospensione).
    static func data(for request: URLRequest, username: String?, password: String?) async throws -> (Data, URLResponse) {
        let session = makeSession(username: username, password: password)
        do {
            let result = try await session.data(for: request)
            release(session)
            return result
        } catch {
            release(session)
            throw error
        }
    }

    /// Come sopra ma restituisce il task senza avviarlo: serve a
    /// `RemoteBrowsing.downloadFile`, che deve registrare il task nel
    /// `DownloadManager` prima di `resume()`. Il chiamante deve avviarlo.
    static func downloadTask(
        with request: URLRequest,
        username: String?,
        password: String?,
        completionHandler: @escaping (URL?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionDownloadTask {
        let session = makeSession(username: username, password: password)
        let task = session.downloadTask(with: request) { url, response, error in
            release(session)
            completionHandler(url, response, error)
        }
        return task
    }

    private static func makeSession(username: String?, password: String?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        let session = URLSession(
            configuration: config,
            delegate: CredentialDelegate(username: username, password: password),
            delegateQueue: nil
        )
        retain(session)
        return session
    }

    private static func retain(_ session: URLSession) {
        lock.lock()
        liveSessions.insert(session)
        lock.unlock()
    }

    private static func release(_ session: URLSession) {
        lock.lock()
        liveSessions.remove(session)
        lock.unlock()
    }
}

/// Risponde alle sfide di autenticazione HTTP con le credenziali dell'account.
/// Solo schemi HTTP (Basic/Digest/NTLM/Negotiate): mai `serverTrust` o client
/// certificate — quelli restano al comportamento di sistema, altrimenti si
/// aprirebbe a intercettazioni.
private final class CredentialDelegate: NSObject, URLSessionTaskDelegate {
    private let credential: URLCredential?

    init(username: String?, password: String?) {
        if let username = username, !username.isEmpty {
            credential = URLCredential(
                user: username,
                password: password ?? "",
                persistence: .none
            )
        } else {
            credential = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        let isHTTPAuth = method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodNTLM
            || method == NSURLAuthenticationMethodNegotiate
        guard isHTTPAuth, challenge.previousFailureCount == 0, let credential else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, credential)
    }
}
