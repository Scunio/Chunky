import SwiftUI

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
                colorRow(title: "Sfondo", hex: $theme.backgroundHex)
                colorRow(title: "Testo", hex: $theme.textHex)
                colorRow(title: "Colore evidenziazione", hex: $theme.accentHex)
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
                colorRow(title: "Colore", hex: $theme.pageTintHex)
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

    private func colorRow(title: String, hex: Binding<String>) -> some View {
        let binding = Binding<Color>(
            get: { Color(hex: hex.wrappedValue) ?? .primary },
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
}
