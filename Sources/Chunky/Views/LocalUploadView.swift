import SwiftUI
import CoreData

struct LocalUploadView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var viewModel: LibraryViewModel
    @StateObject private var server = LocalUploadServer()

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
        // See `AccountsView.tvOSPanel` for why this is needed on tvOS 17.
        #if os(tvOS)
        .scrollClipDisabled(true)
        #endif
        .navigationTitle("Upload dalla rete")
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
