import SwiftUI

struct ComicGridItemView: View {
    @ObservedObject var comic: ComicEntity
    /// Single source of truth for the "to download" badge: a live library-level `NSMetadataQuery`,
    /// so the badge updates on its own when the download finishes instead of depending on
    /// a grid redraw triggered for other reasons.
    @ObservedObject private var downloadTracker = ICloudDownloadTracker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // .overlay(alignment:), not a ZStack with conditional children: inside a
            // LazyVGrid a ZStack sometimes fails to correctly resize/position children
            // added via "if" (observed empirically — the same progress bar
            // showed up in the horizontal "New" tray but not in the grid below it).
            coverImage
                .aspectRatio(2/3, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
                .cornerRadius(8)
                // A comic that's already finished is visible at a glance, like a checkmark
                // ticked off a list: no need to read the badge to understand the status.
                .saturation(comic.isFinished ? 0 : 1)
                .opacity(comic.isFinished ? 0.55 : 1)
                .overlay(progressBar, alignment: .bottom)
                .overlay(finishedBadge, alignment: .topTrailing)
                .overlay(favoriteBadge, alignment: .topLeading)
                .overlay(pendingDownloadBadge, alignment: .bottomTrailing)

            Text(comic.title ?? "Senza titolo")
                .font(.caption.bold())
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isPendingDownload: Bool {
        guard let relativePath = comic.relativePath else { return false }
        return downloadTracker.pendingRelativePaths.contains(relativePath)
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
        if isPendingDownload {
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
