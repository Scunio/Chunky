#if os(macOS)
import SwiftUI
import CoreData

/// Content of a reader window on Mac, opened with `openWindow(value: ComicID)`.
///
/// Resolves the id into a `ComicEntity` when it appears: if the comic no longer exists
/// (deleted, or the store was recreated after a loading error — see `ComicID.resolve`),
/// it shows a placeholder instead of crashing the window restored from a previous
/// session.
struct ReaderWindowContainer: View {
    let comicID: ComicID

    @Environment(\.managedObjectContext) private var context
    @ObservedObject private var lock = ParentalLock.shared
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ComicEntity.title, ascending: true)]
    ) private var allComics: FetchedResults<ComicEntity>

    @State private var comic: ComicEntity?
    @State private var didResolve = false

    var body: some View {
        Group {
            // A reader window opened before the lock (or restored at launch) must not
            // keep showing pages: the same lock screen as the main window
            // covers this one too.
            if lock.isLocked {
                ParentalLockGateView()
                    .lockScreenBackground()
            } else if let comic {
                ReaderView(comic: comic, libraryComics: Array(allComics))
            } else if didResolve {
                ContentUnavailableView(
                    "Fumetto non più disponibile",
                    systemImage: "questionmark.folder",
                    description: Text("Potrebbe essere stato rimosso dalla libreria.")
                )
            } else {
                ProgressView()
            }
        }
        .onAppear {
            comic = comicID.resolve(in: context)
            didResolve = true
        }
    }
}
#endif
