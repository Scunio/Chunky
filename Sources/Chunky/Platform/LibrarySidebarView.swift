#if !os(tvOS)
import SwiftUI
import CoreData

/// Library sidebar (Mac, and iPad in a regular width — see `ContentView`).
///
/// - "Libreria": the cross-source views — all comics, now reading, favorites.
/// - "Sorgenti": the iCloud library and one entry per remote account (NAS/WebDAV/OPDS), each
///   opening a page with just that source's comics. Only when there are accounts: with the iCloud
///   library alone it would repeat "Tutti".
/// - "Serie": the same sections as the grid (`LibraryGrouping`), with the same counts.
///
/// New, Account and Tools stay in the toolbar: they're actions, not places.
struct LibrarySidebarView: View {
    @Binding var selection: LibrarySelection
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.managedObjectContext) private var context
    @StateObject private var comicResults = SafeComicResults()
    @StateObject private var accountResults = SafeManagedObjectResults<RemoteAccountEntity>(request: {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "RemoteAccountEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \RemoteAccountEntity.dateAdded, ascending: true)]
        return request
    }())
    @AppStorage(LibrarySources.includeRemoteInAllKey) private var includeRemoteInAll = false

    private var comics: [ComicEntity] { comicResults.comics }
    private var accounts: [RemoteAccountEntity] { accountResults.items }

    /// What "Tutti" and the series list draw from (see `LibrarySources.filter`).
    private var allPool: [ComicEntity] {
        LibrarySources.filter(comics, selection: .all, includeRemoteInAll: includeRemoteInAll)
    }

    private var sections: [LibraryGrouping.Section] {
        LibraryGrouping.sections(for: allPool)
    }

    private var favoritesCount: Int { comics.filter(\.isFavorite).count }
    private var readingCount: Int { comics.filter(LibrarySources.isReading).count }

    private func count(forAccount id: UUID?) -> Int {
        comics.filter { $0.sourceAccountID == id }.count
    }

    /// iOS's `List` takes only an optional single selection; tapping never clears it here.
    private var listSelection: Binding<LibrarySelection?> {
        Binding(get: { selection }, set: { if let newValue = $0 { selection = newValue } })
    }

    var body: some View {
        List(selection: listSelection) {
            librarySection
            if !accounts.isEmpty { sourcesSection }
            // The same sections as the grid (including "Other Comics" when present):
            // hiding it here would still leave it visible as a header in the
            // grid, misaligning sidebar and content instead of simplifying anything.
            if !sections.isEmpty { seriesSection }
        }
        .listStyle(.sidebar)
        .onAppear {
            comicResults.start(in: context)
            accountResults.start(in: context)
        }
        .onDisappear {
            comicResults.stop()
            accountResults.stop()
        }
        .accessibilityIdentifier("library.sidebar")
        .accentColor(theme.accent)
        // A selection whose target disappears (last comic of a series moved, account deleted,
        // nothing left to read) would leave the grid empty with no explanation: back to "Tutti".
        .onChange(of: sections.map(\.title)) { _, titles in
            if case .group(let title) = selection, !titles.contains(title) {
                selection = .all
            }
        }
        .onChange(of: favoritesCount) { _, count in
            if selection == .favorites, count == 0 { selection = .all }
        }
        .onChange(of: readingCount) { _, count in
            if selection == .reading, count == 0 { selection = .all }
        }
        .onChange(of: accounts.compactMap(\.id)) { _, ids in
            if case .source(let id?) = selection, !ids.contains(id) { selection = .all }
            if case .source(nil) = selection, ids.isEmpty { selection = .all }
        }
    }

    private var librarySection: some View {
        Section("Libreria") {
            Label("Tutti i fumetti", systemImage: "books.vertical")
                .badge(allPool.count)
                .tag(LibrarySelection.all)
                .accessibilityIdentifier("sidebar.all")
            if readingCount > 0 {
                Label("In lettura", systemImage: "book")
                    .badge(readingCount)
                    .tag(LibrarySelection.reading)
                    .accessibilityIdentifier("sidebar.reading")
            }
            if favoritesCount > 0 {
                Label("Preferiti", systemImage: "star")
                    .badge(favoritesCount)
                    .tag(LibrarySelection.favorites)
                    .accessibilityIdentifier("sidebar.favorites")
            }
        }
    }

    private var sourcesSection: some View {
        Section("Sorgenti") {
            Label("iCloud Drive", systemImage: "icloud")
                .badge(count(forAccount: nil))
                .tag(LibrarySelection.source(nil))
                .accessibilityIdentifier("sidebar.source.icloud")
            ForEach(accounts) { account in
                sourceRow(for: account)
            }
        }
    }

    private var seriesSection: some View {
        Section("Serie") {
            ForEach(sections) { section in
                Label(section.title, systemImage: section.title == LibraryGrouping.ungroupedTitle ? "tray" : "book.closed")
                    .badge(section.comics.count)
                    .tag(LibrarySelection.group(section.title))
            }
        }
    }

    @ViewBuilder
    private func sourceRow(for account: RemoteAccountEntity) -> some View {
        let hasError = !(account.lastScanError ?? "").isEmpty || account.needsPasswordOnThisDevice
        Label {
            Text(account.name ?? "Account")
        } icon: {
            Image(systemName: hasError ? "exclamationmark.triangle" : account.kind.systemImage)
                .foregroundStyle(hasError ? Color.orange : Color.accentColor)
        }
        .badge(count(forAccount: account.id))
        .tag(LibrarySelection.source(account.id))
        .help(hasError ? (account.needsPasswordOnThisDevice
                          ? AppLocalization.localizedString("Password richiesta su questo dispositivo: modifica l'account per inserirla.", comment: "Remote account synced from another device without its password")
                          : (account.lastScanError ?? "")) : "")
    }
}
#endif
