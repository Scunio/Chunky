import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Colori personalizzabili della libreria, persistiti come stringhe esadecimali. Un valore
/// nil/non impostato ricade sui colori di sistema (Dark/Light Mode automatico).
final class AppTheme: ObservableObject {
    static let shared = AppTheme()

    @AppStorage("theme.backgroundHex") var backgroundHex: String = ""
    @AppStorage("theme.textHex") var textHex: String = ""
    @AppStorage("theme.accentHex") var accentHex: String = ""
    @AppStorage("theme.pageTintHex") var pageTintHex: String = ""
    @AppStorage("theme.pageTintOpacity") var pageTintOpacity: Double = 0.25

    var background: Color? { Color(hex: backgroundHex) }
    var text: Color? { Color(hex: textHex) }
    var accent: Color? { Color(hex: accentHex) }
    var pageTint: Color? { Color(hex: pageTintHex) }

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
        let r = Int((components.count > 0 ? components[0] : 0) * 255)
        let g = Int((components.count > 1 ? components[1] : 0) * 255)
        let b = Int((components.count > 2 ? components[2] : 0) * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
