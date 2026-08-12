import SwiftUI
import CoreData
import UniformTypeIdentifiers

private enum LibraryDisplayMode: String {
    case grouped
    case alphabetical
}

private enum ReadStatus: CaseIterable, Identifiable {
    case unread
    case reading
    case finished

    var id: Self { self }

    var label: String {
        switch self {
        case .unread: "Non letto"
        case .reading: "In lettura"
        case .finished: "Terminato"
        }
    }
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
    @State private var isSearching = false
    @State private var isEditing = false
    @State private var selectedIDs: Set<NSManagedObjectID> = []
    @State private var collapsedGroups: Set<String> = []
    @State private var isNowReadingPresented = false
    @State private var isNewComicsPresented = false
    @AppStorage("newTrayClearedAt") private var newTrayClearedAtTimestamp: Double = 0
    @State private var isToolsPresented = false
    @State private var isAccountsPresented = false
    @State private var isNewGroupPromptPresented = false
    @State private var newGroupName = ""

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
            .sheet(isPresented: $isToolsPresented) {
                ToolsPanelView()
            }
            .sheet(isPresented: $isAccountsPresented) {
                NavigationView { AccountsView().toolbarDoneButton { isAccountsPresented = false } }
            }
            .modifier(NewGroupPromptModifier(isPresented: $isNewGroupPromptPresented, name: $newGroupName, onCreate: applyGroup))
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
            HStack(spacing: 16) {
                Button("Modifica") { isEditing = true }
                displayModeButton
            }
        }
    }

    @ViewBuilder
    private var trailingToolbarContent: some View {
        if isEditing {
            HStack(spacing: 16) {
                statusMenu
                    .disabled(selectedIDs.isEmpty)
                groupMenu
                    .disabled(selectedIDs.isEmpty)
                Button(action: deleteSelected) {
                    Image(systemName: "trash")
                }
                .disabled(selectedIDs.isEmpty)
            }
        } else {
            HStack(spacing: 16) {
                searchButton
                newComicsButton
                nowReadingButton
                if !isKioskModeEnabled {
                    accountsLink
                    toolsMenu
                } else {
                    settingsLink
                }
            }
        }
    }

    /// Un pannello ("Done"/"Accounts") come nell'originale, non una push a tutto schermo.
    /// È anche il punto in cui si importano i fumetti (Downloads / Web / iCloud Drive / altri
    /// servizi cloud): non esiste un pulsante "Importa" separato, confermato dallo screenshot
    /// dell'originale — niente busta duplicata.
    /// stesso trattamento di Tools, raggiunto dall'icona accanto.
    private var accountsLink: some View {
        Button(action: { isAccountsPresented = true }) {
            Image(systemName: "cloud")
        }
    }

    /// Apre il pannello "Tools" (Colori/Impostazioni/Blocco genitori/Feedback/Informazioni),
    /// come nell'originale.
    private var toolsMenu: some View {
        Button(action: { isToolsPresented = true }) {
            Image(systemName: "wrench.and.screwdriver")
        }
    }

    /// "Mark Selected" come nell'originale: segna i fumetti selezionati come Non letto/In
    /// lettura/Terminato agendo direttamente su `lastReadPage`, l'unico stato che il modello
    /// già tiene traccia (non serve un campo dedicato).
    private var statusMenu: some View {
        Menu {
            Picker("Stato", selection: statusBinding) {
                ForEach(ReadStatus.allCases) { status in
                    Text(status.label).tag(status)
                }
            }
        } label: {
            Image(systemName: "flag")
        }
    }

    /// "Grouping" come nell'originale: Auto ri-deriva il nome serie dal titolo (stessa euristica
    /// usata in import), altrimenti si assegna un gruppo esistente o se ne crea uno nuovo.
    private var groupMenu: some View {
        Menu {
            Picker("Gruppo", selection: groupBinding) {
                Text("Auto").tag(Self.autoGroupTag)
            }
            Button("Nuovo gruppo…") { isNewGroupPromptPresented = true }
            if !existingGroupNames.isEmpty {
                Picker("Gruppi esistenti", selection: groupBinding) {
                    ForEach(existingGroupNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
        } label: {
            Image(systemName: "rectangle.stack")
        }
    }

    private var selectedComics: [ComicEntity] {
        comics.filter { selectedIDs.contains($0.objectID) }
    }

    private func status(for comic: ComicEntity) -> ReadStatus {
        if comic.lastReadPage <= 0 { return .unread }
        if comic.isFinished { return .finished }
        return .reading
    }

    private var statusBinding: Binding<ReadStatus> {
        Binding(
            get: {
                let statuses = Set(selectedComics.map(status(for:)))
                return statuses.count == 1 ? statuses.first! : .reading
            },
            set: applyStatus
        )
    }

    private func applyStatus(_ status: ReadStatus) {
        for comic in selectedComics {
            switch status {
            case .unread:
                comic.lastReadPage = 0
                comic.dateLastOpened = nil
            case .reading:
                let count = comic.pageCount
                comic.lastReadPage = count > 1 ? min(max(comic.lastReadPage, 1), count - 2) : 0
                if comic.dateLastOpened == nil { comic.dateLastOpened = Date() }
            case .finished:
                comic.lastReadPage = max(comic.pageCount - 1, 0)
                if comic.dateLastOpened == nil { comic.dateLastOpened = Date() }
            }
        }
        try? context.save()
    }

    private static let autoGroupTag = "__auto__"

    private var existingGroupNames: [String] {
        Set(comics.compactMap(\.seriesName))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var groupBinding: Binding<String> {
        Binding(
            get: {
                let names = Set(selectedComics.map { $0.seriesName ?? Self.autoGroupTag })
                return names.count == 1 ? names.first! : Self.autoGroupTag
            },
            set: { applyGroup($0 == Self.autoGroupTag ? nil : $0) }
        )
    }

    private func applyGroup(_ name: String?) {
        for comic in selectedComics {
            comic.seriesName = name ?? LibraryViewModel.deriveSeriesName(fromFallbackTitle: comic.title ?? "")
        }
        try? context.save()
    }

    /// Icona lente in toolbar, come nell'originale: mostra/nasconde il campo di ricerca.
    private var searchButton: some View {
        Button(action: {
            withAnimation {
                isSearching.toggle()
                if !isSearching { searchText = "" }
            }
        }) {
            Image(systemName: "magnifyingglass")
        }
    }

    /// Testo (non icona), come nell'originale: alterna tra vista raggruppata per serie e A-Z.
    private var displayModeButton: some View {
        Button(displayMode == .grouped ? "Raggruppato" : "A-Z") {
            displayMode = displayMode == .grouped ? .alphabetical : .grouped
        }
    }

    /// Il fumetto aperto più di recente, se ce n'è almeno uno: alimenta il popover "Ora in lettura".
    private var lastReadComic: ComicEntity? {
        comics
            .filter { $0.dateLastOpened != nil }
            .max { ($0.dateLastOpened ?? .distantPast) < ($1.dateLastOpened ?? .distantPast) }
    }

    @ViewBuilder
    private var nowReadingButton: some View {
        if let comic = lastReadComic {
            Button(action: { isNowReadingPresented = true }) {
                Image(systemName: "book")
            }
            .popover(isPresented: $isNowReadingPresented) {
                NowReadingView(comic: comic) {
                    isNowReadingPresented = false
                    selectedComic = comic
                }
            }
        }
    }

    @ViewBuilder
    private var searchField: some View {
        if isSearching {
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

    /// Fumetti importati negli ultimi 7 giorni e non ancora "smarcati" con Cancella: alimentano
    /// il popover "Nuovi", non una sezione fissa in libreria (coerente con l'originale, dove i
    /// nuovi arrivi si consultano da un pannello dedicato, non restano incollati in cima).
    private var recentComics: [ComicEntity] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let clearedAt = Date(timeIntervalSince1970: newTrayClearedAtTimestamp)
        let effectiveCutoff = max(cutoff, clearedAt)
        return comics
            .filter { ($0.dateAdded ?? .distantPast) > effectiveCutoff }
            .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
    }

    /// Sempre visibile, anche senza fumetti nuovi (confermato dall'utente): a differenza
    /// dell'implementazione precedente, non si nasconde più quando `recentComics` è vuoto.
    private var newComicsButton: some View {
        Button(action: { isNewComicsPresented = true }) {
            Image(systemName: "envelope")
        }
        .popover(isPresented: $isNewComicsPresented) {
            NewComicsView(comics: recentComics) {
                selectedComic = $0
                isNewComicsPresented = false
            } onClear: {
                newTrayClearedAtTimestamp = Date().timeIntervalSince1970
                isNewComicsPresented = false
            }
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
                    Text(sectionHeaderText(title: title, comics: comics))
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

    /// "TOPOLINO 3594-3687" come nell'originale quando i titoli finiscono con un numero
    /// (es. testate periodiche): altrimenti solo il nome della serie.
    private func sectionHeaderText(title: String, comics: [ComicEntity]) -> String {
        guard title != Self.ungroupedSectionTitle else { return title.uppercased() }
        let numbers = comics.compactMap { issueNumber(fromTitle: $0.title ?? "") }
        guard let min = numbers.min(), let max = numbers.max(), numbers.count == comics.count else {
            return title.uppercased()
        }
        return min == max ? "\(title.uppercased()) \(min)" : "\(title.uppercased()) \(min)-\(max)"
    }

    private func issueNumber(fromTitle title: String) -> Int? {
        guard let range = title.range(of: #"\d+\s*$"#, options: .regularExpression) else { return nil }
        return Int(title[range])
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
        // Non un vero Button: su iOS il suo gesture recognizer del tap tende a intercettare
        // anche la pressione prolungata, impedendo al contextMenu sottostante di aprirsi.
        // L'accessibilità (VoiceOver, test automatici) resta comunque coperta dai trait/label
        // espliciti qui sotto.
        ComicGridItemView(comic: comic)
            .overlay(selectionBadge, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .accessibilityAddTraits(.isButton)
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

/// `.alert(_:isPresented:actions:)` con `TextField`/`Button(role:)` richiede iOS 15+: il target
/// minimo del progetto è iOS 14, quindi isoliamo qui il ramo `#available` invece di alzarlo
/// per l'intera app solo per questo prompt.
private struct NewGroupPromptModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var name: String
    let onCreate: (String) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 15.0, macOS 12.0, *) {
            content.alert("Nuovo gruppo", isPresented: $isPresented) {
                TextField("Nome gruppo", text: $name)
                Button("Annulla", role: .cancel) { name = "" }
                Button("Crea") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onCreate(trimmed) }
                    name = ""
                }
            }
        } else {
            content
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
