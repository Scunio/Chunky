import SwiftUI

struct ParentalLockGateView: View {
    @ObservedObject private var lock = ParentalLock.shared
    @State private var enteredPasscode = ""
    @State private var showError = false
    @FocusState private var isPasscodeFocused: Bool
    #if os(macOS)
    /// Every Mac window (library, readers, Settings) shows its own lock screen: only the key
    /// one asks for Touch ID on its own, the others wait for their button.
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var didAutoAttemptBiometrics = false
    #endif

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("Chunky è bloccata")
                .font(.title3.bold())

            SecureField("Codice", text: $enteredPasscode)
                #if !os(tvOS)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                #endif
                // 220pt reads as a sliver on a 1920pt TV screen, and the field is the one
                // thing on this screen the user has to aim at with the remote.
                #if os(tvOS)
                .frame(maxWidth: 560)
                #else
                .frame(maxWidth: 220)
                #endif
                .focused($isPasscodeFocused)
                .onSubmit(attemptUnlock)
                #if os(iOS) || os(tvOS)
                .keyboardType(.numberPad)
                #endif

            if showError {
                Text("Codice errato")
                    .foregroundColor(.red)
                    .font(.footnote)
            }

            Button("Sblocca", action: attemptUnlock)
                .buttonStyle(.borderedProminent)

            if lock.isBiometricsEnabled {
                Button(action: attemptBiometrics) {
                    #if os(macOS)
                    // Macs have Touch ID only.
                    Label("Usa Touch ID", systemImage: "touchid")
                    #else
                    Label("Usa Face ID / Touch ID", systemImage: "faceid")
                    #endif
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isPasscodeFocused = true
            #if os(macOS)
            autoAttemptBiometricsIfKey()
            #else
            attemptBiometrics()
            #endif
        }
        #if os(macOS)
        // Locked while the app was in the background: no window was key at appear time, so
        // the prompt comes when the user brings this window forward (once per lock screen).
        .onChange(of: controlActiveState) { _, _ in autoAttemptBiometricsIfKey() }
        #endif
    }

    #if os(macOS)
    private func autoAttemptBiometricsIfKey() {
        guard controlActiveState == .key, !didAutoAttemptBiometrics else { return }
        didAutoAttemptBiometrics = true
        attemptBiometrics()
    }
    #endif

    private func attemptUnlock() {
        if lock.unlock(withPasscode: enteredPasscode) {
            enteredPasscode = ""
            showError = false
        } else {
            showError = true
        }
    }

    private func attemptBiometrics() {
        lock.unlockWithBiometrics { _ in }
    }
}

#Preview {
    ParentalLockGateView()
}
