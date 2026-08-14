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
            .buttonStyle(PlainButtonStyle())
        }
        .padding()
        .frame(width: 220)
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
        if let data = comic.coverImageData, let platformImage = PlatformImage.from(data: data) {
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
