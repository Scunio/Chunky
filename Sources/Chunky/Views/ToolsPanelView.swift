import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Pannello "Tools" condiviso da libreria e reader (icona chiave inglese): un vero elenco con
/// navigazione — non un Menu a tendina, che su questo target non riesce a spingere le
/// NavigationLink al suo interno (verificato dal vivo: il tap non naviga da nessuna parte).
struct ToolsPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var brightness: Double = ToolsPanelView.currentBrightness()

    var body: some View {
        NavigationView {
            List {
                #if os(iOS)
                Section {
                    HStack {
                        Image(systemName: "sun.min")
                            .foregroundColor(.secondary)
                        Slider(value: $brightness, in: 0...1)
                            .onChange(of: brightness) { UIScreen.current?.brightness = CGFloat(brightness) }
                        Image(systemName: "sun.max.fill")
                            .foregroundColor(.secondary)
                    }
                }
                #endif

                Section {
                    NavigationLink("Colori", destination: ColorThemeView())
                    NavigationLink("Impostazioni", destination: SettingsView())
                    NavigationLink("Blocco genitori", destination: ParentalLockSettingsView())
                }

                Section {
                    Button(action: sendFeedbackEmail) {
                        HStack {
                            Text("Feedback / Segnala un problema")
                            Spacer()
                            Image(systemName: "envelope")
                        }
                    }
                    .foregroundColor(.primary)
                }

                Section {
                    NavigationLink("Informazioni", destination: AboutView())
                }
            }
            .navigationTitle("Tools")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fatto") { dismiss() }
                }
            }
        }
        .sheetSized()
    }

    private func sendFeedbackEmail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "support@scunio.com"
        components.queryItems = [URLQueryItem(name: "subject", value: "Chunky – Feedback")]
        guard let url = components.url else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    private static func currentBrightness() -> Double {
        #if os(iOS)
        Double(UIScreen.current?.brightness ?? 1)
        #else
        1
        #endif
    }
}
