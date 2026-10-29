import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case italian
    case english
    case spanish
    case german
    case french
    case dutch
    case portuguese

    var id: String { rawValue }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "system") ?? .system
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .italian: Locale(identifier: "it")
        case .english: Locale(identifier: "en")
        case .spanish: Locale(identifier: "es")
        case .german: Locale(identifier: "de")
        case .french: Locale(identifier: "fr")
        case .dutch: Locale(identifier: "nl")
        case .portuguese: Locale(identifier: "pt")
        }
    }

    var languageCode: String {
        switch self {
        case .system:
            Locale.autoupdatingCurrent.identifier
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first
                .map(String.init) ?? "en"
        case .italian: "it"
        case .english: "en"
        case .spanish: "es"
        case .german: "de"
        case .french: "fr"
        case .dutch: "nl"
        case .portuguese: "pt"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Lingua del dispositivo"
        case .italian: "Italiano"
        case .english: "English"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .french: "Français"
        case .dutch: "Nederlands"
        case .portuguese: "Português"
        }
    }
}

enum AppLocalization {
    static func plural(_ count: Int, singularKey: String, pluralKey: String, comment: String) -> String {
        format(count == 1 ? singularKey : pluralKey, comment: comment, arguments: [count])
    }

    static func format(_ key: String, comment: String, arguments: [CVarArg]) -> String {
        let format = localizedString(key, comment: comment)
        return String(format: format, locale: AppLanguage.current.locale, arguments: arguments)
    }

    static func userFacingError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return localizedString("Download annullato.", comment: "Operation cancelled")
            case .timedOut:
                return localizedString("Il server non ha risposto in tempo. Verifica che sia acceso e sulla stessa rete.", comment: "Network connection error")
            case .notConnectedToInternet, .networkConnectionLost:
                return localizedString("Nessuna connessione di rete. Verifica il Wi-Fi/LAN.", comment: "Network connection error")
            case .cannotFindHost, .cannotConnectToHost:
                return localizedString("Impossibile raggiungere il server. Controlla l'indirizzo e che sia acceso.", comment: "Network connection error")
            default:
                return localizedString("Operazione non riuscita. Riprova.", comment: "Generic operation error")
            }
        }

        if let posixError = error as? POSIXError {
            switch posixError.code {
            case .EACCES, .EPERM:
                return localizedString("Accesso negato. Controlla i permessi e riprova.", comment: "File or server access denied")
            case .ENOSPC:
                return localizedString("Spazio di archiviazione insufficiente.", comment: "Storage is full")
            case .ENOENT:
                return localizedString("Il file non è più disponibile.", comment: "File is missing")
            case .EADDRINUSE:
                return localizedString("Impossibile avviare il server locale: la porta è già in uso.", comment: "Local server port is already in use")
            default:
                return localizedString("Operazione non riuscita. Riprova.", comment: "Generic operation error")
            }
        }

        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return localizedString("Operazione non riuscita. Riprova.", comment: "Generic operation error")
    }

    static func localizedString(_ key: String, comment: String) -> String {
        let language = AppLanguage.current

        switch language {
        case .system:
            return NSLocalizedString(key, comment: comment)
        case .italian:
            // Italian is the source language, so its localization key is the Italian text.
            return key
        case .english, .spanish, .german, .french, .dutch, .portuguese:
            guard let path = Bundle.main.path(forResource: language.languageCode, ofType: "lproj"),
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
                Picker(selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                } label: {
                    EmptyView()
                }
                #if os(iOS)
                .pickerStyle(.inline)
                #endif
                .labelsHidden()
            } footer: {
                Text("La lingua scelta si applica ai testi di Chunky. Le schermate e gli avvisi di sistema, incluse le richieste di autorizzazione, seguono la lingua impostata in iOS o macOS.")
            }
        }
        .formStyle(.grouped)
        // Resolve this title from the app's selected language. Navigation containers can
        // retain a LocalizedStringKey's original value after the locale changes while the
        // screen is open, even though the form contents refresh correctly.
        .navigationTitle(AppLocalization.localizedString("Lingua", comment: "Language settings screen title"))
    }
}
