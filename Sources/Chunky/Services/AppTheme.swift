import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Light/dark mode for the whole app (library + reader). "Automatic" follows the system
/// setting; the other two force it regardless of the system.
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

    /// Value to pass to `.preferredColorScheme`: nil lets the system decide.
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Customizable library colors, persisted as hex strings. A nil/unset value
/// falls back to system colors (automatic Dark/Light Mode).
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

    /// Approximate hex representation, used to save the color chosen from a ColorPicker.
    var hexString: String {
        #if os(iOS) || os(tvOS)
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
