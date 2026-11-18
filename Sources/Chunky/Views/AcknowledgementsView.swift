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
        #if os(tvOS)
        // One big `Text` in a `ScrollView` can't be scrolled with the remote (nothing in it is
        // focusable): one focusable block per paragraph lets Down walk — and scroll — through it.
        TVPanel(title: "Licenze") { EmptyView() } content: {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        TVAcknowledgementParagraph(text: paragraph)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        #else
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Licenze")
        #endif
    }

    #if os(tvOS)
    private var paragraphs: [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    #endif
}

#if os(tvOS)
/// A focusable paragraph with a visible focus state (plain focusable views get none on tvOS).
private struct TVAcknowledgementParagraph: View {
    let text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(isFocused ? 0.15 : 0))
            )
            .focusable()
            .focused($isFocused)
    }
}
#endif

#Preview {
    AcknowledgementsView()
}
