#if os(tvOS)
import SwiftUI

/// Detail screen between the library grid and the reader — cover on the left, title/metadata/
/// "Leggi" on the right, on the app's normal background. Replaces an earlier full-bleed-cover
/// version (Destination Video's hero-image style): with this app's fixture/placeholder covers
/// it read as an oversized, empty screen rather than a poster backdrop, and cover art here isn't
/// guaranteed to be wide/atmospheric the way a movie backdrop is — a two-column layout doesn't
/// depend on the cover looking good stretched full-screen.
struct TVComicDetailView: View {
    @ObservedObject var comic: ComicEntity
    let onRead: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var hasStartedReading: Bool {
        comic.lastReadPage > 0 && !comic.isFinished
    }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            coverImage
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: 440)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)

            VStack(alignment: .leading, spacing: 16) {
                Text(comic.title ?? "Senza titolo")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .lineLimit(2)

                if let series = comic.seriesName, !series.isEmpty {
                    Text(series)
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                Text("\(comic.pageCount) pagine" + (comic.isFinished ? " · Letto" : hasStartedReading ? " · In lettura" : ""))
                    .font(.body)
                    .foregroundColor(.secondary)

                // `.card` sizes its pill tightly around the label with no padding of its own —
                // a bare `Button(String, action:)` reads as cramped, text nearly touching the
                // edges (confirmed on-device). Real padding on the label gives it breathing room.
                Button(action: onRead) {
                    Text(hasStartedReading ? "Riprendi" : "Leggi")
                        .font(.headline)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.card)
                .padding(.top, 8)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 80)
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        // With the nav bar hidden at every level of the stack (this screen and the grid behind
        // it both suppress it), tvOS has no visible "non-root" affordance to base Menu's default
        // pop-vs-exit-app decision on, so it falls through to exiting the whole app instead of
        // popping back to the grid. Driving the pop explicitly avoids relying on that default.
        .onExitCommand { dismiss() }
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

#Preview {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext
    let comic = ComicEntity.create(
        title: "Anteprima",
        relativePath: "preview.cbz",
        format: .cbz,
        in: context
    )
    return NavigationStack {
        TVComicDetailView(comic: comic, onRead: {})
    }
    .environment(\.managedObjectContext, context)
}
#endif
