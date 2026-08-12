import SwiftUI

/// Schermata "Informazioni", raggiunta dal pannello Tools.
struct AboutView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)
                    Text("Chunky")
                        .font(.title2.bold())
                    Text(appVersion)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                NavigationLink("Licenze open source", destination: AcknowledgementsView())
            }
        }
        .navigationTitle("Informazioni")
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Versione \(version) (\(build))"
    }
}
