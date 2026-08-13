#if os(macOS)
import SwiftUI
import CoreData

/// Contenuto di una finestra reader su Mac, aperta con `openWindow(value: ComicID)`.
///
/// Risolve l'id in un `ComicEntity` al momento della comparsa: se il fumetto non c'è più
/// (cancellato, o store ricreato dopo un errore di caricamento — vedi `ComicID.resolve`),
/// mostra un placeholder invece di far crashare la finestra ripristinata da una sessione
/// precedente.
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
            // Una finestra reader aperta prima del blocco (o ripristinata all'avvio) non deve
            // continuare a mostrare le pagine: la stessa schermata di blocco della finestra
            // principale copre anche questa.
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
