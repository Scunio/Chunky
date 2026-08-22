#if os(tvOS)
import SwiftUI

/// Detail screen between the library grid and the reader — full-bleed cover, gradient scrim,
/// title and a default-focused "Leggi"/"Riprendi" button, matching the shape Apple's own
/// "Destination Video" sample uses for its tvOS detail screen (`Views/tvOS/DetailView.swift`:
/// full-bleed image + material gradient + oversized rounded title).
struct TVComicDetailView: View {
    @ObservedObject var comic: ComicEntity
    let onRead: () -> Void

    private var hasStartedReading: Bool {
        comic.lastReadPage > 0 && !comic.isFinished
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            coverImage
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.4), .clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 480)
            .ignoresSafeArea(edges: .bottom)

            VStack(alignment: .leading, spacing: 16) {
                Text(comic.title ?? "Senza titolo")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(2)

                if let series = comic.seriesName, !series.isEmpty {
                    Text(series)
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.8))
                }

                Text("\(comic.pageCount) pagine" + (comic.isFinished ? " · Letto" : hasStartedReading ? " · In lettura" : ""))
                    .font(.body)
                    .foregroundColor(.white.opacity(0.7))

                Button(hasStartedReading ? "Riprendi" : "Leggi", action: onRead)
                    .buttonStyle(.card)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 80)
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var coverImage: some View {
        if let platformImage = CoverThumbnailCache.image(for: comic) {
            platformImage.asSwiftUIImage
                .resizable()
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
        }
    }
}
#endif
