import SwiftUI

struct AcknowledgementsView: View {
    private var text: String {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "Licenze non disponibili."
        }
        return content
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Licenze")
    }
}

#Preview {
    AcknowledgementsView()
}
