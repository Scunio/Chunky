import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// "Tools" panel shared by library and reader (wrench icon): a real list with
/// navigation — not a dropdown Menu, which on this target fails to push the
/// NavigationLinks inside it (verified live: the tap doesn't navigate anywhere).
struct ToolsPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var brightness: Double = ToolsPanelView.currentBrightness()

    var body: some View {
        NavigationStack {
            Form {
                #if os(iOS)
                Section("Schermo") {
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

                Section("Personalizza") {
                    NavigationLink(destination: ColorThemeView()) {
                        Label("Colori", systemImage: "paintpalette")
                    }
                    NavigationLink(destination: SettingsView()) {
                        Label("Impostazioni", systemImage: "gear")
                    }
                    NavigationLink(destination: ParentalLockSettingsView()) {
                        Label("Blocco genitori", systemImage: "lock")
                    }
                }

                Section {
                    Button(action: sendFeedbackEmail) {
                        Label("Feedback / Segnala un problema", systemImage: "envelope")
                            .foregroundColor(.primary)
                    }
                }

                Section("Info") {
                    NavigationLink(destination: AboutView()) {
                        Label("Informazioni", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Strumenti")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #elseif os(macOS)
            // Come Impostazioni: senza stile esplicito un Form su macOS resta piatto,
            // diverso dal grouped della pagina Impostazioni.
            .formStyle(.grouped)
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

#Preview {
    ToolsPanelView()
}
