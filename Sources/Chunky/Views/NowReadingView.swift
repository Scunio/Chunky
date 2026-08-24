import SwiftUI

/// Popover con l'anteprima rapida dell'ultimo fumetto aperto: titolo centrato in alto,
/// copertina con badge di pagina sovrapposto in basso, tocco sulla copertina per riprendere
/// subito la lettura.
struct NowReadingView: View {
    @ObservedObject var comic: ComicEntity
    let onResume: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Ora in lettura")
                .font(.headline)

            Button(action: onResume) {
                coverImage
                    .aspectRatio(2/3, contentMode: .fit)
                    .cornerRadius(6)
                    .overlay(pageBadge, alignment: .bottom)
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .buttonStyle(PlainButtonStyle())
            #endif
        }
        .padding()
        .frame(width: 220)
        #if os(tvOS)
        // On iOS/macOS this sits inside a `.popover`, whose own material already gives it
        // one seamless rounded card. `platformPopover` uses a plain `.sheet` on tvOS instead,
        // which has no such shared background — without this, the sheet drew a separate
        // white rounded-top shape around the text that didn't line up with the cover image's
        // own corner radius below it, plus it was jarringly light against the app's dark UI.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
        #endif
    }

    private var pageBadge: some View {
        Text("\(min(Int(comic.lastReadPage) + 1, max(Int(comic.pageCount), 1))) / \(comic.pageCount)")
            .font(.subheadline.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private var coverImage: some View {
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

#Preview {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext
    let comic = ComicEntity.create(
        title: "Anteprima",
        relativePath: "preview.cbz",
        format: .cbz,
        in: context
    )
    return NowReadingView(comic: comic, onResume: {})
        .environment(\.managedObjectContext, context)
}
