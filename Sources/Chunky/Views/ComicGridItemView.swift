import SwiftUI

/// Full grid item: cover art (`ComicCoverView`) plus title, stacked. On tvOS this combined
/// shape isn't used inside a focusable `Button` (see `LibraryView.cellButton`) — a title nested
/// inside the same container that receives the `.card` style's focus-scale transform scales and
/// clips awkwardly there (same tvOS quirk documented by Swiftfin's `PosterButton`). Kept as one
/// piece for callers that just need a static cover+title, e.g. `ReaderView`'s "up next" card.
struct ComicGridItemView: View {
    @ObservedObject var comic: ComicEntity
    /// False nella cella libreria (iOS/macOS): lì il badge iCloud statico è sostituito
    /// dal controllo download live in overlay (`RemoteDownloadControl`), altrimenti la
    /// nuvoletta comparirebbe due volte nello stesso angolo.
    var showsPendingDownloadBadge = true
    /// Passato dal genitore (che osserva `ICloudDownloadTracker` una sola volta per
    /// tutta la griglia) — vedi `ComicCoverView.isPendingDownload`.
    var isPendingDownload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ComicCoverView(comic: comic, showsPendingDownloadBadge: showsPendingDownloadBadge, isPendingDownload: isPendingDownload)
            Text(comic.title ?? "Senza titolo")
                .font(.caption.bold())
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Cover art alone (image + progress/favorite/finished/pending-download badges), no title —
/// the piece that should sit inside a focusable `Button` on tvOS, with the title placed as a
/// sibling outside it. See `ComicGridItemView`'s doc comment for why.
struct ComicCoverView: View {
    @ObservedObject var comic: ComicEntity
    /// Vedi `ComicGridItemView.showsPendingDownloadBadge`.
    var showsPendingDownloadBadge = true
    /// Non osservato qui dentro: `ICloudDownloadTracker` è un singleton i cui update
    /// (`NSMetadataQuery`, molto chiacchierone su Mac nel gathering iniziale) invaliderebbero
    /// TUTTE le celle a ogni cambiamento, anche in pieno scroll. Lo osserva una sola volta
    /// il genitore (`LibraryView` / `LibraryTableView`) e passa qui il Bool già calcolato,
    /// così solo le celle il cui valore cambia davvero si ridisegnano.
    var isPendingDownload = false

    var body: some View {
        // .overlay(alignment:), not a ZStack with conditional children: inside a
        // LazyVGrid a ZStack sometimes fails to correctly resize/position children
        // added via "if" (observed empirically — the same progress bar
        // showed up in the horizontal "New" tray but not in the grid below it).
        coverImage
            .aspectRatio(2/3, contentMode: .fill)
            .frame(maxWidth: .infinity)
            // Un solo clip invece di `.clipped()` + `.cornerRadius`: due ritagli
            // sovrapposti costano due passaggi per cella a ogni frame di scroll su macOS.
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // A comic that's already finished is visible at a glance, like a checkmark
            // ticked off a list: no need to read the badge to understand the status.
            // Solo opacità, niente `.saturation`: desaturare costa un passaggio offscreen
            // per cella a ogni frame su macOS, l'opacità da sola comunica già "finito".
            .opacity(comic.isFinished ? 0.55 : 1)
            .overlay(progressBar, alignment: .bottom)
            .overlay(finishedBadge, alignment: .topTrailing)
            .overlay(favoriteBadge, alignment: .topLeading)
            .overlay(pendingDownloadBadge, alignment: .bottomTrailing)
    }

    @ViewBuilder
    private var progressBar: some View {
        // Native ProgressView instead of computing the width by hand with GeometryReader:
        // in a LazyVGrid the latter proved unreliable (it sometimes didn't receive
        // a valid width and the bar disappeared entirely, inconsistently across cells).
        if comic.progress > 0 && !comic.isFinished {
            // The displayed value is raised to a visual minimum (not the actual saved progress):
            // at the start of reading a long comic, the real progress is too small to be
            // perceived as a bar, even with the contrast applied below.
            ProgressView(value: max(comic.progress, 0.08))
                .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                .frame(height: 5)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
                .background(
                    Capsule().fill(Color.black.opacity(0.4))
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                )
        }
    }

    private func badge(systemImage: String, foreground: Color, background: Color) -> some View {
        Image(systemName: systemImage)
            .foregroundColor(foreground)
            .padding(6)
            .background(background)
            .clipShape(Circle())
            .padding(6)
    }

    @ViewBuilder
    private var finishedBadge: some View {
        if comic.isFinished {
            badge(systemImage: "checkmark.circle.fill", foreground: .white, background: .accentColor)
        }
    }

    @ViewBuilder
    private var favoriteBadge: some View {
        if comic.isFavorite {
            badge(systemImage: "star.fill", foreground: .yellow, background: Color.black.opacity(0.5))
        }
    }

    /// Shown when the comic is only an iCloud placeholder, not yet downloaded locally:
    /// without this hint, opening it can produce an error after a long loading time
    /// with no clear reason why.
    @ViewBuilder
    private var pendingDownloadBadge: some View {
        if showsPendingDownloadBadge && isPendingDownload {
            badge(systemImage: "icloud.and.arrow.down", foreground: .white, background: Color.black.opacity(0.5))
        }
    }

    @ViewBuilder
    private var coverImage: some View {
        // Decoded once and reused: without `CoverThumbnailCache` this used to run again on
        // every evaluation of `body`, and with an entire group appearing all at once
        // (e.g. expanding a section) the synchronous decodes piled up
        // enough to noticeably stall the animation.
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
    return ComicGridItemView(comic: comic)
        .environment(\.managedObjectContext, context)
        .frame(width: 160)
        .padding()
}
