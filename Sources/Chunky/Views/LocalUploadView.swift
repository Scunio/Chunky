import SwiftUI
import CoreData
#if os(tvOS)
import CoreImage.CIFilterBuiltins
#endif

struct LocalUploadView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var viewModel: LibraryViewModel
    #if os(tvOS)
    // Shared, not owned by this screen: on tvOS switching tab (or pressing Menu) runs
    // `onDisappear`/tears down a `@StateObject`, which stopped the server mid-upload while
    // the user was simply looking at another tab. It now stays up until switched off here.
    @ObservedObject private var server = LocalUploadServer.tvOSShared
    @Environment(\.dismiss) private var dismiss
    #else
    @StateObject private var server = LocalUploadServer()
    #endif

    var body: some View {
        #if os(tvOS)
        // Title in the layout like `DownloadsView`: `.navigationTitle` overlays a fixed screen
        // position on tvOS, and Menu needs an explicit pop (pushed from a hidden-nav-bar
        // `NavigationStack`, so it would otherwise exit the whole app).
        TVPanel(title: "Upload dalla rete") {
            EmptyView()
        } content: {
            form
        }
        .navigationTitle("")
        .onExitCommand { dismiss() }
        .onAppear {
            server.onFileReceived = { url in
                viewModel.importFiles([url], into: context, cleaningTemporaryDirectories: [url.deletingLastPathComponent()])
            }
        }
        #else
        form
            .tvOSListFocusFix()
            .navigationTitle("Upload dalla rete")
            .onAppear {
                server.onFileReceived = { url in
                    viewModel.importFiles([url], into: context, cleaningTemporaryDirectories: [url.deletingLastPathComponent()])
                }
            }
            .onDisappear {
                server.stop()
            }
        #endif
    }

    private var form: some View {
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
                        #if os(tvOS)
                        // Typing an IP address on a phone is the step people get wrong:
                        // scanning it with the camera opens the upload page directly.
                        if let qrImage = Self.qrCode(for: "http://\(address):8281") {
                            HStack {
                                Image(uiImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 240, height: 240)
                                    .accessibilityLabel(Text("Codice QR dell'indirizzo"))
                                Text("Inquadra il codice con la fotocamera di un telefono sulla stessa rete per aprire la pagina di caricamento.")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 24)
                            }
                            .padding(.vertical, 12)
                        }
                        #endif
                    }
                    #if os(tvOS)
                    Text("Il server resta attivo anche se cambi scheda, finché non lo spegni qui.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    #endif
                }

                if let error = server.lastError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    #if os(tvOS)
    private static func qrCode(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #endif
}

#Preview {
    let controller = PersistenceController(inMemory: true)
    return LocalUploadView()
        .environment(\.managedObjectContext, controller.container.viewContext)
        .environmentObject(LibraryViewModel())
}
