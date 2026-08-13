import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Modalità chiara/scura dell'intera app (libreria + lettore). "Automatica" segue l'impostazione
/// di sistema; le altre due la forzano indipendentemente dal sistema.
enum AppColorSchemeMode: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatica"
        case .light: "Chiara"
        case .dark: "Scura"
        }
    }

    /// Valore da passare a `.preferredColorScheme`: nil lascia decidere al sistema.
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Colori personalizzabili della libreria, persistiti come stringhe esadecimali. Un valore
/// nil/non impostato ricade sui colori di sistema (Dark/Light Mode automatico).
final class AppTheme: ObservableObject {
    static let shared = AppTheme()

    @AppStorage("theme.backgroundHex") var backgroundHex: String = ""
    @AppStorage("theme.textHex") var textHex: String = ""
    @AppStorage("theme.accentHex") var accentHex: String = ""
    @AppStorage("theme.pageTintHex") var pageTintHex: String = ""
    @AppStorage("theme.pageTintOpacity") var pageTintOpacity: Double = 0.25
    @AppStorage("theme.colorSchemeMode") var colorSchemeModeRawValue: String = AppColorSchemeMode.automatic.rawValue

    var background: Color? { Color(hex: backgroundHex) }
    var text: Color? { Color(hex: textHex) }
    var accent: Color? { Color(hex: accentHex) }
    var pageTint: Color? { Color(hex: pageTintHex) }

    var colorSchemeMode: AppColorSchemeMode {
        get { AppColorSchemeMode(rawValue: colorSchemeModeRawValue) ?? .automatic }
        set { colorSchemeModeRawValue = newValue.rawValue }
    }

    func reset() {
        backgroundHex = ""
        textHex = ""
        accentHex = ""
    }
}

extension Color {
    init?(hex: String) {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt64(trimmed, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }

    /// Rappresentazione esadecimale approssimata, usata per salvare il colore scelto da un ColorPicker.
    var hexString: String {
        #if os(iOS)
        let components = UIColor(self).cgColor.components ?? [0, 0, 0]
        #elseif os(macOS)
        let components = NSColor(self).usingColorSpace(.deviceRGB)?.cgColor.components ?? [0, 0, 0]
        #endif
        let r = Int((components.isEmpty ? 0 : components[0]) * 255)
        let g = Int((components.count > 1 ? components[1] : 0) * 255)
        let b = Int((components.count > 2 ? components[2] : 0) * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
