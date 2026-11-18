#if os(tvOS)
import SwiftUI
import CoreData

/// Root navigation for tvOS: a native top tab bar (`TabView` renders as tvOS's own capsule tab
/// bar automatically) with 6 text-labeled destinations, replacing the single shared
/// `NavigationStack { LibraryView() }` iOS also uses. Kept at 6, well under the tvOS 18
/// 8+-tab focus-stuck bug threshold (forums thread 769884) — a plain `TabView`, not
/// `.sidebarAdaptable`, which is the variant that regresses.
struct TVRootTabView: View {
    @EnvironmentObject private var viewModel: LibraryViewModel

    var body: some View {
        // The classic `.tabItem`-based TabView, not the `Tab(_:systemImage:content:)` struct
        // API (tvOS 18+ only) — this project's deployment target is tvOS 17.
        TabView {
            NavigationStack { LibraryView() }
                .tabItem { Text("Libreria") }

            NavigationStack { TVNowReadingTabView() }
                .tabItem { Text("In lettura") }

            NavigationStack { LibraryView(selection: .favorites) }
                .tabItem { Text("Preferiti") }

            // The standard tvOS search pattern: its own tab, `.searchable` inside the tab's
            // own NavigationStack (see `LibraryView.isSearchTab`).
            NavigationStack { LibraryView(isSearchTab: true) }
                .tabItem { Text("Cerca") }

            // No wrapping NavigationStack: AccountsView's tvOS body supplies its own (it's the root of this tab).
            AccountsView()
                .tabItem { Text("Account") }

            NavigationStack { TVSettingsView() }
                .tabItem { Text("Impostazioni") }
        }
        // Presented once, here: the Libreria and Preferiti tabs are two live `LibraryView`
        // instances bound to the same `importError`, so an alert on each could fire twice for
        // the same failure (or from a tab that isn't even on screen).
        .alert("Errore", isPresented: Binding(
            get: { viewModel.importError != nil },
            set: { if !$0 { viewModel.importError = nil } }
        )) {
        } message: {
            Text(viewModel.importError ?? "")
        }
    }
}

/// Large in-layout screen title shared by the tvOS tab roots — `.navigationTitle` overlays a
/// fixed screen position on tvOS instead of a sticky header (see tvOS-design-patterns.md), and
/// the same size/margins as the library's own title row keep the tabs consistent.
struct TVScreenTitle: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }
}

/// "In lettura" tab content: the single most recently opened comic, full-screen instead of the
/// small popover card `NowReadingView` shows on iOS/macOS — there's no toolbar button to anchor
/// a popover to here, this is its own destination.
private struct TVNowReadingTabView: View {
    @Environment(\.managedObjectContext) private var context
    @StateObject private var comicResults = SafeManagedObjectResults<ComicEntity>(request: {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "ComicEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ComicEntity.dateLastOpened, ascending: false)]
        return request
    }())
    @State private var selectedComic: ComicEntity?

    private var lastReadComic: ComicEntity? {
        comicResults.items.first { $0.dateLastOpened != nil && !$0.isFinished }
    }

    /// The library in its display order (series sections, then title — `LibraryGrouping`),
    /// for the reader's "Continuare con:": the fetch above is sorted by last-opened date, so
    /// handing it over as-is proposed the comic read *before* this one instead of the next issue.
    private var libraryOrder: [ComicEntity] {
        LibraryGrouping.sections(for: comicResults.items).flatMap(\.comics)
    }

    var body: some View {
        VStack(spacing: 0) {
            TVScreenTitle(title: "In lettura")
            if let comic = lastReadComic {
                VStack(spacing: 24) {
                    coverImage(for: comic)
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .frame(maxHeight: 480)
                        .cornerRadius(12)
                        .accessibilityHidden(true)

                    Text(comic.title ?? AppLocalization.localizedString("Senza titolo", comment: "Untitled comic fallback"))
                        .font(.title2.bold())

                    Text(pageProgress(for: comic))
                        .foregroundColor(.secondary)

                    // `.card` sizes its pill tightly around a bare label, no internal padding —
                    // confirmed cramped-looking on-device on the equivalent button in
                    // `TVComicDetailView`; same fix here.
                    Button(action: { selectedComic = comic }) {
                        Text("Riprendi")
                            .font(.headline)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.card)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Nessun fumetto in lettura", systemImage: "book.closed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $selectedComic) { comic in
            ReaderView(comic: comic, libraryComics: libraryOrder)
        }
        .onAppear { comicResults.start(in: context) }
        .onDisappear { comicResults.stop() }
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

    private func pageProgress(for comic: ComicEntity) -> String {
        let totalPages = max(Int(comic.pageCount), 1)
        let currentPage = min(max(Int(comic.lastReadPage) + 1, 1), totalPages)
        return "\(currentPage) / \(totalPages)"
    }
}

/// "Impostazioni" tab content: the tvOS home for screens that were previously unreachable there
/// (no trigger button existed anywhere in the tvOS UI for `ToolsPanelView`, so `SettingsView`,
/// `ParentalLockSettingsView` and most of `ColorThemeView` were compiled but dead code).
/// New rows go *after* the existing ones: the tvOS UI tests count Down presses to reach them.
private struct TVSettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            TVScreenTitle(title: "Impostazioni")
            List {
                NavigationLink("Lingua") { TVPopsOnMenu { AppLanguageSettings() } }
                    .tvOSRowBackground()
                NavigationLink("Aspetto") { TVPopsOnMenu { ColorThemeView() } }
                    .tvOSRowBackground()
                NavigationLink("Blocco genitori") { TVPopsOnMenu { ParentalLockSettingsView() } }
                    .tvOSRowBackground()
                RemoteProgressSyncToggle()
                    .tvOSRowBackground()
                NavigationLink("Lettura") { TVPopsOnMenu { TVReaderSettingsView() } }
                    .tvOSRowBackground()
                NavigationLink("Diagnostica") {
                    TVPopsOnMenu {
                        TVPanel(title: "Diagnostica") { EmptyView() } content: {
                            Form { DiagnosticsSections() }
                        }
                    }
                }
                .tvOSRowBackground()
                NavigationLink("Informazioni") { TVPopsOnMenu { AboutView() } }
                    .tvOSRowBackground()
                NavigationLink("Licenze open source") { TVPopsOnMenu { AcknowledgementsView() } }
                    .tvOSRowBackground()
            }
            .scrollClipDisabled(true)
        }
        // The system title is replaced by `TVScreenTitle` above, but the bar itself is left
        // alone (no `.toolbar(.hidden)`): hiding it at the root is what made Menu exit the
        // whole app from pushed screens under the Account tab (tvOS-design-patterns.md).
        // `TVPopsOnMenu` drives the pop explicitly on top of that, belt and braces.
        .navigationTitle("")
    }
}

