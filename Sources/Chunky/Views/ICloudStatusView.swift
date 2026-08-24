import SwiftUI
import CoreData

/// iCloud sync status, reachable from Settings > Advanced.
struct ICloudStatusView: View {
    var body: some View {
        Form {
            ICloudStatusSections()
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Stato iCloud")
    }
}

/// iCloud status content without its own `Form`, so it can be embedded in the "Advanced"
/// tab of Mac Preferences as well as shown standalone on iOS (`ICloudStatusView` above).
struct ICloudStatusSections: View {
    @FetchRequest(sortDescriptors: []) private var comics: FetchedResults<ComicEntity>

    private var isActive: Bool { LibraryStorage.isICloudAvailable }

    var body: some View {
        Group {
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
    }
}

#Preview {
    ICloudStatusView()
}
