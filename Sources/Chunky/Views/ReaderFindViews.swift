import SwiftUI

/// Card di ricerca testuale, sovrapposta alla pagina già visibile come `PanelSelectionView` e
/// `pageJumpCard`: la pagina resta sotto, così si vede subito il risultato del salto senza
/// uscire e rientrare da una schermata a parte.
///
/// I risultati compaiono man mano che `ComicTextIndex` scansiona: la riga di avanzamento in
/// basso esiste perché, altrimenti, "nessun risultato" durante la scansione sarebbe
/// indistinguibile da "questa parola non c'è".
struct ReaderFindView: View {
    @ObservedObject var index: ComicTextIndex
    @Binding var query: String
    let onSelect: (ComicTextMatch) -> Void
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    /// Oltre questo numero l'elenco smette di essere consultabile e inizia solo a costare:
    /// chi ha così tanti riscontri deve restringere la ricerca, non scorrere mille righe.
    private static let maximumResults = 200

    private var matches: [ComicTextMatch] {
        Array(index.matches(for: query).prefix(Self.maximumResults))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().background(Color.white.opacity(0.2))
            resultsList
            statusLine
        }
        .frame(maxWidth: 420)
        .frame(maxHeight: 420)
        .background(Color.black.opacity(0.9))
        .cornerRadius(16)
        .padding()
        // La card ha fondo nero ma non sta dentro l'header: senza forzare lo schema, i colori
        // semantici (`.secondary` dei numeri di pagina e dei messaggi) restano quelli dello
        // schema chiaro, cioè grigio scuro su nero — illeggibili. Stessa correzione che
        // `ReaderContentView.header` applica al suo materiale.
        .environment(\.colorScheme, .dark)
        .onAppear { isFieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Cerca nel fumetto", text: $query)
                .textFieldStyle(.plain)
                .foregroundColor(.white)
                .focused($isFieldFocused)
                .submitLabel(.search)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            Button(action: onClose) {
                Text("Fine").foregroundColor(.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(12)
    }

    @ViewBuilder
    private var resultsList: some View {
        if index.hasNoRecognizableText {
            message("In questo fumetto non è stato trovato testo leggibile: le tavole potrebbero essere senza dialoghi, o con lettering che l'OCR non riesce a interpretare.")
        } else if query.count < 2 {
            message("Scrivi almeno due lettere per cercare tra i testi delle pagine.")
        } else if matches.isEmpty {
            message(index.isScanning ? "Nessun riscontro nelle pagine già lette." : "Nessun riscontro.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { match in
                        Button(action: { onSelect(match) }) {
                            resultRow(match)
                        }
                        .buttonStyle(PlainButtonStyle())
                        Divider().background(Color.white.opacity(0.1))
                    }
                }
            }
        }
    }

    private func resultRow(_ match: ComicTextMatch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(match.pageIndex + 1)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
            Text(match.text)
                .font(.callout)
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(20)
    }

    @ViewBuilder
    private var statusLine: some View {
        if index.isScanning {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Lettura pagine… \(index.scannedPageCount) di \(index.pageCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

/// Evidenzia sulla pagina visibile le righe che corrispondono alla ricerca.
///
/// Carica l'immagine solo per conoscerne le dimensioni in pixel: senza quelle non si può
/// convertire un rettangolo normalizzato in coordinate schermo, perché la geometria dipende
/// dalle proporzioni della pagina. Vale la stessa avvertenza di `PanelSelectionView`: si
/// riferisce alla pagina originale, quindi chi la mostra deve escludere i casi in cui a schermo
/// c'è qualcosa di diverso (doppia pagina, ritaglio automatico).
struct ReaderFindHighlightOverlay: View {
    /// Osservato qui, non a monte: i rettangoli cambiano man mano che la scansione procede, e
    /// un indice tenuto in un `@State` del lettore non ne propagherebbe gli aggiornamenti.
    @ObservedObject var index: ComicTextIndex
    let query: String
    let pageIndex: Int
    let provider: ComicPageProvider

    @State private var imageSize: CGSize = .zero

    private var boxes: [CGRect] { index.highlights(for: query, onPage: pageIndex) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if imageSize.width > 0 {
                    ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                        let rect = PageTextRecognizer.screenRect(
                            forNormalized: box,
                            imageSize: imageSize,
                            displaySize: proxy.size
                        )
                        // Riempimento giallo *più* bordo scuro: le pagine di un fumetto sono
                        // tanto bianche quanto nere, e da sola nessuna delle due cose basta —
                        // il giallo traslucido sparisce su carta chiara, il bordo scuro sparisce
                        // su una vignetta notturna. Insieme si vedono su qualsiasi sfondo.
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.yellow.opacity(0.45))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.orange, lineWidth: 2)
                            )
                            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .task(id: pageIndex) { await loadImageSize() }
    }

    private func loadImageSize() async {
        let page = pageIndex
        let size: CGSize = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let cgImage = (try? provider.image(atPage: page))?.cgImageRepresentation else {
                    continuation.resume(returning: .zero)
                    return
                }
                continuation.resume(returning: CGSize(width: cgImage.width, height: cgImage.height))
            }
        }
        imageSize = size
    }
}
