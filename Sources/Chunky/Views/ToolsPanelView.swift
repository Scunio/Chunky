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
