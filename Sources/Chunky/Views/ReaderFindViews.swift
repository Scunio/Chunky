import SwiftUI

/// Text search card, overlaid on the already-visible page like `PanelSelectionView` and
/// `pageJumpCard`: the page stays underneath, so the result of the jump is visible right away
/// without leaving and re-entering a separate screen.
///
/// Results appear as `ComicTextIndex` scans: the progress line at the bottom exists because,
/// otherwise, "no results" during the scan would be indistinguishable from "this word isn't
/// there".
struct ReaderFindView: View {
    @ObservedObject var index: ComicTextIndex
    @Binding var query: String
    let onSelect: (ComicTextMatch) -> Void
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    /// Beyond this number the list stops being usable and starts just costing: anyone with
    /// this many matches should narrow the search, not scroll through a thousand lines.
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
        // The card has a black background but isn't inside the header: without forcing the
        // scheme, the semantic colors (`.secondary` for page numbers and messages) stay those
        // of the light scheme, i.e. dark gray on black — unreadable. Same fix that
        // `ReaderContentView.header` applies to its own material.
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

/// Highlights on the visible pages the lines that match the search — one page, or the two of a
/// spread side by side, already in the visual order the reading direction implies.
///
/// Loads each image only to know its pixel dimensions (and, with auto-crop on, its content
/// rectangle): without those, a normalized rectangle can't be converted into screen coordinates,
/// because the geometry depends on the page's proportions.
struct ReaderFindHighlightOverlay: View {
    /// Observed here, not upstream: the rectangles change as the scan proceeds, and an index
    /// kept in a `@State` of the reader wouldn't propagate its updates.
    @ObservedObject var index: ComicTextIndex
    let query: String
    /// The pages currently on screen, already in left-to-right visual order: one for a single
    /// page, two for a spread.
    let displayedPages: [Int]
    let provider: ComicPageProvider

    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false

    private struct PageGeometry {
        let imageSize: CGSize
        let cropRect: CGRect?
    }

    @State private var geometries: [Int: PageGeometry] = [:]

    /// Width of a given page in the spread when it's `height` tall: the same formula as
    /// `SpreadZoomableImageView.Coordinator.layOutImages`/`PageView.pairedContent`, so the
    /// highlight boxes line up with the page actually drawn.
    private func slotWidth(for page: Int, height: CGFloat) -> CGFloat {
        guard let geometry = geometries[page] else { return 0 }
        let size = displaySize(for: geometry)
        guard size.height > 0 else { return 0 }
        return height * size.width / size.height
    }

    private func displaySize(for geometry: PageGeometry) -> CGSize {
        guard isAutoCropEnabled, let cropRect = geometry.cropRect else { return geometry.imageSize }
        return cropRect.size
    }

    var body: some View {
        GeometryReader { proxy in
            let slots = layoutSlots(in: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(slots, id: \.page) { slot in
                    highlights(onPage: slot.page, in: slot.frame)
                }
            }
        }
        .allowsHitTesting(false)
        .task(id: displayedPages) { await loadGeometries() }
    }

    private struct Slot { let page: Int; let frame: CGRect }

    /// Splits the available space between the displayed pages, each sized in proportion to its
    /// own dimensions (or its content rectangle, with auto-crop on) and as tall as the whole
    /// box — then centers the pair, exactly like the reader does.
    private func layoutSlots(in size: CGSize) -> [Slot] {
        guard size.height > 0, !displayedPages.isEmpty else { return [] }
        let widths = displayedPages.map { slotWidth(for: $0, height: size.height) }
        guard widths.allSatisfy({ $0 > 0 }) else { return [] }

        let totalWidth = widths.reduce(0, +)
        var originX = max((size.width - totalWidth) / 2, 0)
        var slots: [Slot] = []
        for (page, width) in zip(displayedPages, widths) {
            slots.append(Slot(page: page, frame: CGRect(x: originX, y: 0, width: width, height: size.height)))
            originX += width
        }
        return slots
    }

    @ViewBuilder
    private func highlights(onPage page: Int, in frame: CGRect) -> some View {
        if let geometry = geometries[page] {
            let cropRect = isAutoCropEnabled ? geometry.cropRect : nil
            ForEach(Array(index.highlights(for: query, onPage: page).enumerated()), id: \.offset) { _, box in
                if let rect = PageTextRecognizer.screenRect(
                    forNormalized: box, imageSize: geometry.imageSize, cropRect: cropRect, displaySize: frame.size
                ) {
                    // Yellow fill *plus* dark border: comic pages are as often white as black,
                    // and neither alone is enough — the translucent yellow disappears on light
                    // paper, the dark border disappears on a night-time panel. Together they
                    // show up on any background.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.yellow.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color.orange, lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: frame.minX + rect.minX, y: frame.minY + rect.minY)
                }
            }
        }
    }

    private func loadGeometries() async {
        let pages = displayedPages
        let loaded: [Int: PageGeometry] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result: [Int: PageGeometry] = [:]
                for page in pages {
                    guard let image = try? provider.image(atPage: page),
                          let cgImage = image.cgImageRepresentation else { continue }
                    let size = CGSize(width: cgImage.width, height: cgImage.height)
                    result[page] = PageGeometry(imageSize: size, cropRect: ImageProcessing.contentCropRect(image))
                }
                continuation.resume(returning: result)
            }
        }
        geometries = loaded
    }
}
