import SwiftUI

enum ParentalAutoLockTrigger: String, CaseIterable, Identifiable {
    case doNothing
    case lockImmediately

    var id: String { rawValue }

    var label: String {
        switch self {
        case .doNothing: "Non fare nulla"
        case .lockImmediately: "Blocca subito"
        }
    }
}

struct ParentalLockSettingsView: View {
    var body: some View {
        Form {
            ParentalLockSections()
        }
        .navigationTitle("Blocco genitori")
    }
}

/// Contenuto del blocco genitori senza `Form` propria, per poterlo incorporare in una `Form`
/// più ampia (es. la tab "Blocco genitori" delle Preferenze Mac) oltre che mostrarlo da solo
/// dietro `NavigationLink` su iOS (`ParentalLockSettingsView` sopra).
struct ParentalLockSections: View {
    @ObservedObject private var lock = ParentalLock.shared
    @AppStorage("parentalLockAutoLockTrigger") private var autoLockTriggerRawValue = ParentalAutoLockTrigger.doNothing.rawValue
    @State private var newPasscode = ""
    @State private var confirmPasscode = ""
    @State private var errorMessage: String?

    private var autoLockTrigger: Binding<ParentalAutoLockTrigger> {
        Binding(
            get: { ParentalAutoLockTrigger(rawValue: autoLockTriggerRawValue) ?? .doNothing },
            set: { autoLockTriggerRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Group {
            if lock.hasPasscode {
                Section(footer: Text("Il blocco genitori impedisce di aprire Chunky senza inserire il codice, o Face ID/Touch ID se abilitato. Non protegge da un utente sufficientemente determinato: serve a scoraggiare gli accessi accidentali.")) {
                    Toggle("Blocco attivo", isOn: Binding(
                        get: { lock.isEnabled },
                        set: { lock.isEnabled = $0 }
                    ))
                    Toggle("Sblocca con Face ID / Touch ID", isOn: Binding(
                        get: { lock.isBiometricsEnabled },
                        set: { lock.isBiometricsEnabled = $0 }
                    ))
                    Button("Blocca ora") { lock.lockIfNeeded() }
                    Button("Rimuovi codice", action: lock.removePasscode)
                        .foregroundColor(.red)
                }

                Section(
                    header: Text("Blocco automatico"),
                    footer: Text("Decide se Chunky si blocca automaticamente ogni volta che esci dall'app (es. per rispondere a una notifica), oltre al blocco attivato dal riavvio dell'app.")
                ) {
                    Picker("Quando lascio Chunky", selection: autoLockTrigger) {
                        ForEach(ParentalAutoLockTrigger.allCases) { trigger in
                            Text(trigger.label).tag(trigger)
                        }
                    }
                }
            } else {
                Section(header: Text("Imposta un codice")) {
                    SecureField("Nuovo codice", text: $newPasscode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    SecureField("Conferma codice", text: $confirmPasscode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    if let errorMessage = errorMessage {
                        Text(errorMessage).foregroundColor(.red).font(.footnote)
                    }
                    Button("Salva codice", action: savePasscode)
                }
            }
        }
    }

    private func savePasscode() {
        guard newPasscode.count >= 4 else {
            errorMessage = "Il codice deve avere almeno 4 caratteri."
            return
        }
        guard newPasscode == confirmPasscode else {
            errorMessage = "I due codici non coincidono."
            return
        }
        lock.setPasscode(newPasscode)
        lock.isEnabled = true
        newPasscode = ""
        confirmPasscode = ""
        errorMessage = nil
    }
}
