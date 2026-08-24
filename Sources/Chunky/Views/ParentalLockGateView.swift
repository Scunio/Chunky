import SwiftUI

struct ParentalLockGateView: View {
    @ObservedObject private var lock = ParentalLock.shared
    @State private var enteredPasscode = ""
    @State private var showError = false
    @FocusState private var isPasscodeFocused: Bool

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
                .frame(maxWidth: 220)
                .focused($isPasscodeFocused)
                .onSubmit(attemptUnlock)
                #if os(iOS)
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
                    Label("Usa Face ID / Touch ID", systemImage: "faceid")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isPasscodeFocused = true
            attemptBiometrics()
        }
    }

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
