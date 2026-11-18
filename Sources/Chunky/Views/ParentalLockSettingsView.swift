import SwiftUI

enum ParentalAutoLockTrigger: String, CaseIterable, Identifiable {
    case doNothing
    case lockImmediately

    var id: String { rawValue }

    /// What applies when the user never picked anything. tvOS: "Blocca subito" — leaving the app
    /// there means going back to the shared living-room Home Screen, exactly when a child could
    /// pick the remote up; iOS/macOS keep their historical default. Read by both the settings
    /// picker and `ChunkyApp`'s background handler, so the two can't disagree.
    static var platformDefault: ParentalAutoLockTrigger {
        #if os(tvOS)
        .lockImmediately
        #else
        .doNothing
        #endif
    }

    var label: String {
        switch self {
        case .doNothing: AppLocalization.localizedString("Non fare nulla", comment: "Parental lock behavior")
        case .lockImmediately: AppLocalization.localizedString("Blocca subito", comment: "Parental lock behavior")
        }
    }
}

struct ParentalLockSettingsView: View {
    var body: some View {
        #if os(tvOS)
        // Same fix as `ColorThemeView`: `.navigationTitle` overlays a fixed screen position on
        // tvOS instead of a sticky header, so a Form long enough to scroll (toggles + two
        // footers here) scrolls right through it. `TVPanel` puts the title in the layout instead.
        TVPanel(title: "Blocco genitori") {
            EmptyView()
        } content: {
            Form {
                ParentalLockSections()
            }
        }
        #else
        Form {
            ParentalLockSections()
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Blocco genitori")
        #endif
    }
}

/// Content of the parental lock without its own `Form`, so it can be embedded in a larger
/// `Form` (e.g. the "Parental Lock" tab in the Mac Preferences) as well as being shown on its
/// own behind a `NavigationLink` on iOS (`ParentalLockSettingsView` above).
struct ParentalLockSections: View {
    @ObservedObject private var lock = ParentalLock.shared
    @AppStorage("parentalLockAutoLockTrigger") private var autoLockTriggerRawValue = ParentalAutoLockTrigger.platformDefault.rawValue
    @State private var newPasscode = ""
    @State private var confirmPasscode = ""
    @State private var errorMessage: String?
    #if os(tvOS)
    /// "Rimuovi codice" asks for the current code first on tvOS: the settings screen sits
    /// unlocked behind a shared remote, and one stray Select used to drop the lock entirely.
    @State private var isConfirmingRemoval = false
    @State private var removalPasscode = ""
    @State private var removalError: String?

    private enum PasscodeField: Hashable { case new, confirm, save }
    @FocusState private var focusedField: PasscodeField?
    #endif

    private var lockFooter: Text {
        #if os(tvOS)
        Text("Il blocco genitori impedisce di aprire Chunky senza inserire il codice. Non protegge da un utente sufficientemente determinato: serve a scoraggiare gli accessi accidentali.")
        #else
        Text("Il blocco genitori impedisce di aprire Chunky senza inserire il codice, o Face ID/Touch ID se abilitato. Non protegge da un utente sufficientemente determinato: serve a scoraggiare gli accessi accidentali.")
        #endif
    }

