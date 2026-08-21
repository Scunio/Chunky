import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PageBackground: String, CaseIterable, Identifiable {
    case automatic
    case black
    case white

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatico"
        case .black: "Nero"
        case .white: "Bianco"
        }
    }
}

struct ColorThemeView: View {
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage("pageBackground") private var pageBackgroundRawValue = PageBackground.black.rawValue

    private var pageBackground: Binding<PageBackground> {
        Binding(
            get: { PageBackground(rawValue: pageBackgroundRawValue) ?? .black },
            set: { pageBackgroundRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section(
                header: Text("Modalità"),
                footer: Text("\"Automatica\" segue la modalità chiara/scura del sistema. Chiara/Scura la forzano in tutta l'app, libreria inclusa, indipendentemente dal sistema.")
            ) {
                Picker("Modalità", selection: Binding(
                    get: { theme.colorSchemeMode },
                    set: { theme.colorSchemeMode = $0 }
                )) {
                    ForEach(AppColorSchemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            // `ColorPicker`/`Slider` don't exist on tvOS, and this screen isn't reachable there
            // anyway (no tvOS Settings entry point in v1) — these two sections are iOS/macOS only.
            #if !os(tvOS)
            Section(footer: Text("Personalizza i colori della libreria. Lascia \"Automatico\" per seguire la modalità chiara/scura di sistema.")) {
                // Each row has a different fallback color when it hasn't been customized yet
                // (empty hex = "Automatic"): showing them all as .primary made them identical
                // and black, indistinguishable from one another despite representing different things.
                colorRow(title: "Sfondo", hex: $theme.backgroundHex, defaultColor: systemBackgroundColor)
                colorRow(title: "Testo", hex: $theme.textHex, defaultColor: .primary)
                colorRow(title: "Colore evidenziazione", hex: $theme.accentHex, defaultColor: .accentColor)
            }
            #endif

            Section(
                header: Text("Lettura"),
                footer: Text("Lo sfondo dietro le pagine nel lettore. \"Automatico\" segue la modalità chiara/scura di sistema.")
            ) {
                Picker("Sfondo pagina", selection: pageBackground) {
                    ForEach(PageBackground.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            }

            Section(
                header: Text("Tint pagina (lettore)"),
                footer: Text("Sovrappone una leggera tinta alle pagine mentre leggi: utile per correggere pagine ingiallite o per una modalità notte più riposante.")
            ) {
                #if !os(tvOS)
                colorRow(title: "Colore", hex: $theme.pageTintHex, defaultColor: .white)
                if !theme.pageTintHex.isEmpty {
                    HStack {
                        Text("Intensità")
                        Slider(value: $theme.pageTintOpacity, in: 0...0.6)
                    }
                }
                #endif
                HStack(spacing: 12) {
                    tintPresetButton(name: "Nessuno", hex: "")
                    tintPresetButton(name: "Seppia", hex: "#704214", opacity: 0.18)
                    tintPresetButton(name: "Notte", hex: "#0A1A2F", opacity: 0.35)
                }
            }

            Section {
                Button("Ripristina automatico", action: theme.reset)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Colori")
    }

    private func tintPresetButton(name: String, hex: String, opacity: Double = 0.25) -> some View {
        Button(action: {
            theme.pageTintHex = hex
            theme.pageTintOpacity = opacity
        }) {
            Text(name)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }

    #if !os(tvOS)
    private func colorRow(title: String, hex: Binding<String>, defaultColor: Color) -> some View {
        let binding = Binding<Color>(
            get: { Color(hex: hex.wrappedValue) ?? defaultColor },
            set: { hex.wrappedValue = $0.hexString }
        )
        return HStack {
            ColorPicker(title, selection: binding)
            if !hex.wrappedValue.isEmpty {
                Button(action: { hex.wrappedValue = "" }) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    /// System color for the background, as a fallback when "Background" hasn't been customized yet
    /// (empty hex = "Automatic"). It's not the same `.primary` used for "Text": showing the
    /// same value for rows that represent different things is what made them indistinguishable.
    private var systemBackgroundColor: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }
    #endif
}
