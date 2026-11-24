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
    /// Only feeds "next comic in the library" (ordered by title): this window's own page turns
    /// must not refetch and republish it on every page.
    @StateObject private var comicResults = SafeComicResults(progressChangePolicy: .ignore)

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
                ReaderView(comic: comic, libraryComics: comicResults.comics)
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
        // Below this the header's icons and the page counter/slider overlap; with
        // `.windowResizability(.contentMinSize)` this becomes the window's minimum size.
        .frame(minWidth: 480, minHeight: 400)
        // Files opened from the Finder go to the library window (`OpenComicFilesFromFinder`),
        // never to a reader window, which has no handler for them.
        .handlesExternalEvents(preferring: [], allowing: [])
        .onAppear {
            comic = comicID.resolve(in: context)
            didResolve = true
            comicResults.start(in: context)
        }
        .onDisappear { comicResults.stop() }
    }
}

/// macOS handling of a comic file opened from the Finder ("Open With", double-click): imports
/// it like before, then opens its reader window once the import has registered it. A view
/// modifier rather than code in `ChunkyApp` because `openWindow` comes from a view's
/// environment.
struct OpenComicFilesFromFinder: ViewModifier {
    let viewModel: LibraryViewModel
    let context: NSManagedObjectContext
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
        // Without this, every file opened from the Finder made SwiftUI create a *new* window
        // of the main group (a second library, with its own sync loops) to deliver the URL.
        // An existing library window now takes it; a new one is created only if none is open.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in
            viewModel.importFiles([url], into: context) { paths in
                guard let path = paths.first else { return }
                let request = NSFetchRequest<ComicEntity>(entityName: "ComicEntity")
                request.predicate = NSPredicate(format: "relativePath == %@", path)
                request.fetchLimit = 1
                // A plain fetch (it reads the store, which the import's background context
                // has already saved to). If dedup folded the copy into an existing record
                // there's nothing to open: the import alone still happened, as before.
                guard let comic = (try? context.fetch(request))?.first, let id = ComicID(comic) else { return }
                openWindow(value: id)
            }
        }
    }
}
#endif
