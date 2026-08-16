#if os(macOS)
import SwiftUI
import CoreData

/// Mac sidebar: "All Comics" plus the series already present in the library.
///
/// Contains only what exists: the same labels and the same counts as the grid's
/// collapsible sections (`LibraryGrouping`). New, Now Reading, Account and
/// Tools stay where they've always been, i.e. in the toolbar — they don't become
/// navigation items.
struct LibrarySidebarView: View {
    @Binding var selection: LibrarySelection
    @ObservedObject private var theme = AppTheme.shared

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ComicEntity.title, ascending: true)]
    ) private var comics: FetchedResults<ComicEntity>

    private var sections: [LibraryGrouping.Section] {
        LibraryGrouping.sections(for: Array(comics))
    }

    var body: some View {
        List(selection: $selection) {
            Label("Tutti i fumetti", systemImage: "books.vertical")
                .badge(comics.count)
                .tag(LibrarySelection.all)
                .accessibilityIdentifier("sidebar.all")

            // The same sections as the grid (including "Other Comics" when present):
            // hiding it here would still leave it visible as a header in the
            // grid, misaligning sidebar and content instead of simplifying anything.
            if !sections.isEmpty {
                Section("Serie") {
                    ForEach(sections) { section in
                        Label(section.title, systemImage: section.title == LibraryGrouping.ungroupedTitle
                              ? "tray" : "book.closed")
                            .badge(section.comics.count)
                            .tag(LibrarySelection.group(section.title))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("library.sidebar")
        .accentColor(theme.accent)
        // If the selected group stops existing (last comic moved elsewhere or
        // deleted), the sidebar removes it from the list on its own, but the selection
        // would stay pointed at it anyway: the grid would show "no results" for an empty
        // search, with no way to understand why. It falls back to "All Comics".
        .onChange(of: sections.map(\.title)) { _, titles in
            if case .group(let title) = selection, !titles.contains(title) {
                selection = .all
            }
        }
    }
}
#endif
