import SwiftUI
import CoreData
import UniformTypeIdentifiers

private enum LibraryDisplayMode: String {
    case grouped
    case alphabetical
}

struct LibraryView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ComicEntity.title, ascending: true)]
    ) private var comics: FetchedResults<ComicEntity>

    @EnvironmentObject private var viewModel: LibraryViewModel
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage("kioskModeEnabled") private var isKioskModeEnabled = false
    @State private var isShowingFileImporter = false
    @State private var selectedComic: ComicEntity?
    @State private var displayMode: LibraryDisplayMode = .grouped
    @State private var searchText = ""
    @State private var isEditing = false
    @State private var selectedIDs: Set<NSManagedObjectID> = []
    @State private var collapsedGroups: Set<String> = []

    private static let ungroupedSectionTitle = "Altri fumetti"

    var body: some View {
        VStack(spacing: 0) {
            searchField
            content
        }
            .navigationTitle("Chunky")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    leadingToolbarContent
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    trailingToolbarContent
                }
                #else
                ToolbarItem {
                    leadingToolbarContent
                }
                ToolbarItem {
                    trailingToolbarContent
                }
                #endif
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.cbz, .cbr, .pdf],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    viewModel.importFiles(urls, into: context)
                }
            }
            .alert(item: errorBinding) { message in
                Alert(title: Text("Errore"), message: Text(message.text))
            }
            #if os(iOS)
            // A schermo intero come nell'originale: un .sheet normale su iOS resta una card
            // con angoli arrotondati che non copre tutto lo schermo (da cui lo spazio vuoto
            // sopra e lo slider quasi tagliato in fondo).
            .fullScreenCover(item: $selectedComic) { comic in
                ReaderView(comic: comic, libraryComics: filteredComics)
            }
            #else
            .sheet(item: $selectedComic) { comic in
                ReaderView(comic: comic, libraryComics: filteredComics)
            }
            #endif
            .overlay(importingOverlay)
            .background((theme.background ?? Color.clear).ignoresSafeArea())
            .foregroundColor(theme.text)
            .accentColor(theme.accent)
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var leadingToolbarContent: some View {
        if isEditing {
            Button("Annulla") {
                isEditing = false
                selectedIDs.removeAll()
            }
        } else {
            HStack {
                settingsLink
                if !isKioskModeEnabled {
                    accountsLink
                }
            }
        }
    }

    @ViewBuilder
    private var trailingToolbarContent: some View {
        if isEditing {
            HStack {
                Button(action: deleteSelected) {
                    Image(systemName: "trash")
                }
                .disabled(selectedIDs.isEmpty)
            }
        } else {
            HStack {
                displayModeButton
                if !isKioskModeEnabled {
                    importButton
                    Button("Modifica") { isEditing = true }
                }
            }
        }
    }

    private var accountsLink: some View {
        NavigationLink(destination: AccountsView()) {
            Label("Account", systemImage: "icloud")
        }
    }

    private var displayModeButton: some View {
        Button {
            displayMode = displayMode == .grouped ? .alphabetical : .grouped
        } label: {
            Image(systemName: displayMode == .grouped ? "square.grid.2x2" : "list.bullet")
        }
    }

    @ViewBuilder
    private var searchField: some View {
        if !comics.isEmpty {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Cerca per titolo o serie", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(10)
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    // MARK: - Content

    private var content: some View {
        Group {
            if comics.isEmpty && !viewModel.isImporting {
                emptyState
            } else if filteredComics.isEmpty {
                noResultsState
            } else {
                libraryGrid
            }
        }
    }

    private var filteredComics: [ComicEntity] {
        guard !searchText.isEmpty else { return Array(comics) }
        return comics.filter { comic in
            (comic.title ?? "").localizedCaseInsensitiveContains(searchText)
                || (comic.seriesName ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Serie ordinate alfabeticamente; i fumetti senza serie finiscono in una sezione a parte, in fondo.
    private var groupedSections: [(title: String, comics: [ComicEntity])] {
        let groups = Dictionary(grouping: filteredComics) { $0.seriesName ?? Self.ungroupedSectionTitle }
        return groups.keys.sorted { lhs, rhs in
            if lhs == Self.ungroupedSectionTitle { return false }
            if rhs == Self.ungroupedSectionTitle { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { key in (title: key, comics: groups[key]!.sorted { ($0.title ?? "") < ($1.title ?? "") }) }
    }

    private var libraryGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                newTray
                switch displayMode {
                case .grouped:
                    ForEach(groupedSections, id: \.title) { section in
                        sectionView(title: section.title, comics: section.comics)
                    }
                case .alphabetical:
                    Text("TUTTI I FUMETTI (\(filteredComics.count))")
                        .font(.subheadline.bold())
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(filteredComics) { comic in
                            cell(for: comic)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    /// Fumetti importati negli ultimi 7 giorni, in un tray orizzontale in cima alla libreria.
    private var recentComics: [ComicEntity] {
        guard searchText.isEmpty else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return comics
            .filter { ($0.dateAdded ?? .distantPast) >= cutoff }
            .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
    }

    @ViewBuilder
    private var newTray: some View {
        if !recentComics.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("NUOVI")
                    .font(.subheadline.bold())
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(recentComics) { comic in
                            cell(for: comic)
                                .frame(width: 130)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 16)]
    }

    private func sectionView(title: String, comics: [ComicEntity]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation {
                    if collapsedGroups.contains(title) {
                        collapsedGroups.remove(title)
                    } else {
                        collapsedGroups.insert(title)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: collapsedGroups.contains(title) ? "chevron.right" : "chevron.down")
                        .font(.caption.bold())
                    Text(title.uppercased())
                        .font(.subheadline.bold())
                    Spacer()
                    if comics.contains(where: { $0.progress > 0 }) {
                        Text("INIZIATA")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("\(comics.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .foregroundColor(.primary)
                .padding(.horizontal)
            }
            .buttonStyle(PlainButtonStyle())

            if !collapsedGroups.contains(title) {
                LazyVGrid(columns: gridColumns, spacing: 20) {
                    ForEach(comics) { comic in
                        cell(for: comic)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func cell(for comic: ComicEntity) -> some View {
        ComicCell(
            comic: comic,
            isEditing: isEditing,
            isSelected: selectedIDs.contains(comic.objectID),
            allowsDeletion: !isKioskModeEnabled,
            onSelect: { handleTap(on: comic) },
            onDelete: { viewModel.delete(comic, from: context) }
        )
    }

    private func handleTap(on comic: ComicEntity) {
        if isEditing {
            if selectedIDs.contains(comic.objectID) {
                selectedIDs.remove(comic.objectID)
            } else {
                selectedIDs.insert(comic.objectID)
            }
        } else {
            selectedComic = comic
        }
    }

    private func deleteSelected() {
        for comic in filteredComics where selectedIDs.contains(comic.objectID) {
            viewModel.delete(comic, from: context)
        }
        selectedIDs.removeAll()
        isEditing = false
    }

    // MARK: - Misc

    private var errorBinding: Binding<AlertMessage?> {
        Binding(
            get: { viewModel.importError.map { AlertMessage(text: $0) } },
            set: { _ in viewModel.importError = nil }
        )
    }

    private var importingOverlay: some View {
        Group {
            if viewModel.isImporting {
                ProgressView("Importazione…")
                    .padding()
                    .background(Color(white: 0.15).opacity(0.9))
                    .cornerRadius(12)
            } else {
                EmptyView()
            }
        }
    }

    private var importButton: some View {
        Button {
            isShowingFileImporter = true
        } label: {
            Label("Importa", systemImage: "plus")
        }
    }

    private var settingsLink: some View {
        NavigationLink(destination: SettingsView()) {
            Label("Impostazioni", systemImage: "gearshape")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("La tua libreria è vuota")
                .font(.title3.bold())
            Text("Importa fumetti in formato CBZ, CBR o PDF per iniziare a leggere.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(action: { isShowingFileImporter = true }) {
                Label("Importa fumetti", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Nessun risultato per \"\(searchText)\"")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ComicCell: View {
    let comic: ComicEntity
    let isEditing: Bool
    let isSelected: Bool
    let allowsDeletion: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ComicGridItemView(comic: comic)
                .overlay(selectionBadge, alignment: .topLeading)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(comic.title ?? "Fumetto")
        .contextMenu {
            if !isEditing && allowsDeletion {
                Button(action: onDelete) {
                    Label("Rimuovi", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isEditing {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .white)
                .background(Circle().fill(isSelected ? Color.white : Color.black.opacity(0.4)))
                .padding(6)
        }
    }
}

private struct AlertMessage: Identifiable {
    let id = UUID()
    let text: String
}

extension UTType {
    static let cbz = UTType(exportedAs: "com.scunio.chunky.cbz")
    static let cbr = UTType(exportedAs: "com.scunio.chunky.cbr")
}
