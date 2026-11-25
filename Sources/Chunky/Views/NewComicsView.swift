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
                            #if os(tvOS)
                            .buttonStyle(.card)
                            #else
                            .buttonStyle(PlainButtonStyle())
                            #endif
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
        #elseif os(macOS)
        // A 2:3 cover at 280pt is ~370pt tall: with the 420pt popover only a sliver of it was
        // visible under the header, which read as a clipped image. Taller on the Mac, where
        // there's room, and the list scrolls when there are more.
        .frame(width: 300, height: 560)
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
            // Opaque base under the tint: the macOS popover is translucent glass, and a
            // see-through placeholder showed the library behind it as a blurred smear.
            Rectangle()
                .fill(.background)
                .overlay(Rectangle().fill(Color.secondary.opacity(0.2)))
                .overlay(
                    Image(systemName: "book.closed")
                        .font(.title)
                        .foregroundColor(.secondary)
                )
        }
    }
}

#Preview {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext
    let comic = ComicEntity.create(
        title: "Anteprima",
        relativePath: "preview.cbz",
        format: .cbz,
        in: context
    )
    return NewComicsView(comics: [comic], onSelect: { _ in }, onClear: {})
        .environment(\.managedObjectContext, context)
}
