import SwiftUI

enum ResetToFirstPagePolicy: String, CaseIterable, Identifiable {
    case never
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "Mai"
        case .always: "Sempre"
        }
    }
}

struct SettingsView: View {
    @AppStorage("defaultReadingDirection") private var defaultReadingDirectionRawValue = ReadingDirection.leftToRight.rawValue
    @AppStorage("doublePageMode") private var isDoublePageEnabled = false
    @AppStorage("tapToTurnEnabled") private var isTapToTurnEnabled = true
    @AppStorage("oneHandedMode") private var isOneHandedModeEnabled = false
    @AppStorage("hotCornersEnabled") private var isHotCornersEnabled = false
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    @AppStorage("kioskModeEnabled") private var isKioskModeEnabled = false
    @AppStorage("twoFingerBrightnessEnabled") private var isTwoFingerBrightnessEnabled = true
    @AppStorage("resetToFirstPagePolicy") private var resetToFirstPagePolicyRawValue = ResetToFirstPagePolicy.never.rawValue
    @AppStorage("includeInBackup") private var isIncludedInBackup = true

    private var resetToFirstPagePolicy: Binding<ResetToFirstPagePolicy> {
        Binding(
            get: { ResetToFirstPagePolicy(rawValue: resetToFirstPagePolicyRawValue) ?? .never },
            set: { resetToFirstPagePolicyRawValue = $0.rawValue }
        )
    }

    private var defaultReadingDirection: Binding<ReadingDirection> {
        Binding(
            get: { ReadingDirection(rawValue: defaultReadingDirectionRawValue) ?? .leftToRight },
            set: { defaultReadingDirectionRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section(
                header: Text("Lettura"),
                footer: Text("Si applica ai nuovi fumetti importati. Puoi comunque cambiare la direzione per ogni fumetto dal lettore.")
            ) {
                Picker("Direzione predefinita", selection: defaultReadingDirection) {
                    ForEach(ReadingDirection.allCases) { direction in
                        Text(direction.label).tag(direction)
                    }
                }
                #if os(iOS)
                .pickerStyle(.inline)
                #endif
                Toggle("Doppia pagina di default", isOn: $isDoublePageEnabled)
            }

            Section(
                header: Text("Navigazione"),
                footer: Text("Con \"Modalità una mano\" le zone di tap per cambiare pagina diventano orizzontali (alto/basso) invece che laterali, più comode da raggiungere con il pollice.")
            ) {
                Toggle("Tocca per cambiare pagina", isOn: $isTapToTurnEnabled)
                Toggle("Modalità una mano", isOn: $isOneHandedModeEnabled)
                    .disabled(!isTapToTurnEnabled)
                Toggle("Hot corners", isOn: $isHotCornersEnabled)
                    .disabled(!isTapToTurnEnabled)
                #if os(iOS)
                Toggle("Luminosità con due dita", isOn: $isTwoFingerBrightnessEnabled)
                #endif
            }

            Section(header: Text("Aspetto")) {
                NavigationLink("Colori", destination: ColorThemeView())
            }

            Section(
                header: Text("Qualità immagine"),
                footer: Text("L'upscaling migliora le pagine a bassa risoluzione con un filtro di qualità superiore al semplice ridimensionamento. Il ritaglio bordi rimuove automaticamente i margini bianchi delle scansioni.")
            ) {
                Toggle("Ritaglia bordi bianchi", isOn: $isAutoCropEnabled)
                Toggle("Auto tint & contrasto", isOn: $isAutoTintContrastEnabled)
                Toggle("Upscaling pagine a bassa risoluzione", isOn: $isUpscalingEnabled)
            }

            Section(
                header: Text("Lettura completata"),
                footer: Text("Decide se un fumetto già terminato riparte dalla prima pagina la prossima volta che lo apri.")
            ) {
                Picker("Riparti dalla prima pagina", selection: resetToFirstPagePolicy) {
                    ForEach(ResetToFirstPagePolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
            }

            Section(header: Text("Privacy")) {
                NavigationLink("Blocco genitori", destination: ParentalLockSettingsView())
                Toggle("Modalità Kiosk", isOn: $isKioskModeEnabled)
            }

            Section(
                header: Text("Avanzate"),
                footer: Text("Se disattivato, la cartella dei fumetti non viene inclusa nei backup di iCloud/iTunes — utile per risparmiare spazio se hai già una copia altrove.")
            ) {
                NavigationLink("Diagnostica", destination: DiagnosticsView())
                Toggle("Includi fumetti nel backup", isOn: Binding(
                    get: { isIncludedInBackup },
                    set: { newValue in
                        isIncludedInBackup = newValue
                        LibraryStorage.setExcludedFromBackup(!newValue)
                    }
                ))
            }

            Section(header: Text("Informazioni")) {
                HStack {
                    Text("Versione")
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(.secondary)
                }
                NavigationLink("Licenze open source", destination: AcknowledgementsView())
            }
        }
        .navigationTitle("Impostazioni")
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
