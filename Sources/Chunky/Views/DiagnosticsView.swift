import SwiftUI
import CoreData

struct DiagnosticsView: View {
    var body: some View {
        Form {
            DiagnosticsSections()
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Diagnostica")
    }
}

/// Diagnostics content without its own `Form`, so it can be embedded in the "Advanced"
/// tab of Mac Preferences as well as shown standalone on iOS (`DiagnosticsView` above).
struct DiagnosticsSections: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var viewModel: LibraryViewModel
    @State private var logText = DiagnosticLog.readAll()

    var body: some View {
        Group {
            Section(
                header: Text("Libreria"),
                footer: Text("Rimuove i fumetti i cui file non esistono più e ritrova quelli presenti nella cartella della libreria ma non registrati (utile dopo un ripristino da backup).")
            ) {
                Button(action: { viewModel.rebuildLibrary(context: context) }) {
                    Label("Ricostruisci libreria", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(viewModel.isImporting)
            }

            Section(header: Text("Log")) {
                ScrollView {
                    Text(logText.isEmpty ? "Nessun log ancora." : logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 240)

                Button("Aggiorna", action: refresh)
                Button("Svuota log", action: clear)
                    .foregroundColor(.red)
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        logText = DiagnosticLog.readAll()
    }

    private func clear() {
        DiagnosticLog.clear()
        logText = ""
    }
}

#Preview {
    DiagnosticsView()
}
