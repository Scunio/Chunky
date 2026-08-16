import SwiftUI

/// Popover "Nuovi", agganciato all'icona a forma di vassoio nella toolbar della libreria:
/// una lista verticale di copertine a piena larghezza (non una griglia di miniature), con
/// "Cancella" per smarcare i fumetti come già visti.
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
                emptyState
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
        .frame(width: 280, height: 420)
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
