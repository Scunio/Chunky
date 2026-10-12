import SwiftUI

/// Schermata bloccante quando lo store non si apre. Oltre al messaggio mostra il dettaglio
/// tecnico (dominio, codice, userInfo troncato): è l'unico dato che distingue un timeout di rete
/// da una migrazione fallita, e senza store le Impostazioni con la Diagnostica sono irraggiungibili.
/// "Riprova" ricrea il `PersistenceController` senza rilanciare l'app; "Condividi log" allega il
/// file diagnostico per l'assistenza.
struct StorageErrorView: View {
    let error: Error
    let onRetry: () -> Void

    @State private var isRetrying = false

    var body: some View {
        ContentUnavailableView {
            Label("Impossibile aprire la libreria", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text("Si è verificato un problema con l'archivio dati locale. Prova a toccare Riprova (spesso basta, se era la rete); se il problema persiste, condividi il log per l'assistenza: la libreria potrebbe dover essere ricreata.")
            Text(detailsText)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } actions: {
            if isRetrying {
                ProgressView("Riprovo…")
            } else {
                Button("Riprova") {
                    isRetrying = true
                    // Il caricamento è bloccante (fino al timeout di 20s): fuori dal main, poi si
                    // torna per riassegnare il controller e far rivalutare la schermata.
                    DispatchQueue.global(qos: .userInitiated).async {
                        PersistenceController.resetShared()
                        DispatchQueue.main.async {
                            onRetry()
                            isRetrying = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            if let logURL = DiagnosticLog.logFileURLForSharing {
                ShareLink(item: logURL, subject: Text("Chunky log diagnostico"), message: Text(detailsText)) {
                    Label("Condividi log", systemImage: "square.and.arrow.up")
                }
            }
        }
        .padding()
    }

    /// Dominio + codice + userInfo (troncato): `localizedDescription` da sola è generica
    /// ("A Core Data error occurred") e non distingue timeout da migrazione fallita.
    private var detailsText: String {
        let ns = error as NSError
        let userInfo = String(describing: ns.userInfo)
        return "\(ns.domain) (\(ns.code))\n\(ns.localizedDescription)\n\(userInfo.prefix(2000))"
    }
}

#Preview {
    StorageErrorView(error: NSError(domain: "com.scunio.chunky", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Impossibile aprire lo store persistente."
    ])) {}
}
