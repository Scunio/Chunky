import SwiftUI
import CoreData

struct LocalUploadView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var viewModel: LibraryViewModel
    @StateObject private var server = LocalUploadServer()
    #if os(tvOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        Form {
            Section(
                header: Text("Server locale"),
                footer: Text("Con il server attivo, apri l'indirizzo qui sotto da un browser su un computer collegato alla stessa rete Wi-Fi per caricare fumetti direttamente nella libreria.")
            ) {
                Toggle("Server attivo", isOn: Binding(
                    get: { server.isRunning },
                    set: { isOn in isOn ? server.start() : server.stop() }
                ))

                if server.isRunning {
                    ForEach(LocalUploadServer.localIPAddresses(), id: \.self) { address in
                        HStack {
                            Text("http://\(address):8281")
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                        }
                    }
                }

                if let error = server.lastError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
        }
        .tvOSListFocusFix()
        .navigationTitle("Upload dalla rete")
        #if os(tvOS)
        // Same missing-affordance fix as `DownloadsView` — pushed from the Account tab's
        // hidden-nav-bar `NavigationStack` root, so Menu would otherwise exit the whole app
        // instead of popping back to the Account list.
        .onExitCommand { dismiss() }
        #endif
        .onAppear {
            server.onFileReceived = { url in
                viewModel.importFiles([url], into: context)
            }
        }
        .onDisappear {
            server.stop()
        }
    }
}

#Preview {
    let controller = PersistenceController(inMemory: true)
    return LocalUploadView()
        .environment(\.managedObjectContext, controller.container.viewContext)
        .environmentObject(LibraryViewModel())
}
