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
    /// False in kiosk mode — same rule as the grid's own context menu (`ComicCell.allowsDeletion`).
    var allowsDeletion = true
    let onRead: () -> Void
    /// Pops this screen and deletes the comic (owned by `LibraryView`, which pops first so
    /// this view never observes a deleted object). Asked for only after the confirmation below.
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false

    /// Same rule as the "In lettura" tab (`TVNowReadingTabView.lastReadComic`): opened at least
    /// once and not finished — page 1 included, so going back to page 1 doesn't read as "never opened".
    private var hasStartedReading: Bool {
        comic.dateLastOpened != nil && !comic.isFinished
    }

    private var pageStatusText: String {
        let key: String
        if comic.isFinished {
            key = "%@ pagine · Terminato"
        } else if hasStartedReading {
            key = "%@ pagine · In lettura"
        } else {
            key = "%@ pagine"
        }
        let format = AppLocalization.localizedString(key, comment: "Comic page count and reading status")
        return String(format: format, arguments: ["\(comic.pageCount)" as NSString])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            coverImage
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: 440)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)

            VStack(alignment: .leading, spacing: 16) {
                Text(comic.title ?? AppLocalization.localizedString("Senza titolo", comment: "Untitled comic fallback"))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .lineLimit(2)

                if let series = comic.seriesName, !series.isEmpty {
                    Text(series)
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                Text(pageStatusText)
                    .font(.body)
                    .foregroundColor(.secondary)

                // `.card` sizes its pill tightly around the label with no padding of its own —
                // a bare `Button(String, action:)` reads as cramped, text nearly touching the
                // edges (confirmed on-device). Real padding on the label gives it breathing room.
                Button(action: comic.isFinished ? restartFromBeginning : onRead) {
                    Text(primaryActionTitle)
                        .font(.headline)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.card)
                .padding(.top, 8)

                // Secondary actions: until now only reachable from the grid tile's long-press
                // context menu (and deletion not at all from here), which nothing on screen
                // hinted at.
                HStack(alignment: .top, spacing: 24) {
                    if hasStartedReading && comic.lastReadPage > 0 {
                        secondaryButton("Ricomincia dall'inizio", systemImage: "arrow.counterclockwise", action: restartFromBeginning)
                    }
                    secondaryButton(
                        comic.isFavorite ? "Rimuovi dai preferiti" : "Preferito",
                        systemImage: comic.isFavorite ? "star.fill" : "star",
                        action: toggleFavorite
                    )
                    if readStatus(for: comic) == .finished {
                        secondaryButton("Segna come non letto", systemImage: "circle", action: { markStatus(.unread) })
                    } else {
                        secondaryButton("Segna come letto", systemImage: "checkmark.circle", action: { markStatus(.finished) })
                    }
                    if allowsDeletion, onDelete != nil {
                        secondaryButton("Elimina", systemImage: "trash", action: { isConfirmingDelete = true })
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        // With the nav bar hidden at every level of the stack (this screen and the grid behind
        // it both suppress it), tvOS has no visible "non-root" affordance to base Menu's default
        // pop-vs-exit-app decision on, so it falls through to exiting the whole app instead of
        // popping back to the grid. Driving the pop explicitly avoids relying on that default.
        .onExitCommand { dismiss() }
        .confirmationDialog("Eliminare questo fumetto?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) { onDelete?() }
            Button("Annulla", role: .cancel) {}
        }
    }

    private func secondaryButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxHeight: .infinity)
        }
        .buttonStyle(.card)
    }

    private var primaryActionTitle: LocalizedStringKey {
        if comic.isFinished { return "Ricomincia dall'inizio" }
        return hasStartedReading ? "Riprendi" : "Leggi"
    }

    private func toggleFavorite() {
        comic.isFavorite.toggle()
        try? comic.managedObjectContext?.save()
    }

    private func markStatus(_ status: ReadStatus) {
        status.apply(to: comic)
        try? comic.managedObjectContext?.save()
        Task { @MainActor in RemoteProgressSync.requestPush(comic) }
    }

    /// Back to page 1 and straight into the reader. Not `ReadStatus.unread`: that also clears
    /// `dateLastOpened`, dropping the comic out of "In lettura" for no reason.
    private func restartFromBeginning() {
        comic.lastReadPage = 0
        comic.dateLastOpened = Date()
        try? comic.managedObjectContext?.save()
        Task { @MainActor in RemoteProgressSync.requestPush(comic) }
        onRead()
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
