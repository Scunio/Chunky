import SwiftUI
import CoreData

/// Stato sincronizzazione iCloud, raggiungibile da Impostazioni > Avanzate.
struct ICloudStatusView: View {
    @FetchRequest(sortDescriptors: []) private var comics: FetchedResults<ComicEntity>

    private var isActive: Bool { LibraryStorage.isICloudAvailable }

    var body: some View {
        Form {
            Section {
                Label(
                    isActive ? "iCloud Drive attivo" : "iCloud Drive non disponibile",
                    systemImage: isActive ? "checkmark.icloud" : "xmark.icloud"
                )
                .foregroundColor(isActive ? .primary : .secondary)
                HStack {
                    Text("Fumetti nella libreria")
                    Spacer()
                    Text("\(comics.count)")
                        .foregroundColor(.secondary)
                }
            }
            Section(
                footer: Text(
                    isActive
                        ? "I fumetti importati vengono salvati nel container iCloud dell'app e sincronizzati automaticamente su tutti i tuoi dispositivi."
                        : "Attiva iCloud Drive nelle Impostazioni di sistema per sincronizzare la libreria tra i tuoi dispositivi. I fumetti restano comunque salvati localmente su questo dispositivo."
                )
            ) { EmptyView() }
        }
        .navigationTitle("Stato iCloud")
    }
}