/// Wraps a screen pushed from a tvOS tab root so Menu pops it explicitly instead of relying on
/// the system's inferred pop-vs-exit-app decision (see tvOS-design-patterns.md, "Hidden nav bar
/// at every level of a pushed stack breaks Menu's pop").
private struct TVPopsOnMenu<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: Content

    var body: some View {
        content.onExitCommand { dismiss() }
    }
}

/// The subset of `SettingsView`'s reader options that means something with a remote: no tap
/// zones, swipes, one-handed mode, hot corners or brightness gesture (no touch), and no
/// "Adatta larghezza" zoom mode (its scroll view can't take remote focus — tvOS has the
/// Play/Pause zoom instead, see `ReaderContentView.tvOSPager`).
private struct TVReaderSettingsView: View {
    @AppStorage("defaultReadingDirection") private var defaultReadingDirectionRawValue = ReadingDirection.leftToRight.rawValue
    @AppStorage("doublePageCoverAlone") private var isCoverAlone = true
    @AppStorage("tapPageTurnStyle") private var pageTurnStyle = TapPageTurnStyle.slide
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    @AppStorage("readerIdleResetSeconds") private var readerIdleReset = ReaderIdleResetOption.never

    private var defaultReadingDirection: Binding<ReadingDirection> {
        Binding(
            get: { ReadingDirection(rawValue: defaultReadingDirectionRawValue) ?? .leftToRight },
            set: { defaultReadingDirectionRawValue = $0.rawValue }
        )
    }

    var body: some View {
        TVPanel(title: "Lettura") { EmptyView() } content: {
            Form {
                TVOptionPickerSection(
                    title: Text("Direzione predefinita"),
                    footer: Text("Si applica ai nuovi fumetti importati. Puoi comunque cambiare la direzione per ogni fumetto dal lettore, con il pulsante Info."),
                    selection: defaultReadingDirection,
                    options: Array(ReadingDirection.allCases)
                ) { Text($0.label) }

                Section {
                    Toggle("Copertina da sola in doppia pagina", isOn: $isCoverAlone)
                }

                // "Disattivato" means "no tap zones" on iOS/macOS; the remote always turns
                // pages, so only the animation choices make sense here.
                TVOptionPickerSection(
                    title: Text("Animazione cambio pagina"),
                    selection: $pageTurnStyle,
                    options: TapPageTurnStyle.allCases.filter { $0 != .disabled }
                ) { Text($0.label) }

                Section(footer: Text("Il ritaglio bordi rimuove automaticamente i margini bianchi delle scansioni. L'upscaling migliora le pagine a bassa risoluzione.")) {
                    Toggle("Ritaglia bordi bianchi", isOn: $isAutoCropEnabled)
                    Toggle("Tinta e contrasto automatici", isOn: $isAutoTintContrastEnabled)
                    Toggle("Upscaling pagine a bassa risoluzione", isOn: $isUpscalingEnabled)
                }

                TVOptionPickerSection(
                    title: Text("Riparti dalla prima pagina"),
                    footer: Text("Se il lettore resta inattivo per il tempo scelto, torna automaticamente a pagina 1 — pensato per l'uso a schermo esposto (vetrina/kiosk), non per l'uso quotidiano."),
                    selection: $readerIdleReset,
                    options: Array(ReaderIdleResetOption.allCases)
                ) { Text($0.label) }
            }
        }
    }
}

#Preview {
    let controller = PersistenceController(inMemory: true)
    return TVRootTabView()
        .environment(\.managedObjectContext, controller.container.viewContext)
        .environmentObject(LibraryViewModel())
}
#endif
