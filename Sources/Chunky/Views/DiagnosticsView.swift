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
    /// Tail shown on screen: laying out the full (up to 512KB) log as one `Text`
    /// stalled opening and scrolling the panel. Copy/Share still use the full log.
    @State private var logText = DiagnosticLog.tail()
    @State private var fullLogText = DiagnosticLog.readAll()
    @State private var isTruncated = false
    @State private var didCopy = false

    var body: some View {
        Group {
            Section(
                header: Text("Libreria"),
                footer: Text("Rimuove i fumetti i cui file non esistono più e ritrova quelli presenti nella cartella della libreria ma non registrati (utile dopo un ripristino da backup).")
            ) {
                // Mai disabilitato durante gli import: il rebuild va in coda seriale
                // con gli altri lavori e parte da solo; disabilitarlo lo faceva
                // sembrare morto proprio mentre serviva (es. pre-cache in corso).
                // Il banner di stato conferma il tap anche se parte dopo.
                Button(action: { viewModel.rebuildLibrary(context: context) }) {
                    Label("Ricostruisci libreria", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Section(header: Text("Log")) {
                // ScrollView ripristinata: senza, su iPhone la coda non si scorre più.
                // Resta leggera perché mostra solo la coda (300 righe), non il file intero.
                ScrollView {
                    Text(logText.isEmpty ? "Nessun log ancora." : logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelectableCompat()
                }
                .frame(height: 240)
                if isTruncated {
                    Text("Mostrate le ultime righe — Copia o Condividi per il log completo.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Aggiorna", action: refresh)
                #if !os(tvOS)
                Button(action: copyLog) {
                    Label(didCopy ? "Copiato!" : "Copia log", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .disabled(fullLogText.isEmpty)
                if #available(iOS 16, macOS 13, *) {
                    ShareLink(item: fullLogText.isEmpty ? "Nessun log." : fullLogText, preview: SharePreview("chunky-log.txt"))
                        .disabled(fullLogText.isEmpty)
                }
                #endif
                Button("Svuota log", action: clear)
                    .foregroundColor(.red)
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        fullLogText = DiagnosticLog.readAll()
        logText = DiagnosticLog.tail(from: fullLogText)
        isTruncated = !fullLogText.isEmpty && logText.count < fullLogText.count
        didCopy = false
    }

    /// Copia negli appunti di sistema (best practice per target vecchi: ShareLink
    /// richiede iOS 16+, la copia funziona ovunque).
    private func copyLog() {
        let text = fullLogText.isEmpty ? "Nessun log." : fullLogText
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
        didCopy = true
    }

    private func clear() {
        DiagnosticLog.clear()
        logText = ""
        fullLogText = ""
        isTruncated = false
        didCopy = false
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