    private var autoLockTrigger: Binding<ParentalAutoLockTrigger> {
        Binding(
            get: { ParentalAutoLockTrigger(rawValue: autoLockTriggerRawValue) ?? .platformDefault },
            set: { autoLockTriggerRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Group {
            if lock.hasPasscode {
                Section(footer: lockFooter) {
                    Toggle("Blocco attivo", isOn: Binding(
                        get: { lock.isEnabled },
                        set: { lock.isEnabled = $0 }
                    ))
                    #if !os(tvOS)
                    Toggle("Sblocca con Face ID / Touch ID", isOn: Binding(
                        get: { lock.isBiometricsEnabled },
                        set: { lock.isBiometricsEnabled = $0 }
                    ))
                    #endif
                    Button("Blocca ora") { lock.lockIfNeeded() }
                    #if os(tvOS)
                    Button("Rimuovi codice") {
                        removalPasscode = ""
                        isConfirmingRemoval = true
                    }
                    // On the button, not on the `Group` below: modifiers on a `Group` are
                    // applied to each child, which would install the alert once per Section.
                    .alert("Rimuovere il codice?", isPresented: $isConfirmingRemoval) {
                        SecureField("Codice attuale", text: $removalPasscode)
                            .keyboardType(.numberPad)
                        Button("Rimuovi", role: .destructive, action: confirmRemoval)
                        Button("Annulla", role: .cancel) { removalPasscode = "" }
                    } message: {
                        Text("Inserisci il codice attuale per disattivare il blocco genitori.")
                    }
                    if let removalError {
                        Text(removalError).foregroundColor(.red).font(.callout)
                    }
                    #else
                    Button("Rimuovi codice", action: lock.removePasscode)
                        .foregroundColor(.red)
                    #endif
                }

                #if os(tvOS)
                TVOptionPickerSection(
                    title: Text("Quando lascio Chunky"),
                    footer: Text("Decide se Chunky si blocca automaticamente ogni volta che esci dall'app (es. per rispondere a una notifica), oltre al blocco attivato dal riavvio dell'app."),
                    selection: autoLockTrigger,
                    options: Array(ParentalAutoLockTrigger.allCases)
                ) { Text($0.label) }
                #else
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
                #endif
            } else {
                Section(header: Text("Imposta un codice")) {
                    SecureField("Nuovo codice", text: $newPasscode)
                        #if os(iOS) || os(tvOS)
                        .keyboardType(.numberPad)
                        #endif
                        #if os(tvOS)
                        .focused($focusedField, equals: .new)
                        .listRowBackground(Color.clear)
                        .onSubmit { moveFocus(to: .confirm) }
                        #endif
                    SecureField("Conferma codice", text: $confirmPasscode)
                        #if os(iOS) || os(tvOS)
                        .keyboardType(.numberPad)
                        #endif
                        #if os(tvOS)
                        .focused($focusedField, equals: .confirm)
                        .listRowBackground(Color.clear)
                        .onSubmit { moveFocus(to: .save) }
                        #endif
                    if let errorMessage = errorMessage {
                        Text(errorMessage).foregroundColor(.red).font(.footnote)
                    }
                    Button("Salva codice", action: savePasscode)
                        #if os(tvOS)
                        .focused($focusedField, equals: .save)
                        #endif
                }
            }
        }
    }

    #if os(tvOS)
    /// The tvOS system keyboard hands focus back to the screen's first field as it closes,
    /// after `onSubmit` has run, overwriting an immediate assignment. Assign once it is gone.
    private func moveFocus(to field: PasscodeField) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            focusedField = field
        }
    }

    private func confirmRemoval() {
        if lock.verifyPasscode(removalPasscode) {
            lock.removePasscode()
            removalError = nil
        } else {
            removalError = AppLocalization.localizedString("Codice errato", comment: "Passcode validation error")
        }
        removalPasscode = ""
    }
    #endif

    private func savePasscode() {
        guard newPasscode.count >= 4 else {
            errorMessage = AppLocalization.localizedString("Il codice deve avere almeno 4 caratteri.", comment: "Passcode validation error")
            return
        }
        guard newPasscode == confirmPasscode else {
            errorMessage = AppLocalization.localizedString("I due codici non coincidono.", comment: "Passcode validation error")
            return
        }
        guard lock.setPasscode(newPasscode) else {
            errorMessage = AppLocalization.localizedString("Impossibile salvare il codice. Riprova.", comment: "Passcode save error")
            return
        }
        lock.isEnabled = true
        newPasscode = ""
        confirmPasscode = ""
        errorMessage = nil
    }
}

#Preview {
    ParentalLockSettingsView()
}
