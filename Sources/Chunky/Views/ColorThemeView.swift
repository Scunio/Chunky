import SwiftUI
#if os(iOS)
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

            Section(footer: Text("Personalizza i colori della libreria. Lascia \"Automatico\" per seguire la modalità chiara/scura di sistema.")) {
                // Ogni riga ha un colore di ripiego diverso quando non è ancora personalizzata
                // (hex vuoto = "Automatico"): mostrarli tutti come .primary li rendeva identici
                // e neri, indistinguibili l'uno dall'altro nonostante rappresentino cose diverse.
                colorRow(title: "Sfondo", hex: $theme.backgroundHex, defaultColor: systemBackgroundColor)
                colorRow(title: "Testo", hex: $theme.textHex, defaultColor: .primary)
                colorRow(title: "Colore evidenziazione", hex: $theme.accentHex, defaultColor: .accentColor)
            }

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
                colorRow(title: "Colore", hex: $theme.pageTintHex, defaultColor: .white)
                if !theme.pageTintHex.isEmpty {
                    HStack {
                        Text("Intensità")
                        Slider(value: $theme.pageTintOpacity, in: 0...0.6)
                    }
                }
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

    /// Colore di sistema per lo sfondo, come ripiego quando "Sfondo" non è ancora personalizzato
    /// (hex vuoto = "Automatico"). Non è lo stesso `.primary` usato per "Testo": mostrare lo
    /// stesso valore per righe che rappresentano cose diverse è ciò che le rendeva indistinguibili.
    private var systemBackgroundColor: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }
}
