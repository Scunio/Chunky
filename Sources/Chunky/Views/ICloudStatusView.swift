import CloudKit
import CoreData
import SwiftUI

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
    @Environment(\.managedObjectContext) private var context
    /// Count only: materializing every `ComicEntity` via `@FetchRequest` just to show
    /// the total stalled opening this panel on large libraries.
    @State private var comicsCount = 0
    /// `nil` while loading or when the build can't query CloudKit (no entitlement).
    @State private var cloudKitStatus: CKAccountStatus?
    @State private var hasLoadedCloudKitStatus = false

    private var isActive: Bool { LibraryStorage.isICloudAvailable }

    /// iCloud Drive (files) and CloudKit (library records, progress) are separate switches:
    /// Drive can be on while the CloudKit account is restricted or signed out, which is
    /// exactly the "files arrive but progress never does" case worth showing here.
    private var cloudKitStatusText: LocalizedStringKey {
        guard hasLoadedCloudKitStatus else { return "Verifica in corso…" }
        switch cloudKitStatus {
        case .available: return "Disponibile"
        case .noAccount: return "Nessun account iCloud"
        case .restricted: return "Con restrizioni"
        case .temporarilyUnavailable: return "Temporaneamente non disponibile"
        default: return "Non determinabile"
        }
    }

    var body: some View {
        Group {
            Section {
                Label(
                    isActive ? "iCloud Drive attivo" : "iCloud Drive non disponibile",
                    systemImage: isActive ? "checkmark.icloud" : "xmark.icloud"
                )
                .foregroundColor(isActive ? .primary : .secondary)
                HStack {
                    Text("Sincronizzazione CloudKit")
                    Spacer()
                    Text(cloudKitStatusText)
                        .foregroundColor(cloudKitStatus == .available || !hasLoadedCloudKitStatus ? .secondary : .orange)
                }
                HStack {
                    Text("Fumetti nella libreria")
                    Spacer()
                    Text("\(comicsCount)")
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
            Section(
                footer: Text("Invia subito i progressi di lettura di questo dispositivo e scarica quelli degli altri.")
            ) {
                Button("Sincronizza ora") {
                    RemoteProgressSync.flushPush()
                    RemoteProgressSync.fetchAndApply(in: context, force: true)
                }
            }
        }
        .onAppear {
            refreshCount()
            RemoteProgressSync.fetchAccountStatus { status in
                cloudKitStatus = status
                hasLoadedCloudKitStatus = true
            }
        }
    }

    private func refreshCount() {
        comicsCount = (try? context.count(for: ComicEntity.fetchRequest())) ?? 0
    }
}

#Preview {
    ICloudStatusView()
}
