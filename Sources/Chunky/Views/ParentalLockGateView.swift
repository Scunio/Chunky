import SwiftUI

struct ParentalLockGateView: View {
    @ObservedObject private var lock = ParentalLock.shared
    @State private var enteredPasscode = ""
    @State private var showError = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("Chunky è bloccata")
                .font(.title3.bold())

            SecureField("Codice", text: $enteredPasscode, onCommit: attemptUnlock)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(maxWidth: 220)
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
        .onAppear(perform: attemptBiometrics)
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
