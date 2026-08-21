import SwiftUI

/// "New" popover, anchored to the tray-shaped icon in the library toolbar:
/// a vertical list of full-width covers (not a grid of thumbnails), with
/// "Clear" to unmark comics as already seen.
struct NewComicsView: View {
    let comics: [ComicEntity]
    let onSelect: (ComicEntity) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nuovi")
                    .font(.headline)
                Spacer()
                Button("Cancella", action: onClear)
                    .foregroundColor(.red)
                    .disabled(comics.isEmpty)
            }
            .padding()

            Divider()

            if comics.isEmpty {
                Spacer(minLength: 0)
                emptyState
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(comics) { comic in
                            Button(action: { onSelect(comic) }) {
                                coverImage(for: comic)
                                    .aspectRatio(2/3, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding()
                }
            }
        }
        #if os(tvOS)
        // tvOS's default type is much larger than iOS/macOS (10-foot readability), so the
        // iOS/macOS popover size is too narrow here and wraps "Nuovi"/"Cancella" letter by letter.
        // The empty state also needs less height than the scrollable cover list: at the
        // list's height it was mostly dead black space around one small icon and a line of text.
        .frame(width: 520, height: comics.isEmpty ? 320 : 620)
        #else
        .frame(width: 280, height: 420)
        #endif
    }

    private var emptyState: some View {
        ContentUnavailableView("Nessun fumetto nuovo", systemImage: "envelope")
    }

    @ViewBuilder
    private func coverImage(for comic: ComicEntity) -> some View {
        if let platformImage = CoverThumbnailCache.image(for: comic) {
            platformImage.asSwiftUIImage
                .resizable()
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .overlay(
                    Image(systemName: "book.closed")
                        .font(.title)
                        .foregroundColor(.secondary)
                )
        }
    }
}
