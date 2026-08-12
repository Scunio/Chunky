import SwiftUI

struct ComicGridItemView: View {
    @ObservedObject var comic: ComicEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                coverImage
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .cornerRadius(8)

                if comic.progress > 0 && !comic.isFinished {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: proxy.size.width * comic.progress, height: 4)
                    }
                    .frame(height: 4)
                }

                if comic.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                }

                if comic.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .padding(6)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            Text(comic.title ?? "Senza titolo")
                .font(.caption.bold())
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
