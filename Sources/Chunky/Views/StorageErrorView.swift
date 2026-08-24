import SwiftUI

struct StorageErrorView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView {
            Label("Impossibile aprire la libreria", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text("Si è verificato un problema con l'archivio dati locale. Prova a riavviare l'app; se il problema persiste, la libreria potrebbe dover essere ricreata.")
                + Text("\n\n")
                + Text(error.localizedDescription).font(.caption)
        }
    }
}

#Preview {
    StorageErrorView(error: NSError(domain: "com.scunio.chunky", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Impossibile aprire lo store persistente."
    ]))
}
