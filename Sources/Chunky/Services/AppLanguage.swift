import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case italian
    case english

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .italian: Locale(identifier: "it")
        case .english: Locale(identifier: "en")
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Lingua del dispositivo"
        case .italian: "Italiano"
        case .english: "English"
        }
    }
}

enum AppLocalization {
    static func localizedString(_ key: String, comment: String) -> String {
        let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "system") ?? .system

        switch language {
        case .system:
            return NSLocalizedString(key, comment: comment)
        case .italian:
            // Italian is the source language, so its localization key is the Italian text.
            return key
        case .english:
            guard let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return key
            }
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
    }
}

struct AppLanguageSettings: View {
    @AppStorage("appLanguage") private var language = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Lingua", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                #if os(iOS)
                .pickerStyle(.inline)
                #endif
            } footer: {
                Text("La lingua scelta si applica a tutte le finestre dell’app.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Lingua")
    }
}
