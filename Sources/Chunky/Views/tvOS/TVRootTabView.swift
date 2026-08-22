#if os(tvOS)
import SwiftUI
import CoreData

/// Root navigation for tvOS: a native top tab bar (`TabView` renders as tvOS's own capsule tab
/// bar automatically) with 5 text-labeled destinations, replacing the single shared
/// `NavigationStack { LibraryView() }` iOS also uses. Capped at 5, well under the tvOS 18
/// 8+-tab focus-stuck bug threshold (forums thread 769884) — a plain `TabView`, not
/// `.sidebarAdaptable`, which is the variant that regresses.
struct TVRootTabView: View {
    var body: some View {
        // The classic `.tabItem`-based TabView, not the `Tab(_:systemImage:content:)` struct
        // API (tvOS 18+ only) — this project's deployment target is tvOS 17.
        TabView {
            NavigationStack { LibraryView() }
                .tabItem { Label("Libreria", systemImage: "square.grid.2x2") }

            NavigationStack { TVNowReadingTabView() }
                .tabItem { Label("In lettura", systemImage: "book") }

            NavigationStack { LibraryView(selection: .favorites) }
                .tabItem { Label("Preferiti", systemImage: "star") }

            NavigationStack { AccountsView() }
                .tabItem { Label("Account", systemImage: "cloud") }

            NavigationStack { TVSettingsView() }
                .tabItem { Label("Impostazioni", systemImage: "gearshape") }
        }
    }
}

/// "In lettura" tab content: the single most recently opened comic, full-screen instead of the
/// small popover card `NowReadingView` shows on iOS/macOS — there's no toolbar button to anchor
/// a popover to here, this is its own destination.
private struct TVNowReadingTabView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ComicEntity.dateLastOpened, ascending: false)]
    ) private var comics: FetchedResults<ComicEntity>
    @State private var selectedComic: ComicEntity?

    private var lastReadComic: ComicEntity? {
        comics.first { $0.dateLastOpened != nil }
    }

    var body: some View {
        Group {
            if let comic = lastReadComic {
                VStack(spacing: 24) {
                    coverImage(for: comic)
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .frame(maxHeight: 520)
                        .cornerRadius(12)

                    Text(comic.title ?? "Senza titolo")
                        .font(.title2.bold())

                    Text("\(min(Int(comic.lastReadPage) + 1, max(Int(comic.pageCount), 1))) / \(comic.pageCount)")
                        .foregroundColor(.secondary)

                    Button("Riprendi") { selectedComic = comic }
                        .buttonStyle(.card)
                }
                .padding(60)
            } else {
                ContentUnavailableView("Nessun fumetto in lettura", systemImage: "book.closed")
            }
        }
        .navigationTitle("In lettura")
        .fullScreenCover(item: $selectedComic) { comic in
            ReaderView(comic: comic, libraryComics: Array(comics))
        }
    }

    @ViewBuilder
    private func coverImage(for comic: ComicEntity) -> some View {
        if let platformImage = CoverThumbnailCache.image(for: comic) {
            platformImage.asSwiftUIImage
                .resizable()
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .overlay(
                    Image(systemName: "book.closed")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                )
        }
    }
}

/// "Impostazioni" tab content: the tvOS home for screens that were previously unreachable there
/// (no trigger button existed anywhere in the tvOS UI for `ToolsPanelView`, so `SettingsView`,
/// `ParentalLockSettingsView` and most of `ColorThemeView` were compiled but dead code).
private struct TVSettingsView: View {
    var body: some View {
        List {
            NavigationLink("Aspetto") { ColorThemeView() }
                .tvOSRowBackground()
            NavigationLink("Blocco genitori") { ParentalLockSettingsView() }
                .tvOSRowBackground()
        }
        .scrollClipDisabled(true)
        .navigationTitle("Impostazioni")
    }
}
#endif
