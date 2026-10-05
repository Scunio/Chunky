import SwiftUI
import CoreData
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
                        .textSelectableCompat()
                }
                .frame(height: 240)

                Button("Aggiorna", action: refresh)
                #if !os(tvOS)
                Button(action: copyLog) {
                    Label("Copia log", systemImage: "doc.on.doc")
                }
                .disabled(logText.isEmpty)
                if #available(iOS 16, macOS 13, *) {
                    ShareLink(item: logText.isEmpty ? "Nessun log." : logText, preview: SharePreview("chunky-log.txt"))
                        .disabled(logText.isEmpty)
                }
                #endif
                Button("Svuota log", action: clear)
                    .foregroundColor(.red)
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        logText = DiagnosticLog.readAll()
    }

    /// Copia negli appunti di sistema (best practice per target vecchi: ShareLink
    /// richiede iOS 16+, la copia funziona ovunque e basta per incollare in chat).
    private func copyLog() {
        let text = logText.isEmpty ? "Nessun log." : logText
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    private func clear() {
        DiagnosticLog.clear()
        logText = ""
    }
}

#Preview {
    DiagnosticsView()
}

/// `.textSelection(.enabled)` esiste solo da iOS 15 / macOS 12: questo wrapper lo
/// applica dove disponibile e non fa nulla sul target minimo (iOS 14) così il
/// progetto compila ovunque; lì resta il tasto Copia.
private extension View {
    @ViewBuilder
    func textSelectableCompat() -> some View {
        #if os(tvOS)
        self
        #else
        if #available(iOS 15, macOS 12, *) {
            self.textSelection(.enabled)
        } else {
            self
        }
        #endif
    }
}
