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
    /// Su macOS la sidebar decide quale serie mostrare; su iOS non esiste sidebar e la
    /// selezione resta sempre `.all`, quindi il comportamento non cambia.
    var selection: LibrarySelection = .all

    @Environment(\.managedObjectContext) private var context
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var lock = ParentalLock.shared
    #endif
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ComicEntity.title, ascending: true)]
    ) private var comics: FetchedResults<ComicEntity>

    @EnvironmentObject private var viewModel: LibraryViewModel
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage("kioskModeEnabled") private var isKioskModeEnabled = false
    @State private var isShowingFileImporter = false
    #if os(iOS)
    // Su Mac il reader vive in una finestra propria (vedi `openComic`); questo stato
    // esiste solo per il `.fullScreenCover` di iOS.
    @State private var selectedComic: ComicEntity?
    #endif
    @State private var displayMode: LibraryDisplayMode = .grouped
    @State private var searchText = ""
    @State private var isEditing = false
    @State private var selectedIDs: Set<NSManagedObjectID> = []
    @State private var collapsedGroups: Set<String> = []
    @State private var isNowReadingPresented = false
    @State private var isNewComicsPresented = false
    @AppStorage("newTrayClearedAt") private var newTrayClearedAtTimestamp: Double = 0
    #if os(macOS)
    /// Per finestra, non globale: aprire una seconda finestra libreria (in futuro) non deve
    /// costringerla alla stessa modalità di visualizzazione dell'altra.
    @SceneStorage("libraryUsesTableLayout") private var usesTableLayout = false
    #endif
    @State private var isToolsPresented = false
    @State private var isAccountsPresented = false
    @State private var isNewGroupPromptPresented = false
    @State private var newGroupName = ""
    /// Solo per l'indicazione visiva del drag & drop: non c'è altro stato da tracciare, il
    /// drop stesso è gestito interamente dentro `.dropDestination`.
    @State private var isDropTargeted = false

    var body: some View {
        content
            .navigationTitle(selection.groupTitle ?? "Chunky")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    leadingToolbarContent
                }
                // Ogni pulsante deve comparire come statement separato dentro il ViewBuilder,
                // non raggruppato in una singola "some View": solo così iOS li riconosce come
                // item nativi distinti e può metterli nel menu di overflow "•••" quando manca
                // spazio. Una view opaca finisce nell'overflow ma senza reagire al tap.
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isEditing {
                        statusMenu
                            .disabled(selectedIDs.isEmpty)
                        groupMenu
                            .disabled(selectedIDs.isEmpty)
                        Button(action: deleteSelected) {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedIDs.isEmpty)
                    } else {
                        addButton
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
                #else
                macOSToolbarContent
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
            .alert("Errore", isPresented: isErrorPresented) {
            } message: {
                Text(viewModel.importError ?? "")
            }
            // .sheet lascerebbe una card con angoli arrotondati che non copre tutto lo schermo.
            // Su Mac il reader vive in una finestra propria (vedi openComic), quindi qui non
            // c'è nulla da presentare.
            #if os(iOS)
            .fullScreenCover(item: $selectedComic) { comic in
                ReaderView(comic: comic, libraryComics: filteredComics)
            }
            #endif
            .sheet(isPresented: $isToolsPresented) {
                ToolsPanelView()
            }
            .sheet(isPresented: $isAccountsPresented) {
                NavigationStack { AccountsView().toolbarDoneButton { isAccountsPresented = false } }
                    .sheetSized()
            }
            #if os(macOS)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Cerca per titolo o serie")
            #else
            .searchable(text: $searchText, prompt: "Cerca per titolo o serie")
            #endif
            // Vale su entrambe le piattaforme: su iPad si può trascinare da Files, su Mac dal
            // Finder. `URL` è già `Transferable` di sistema (si rappresenta come URL di file),
            // quindi non serve altro che filtrare le estensioni supportate.
            .dropDestination(for: URL.self) { urls, _ in
                let supported = urls.filter { ComicFormat(fileExtension: $0.pathExtension) != nil }
                guard !supported.isEmpty else { return false }
                viewModel.importFiles(supported, into: context)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .modifier(NewGroupPromptModifier(isPresented: $isNewGroupPromptPresented, name: $newGroupName, onCreate: applyGroup))
            #if os(macOS)
            // `nil` mentre il blocco genitori è attivo: altrimenti un comando da tastiera
            // (⌘O, ⇧⌘N) agirebbe comunque sulla libreria da sotto la schermata di blocco.
            .focusedSceneValue(\.libraryActions, lock.isLocked ? nil : LibraryCommandActions(
                importFiles: { isShowingFileImporter = true },
                newGroup: { isNewGroupPromptPresented = true },
                isGroupedBySeries: Binding(
                    get: { displayMode == .grouped },
                    set: { displayMode = $0 ? .grouped : .alphabetical }
                ),
                isTableLayout: $usesTableLayout
            ))
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
            HStack(spacing: 16) {
                Button("Modifica") { isEditing = true }
                displayModeButton
            }
        }
    }

    #if os(macOS)
    // Ogni controllo è un `ToolbarItem` a sé, non un `HStack` dentro un `ToolbarItem` solo:
    // un'unica view opaca non si scompone correttamente nel menu "»" quando la finestra è
    // stretta — macOS riesce a farne un sottomenu solo per controlli nativi riconoscibili
    // (es. il Picker qui sotto, che diventa "Vista").
    @ToolbarContentBuilder
    private var macOSToolbarContent: some ToolbarContent {
        if isEditing {
            ToolbarItem {
                Button("Annulla") {
                    isEditing = false
                    selectedIDs.removeAll()
                }
            }
            ToolbarItem { statusMenu.disabled(selectedIDs.isEmpty) }
            ToolbarItem { groupMenu.disabled(selectedIDs.isEmpty) }
            ToolbarItem {
                Button(action: deleteSelected) {
                    Image(systemName: "trash")
                }
                .disabled(selectedIDs.isEmpty)
            }
        } else {
            ToolbarItem { Button("Modifica") { isEditing = true } }
            ToolbarItem { displayModeButton }
            ToolbarItem {
                Picker("Vista", selection: $usesTableLayout) {
                    // Label anche qui: se la finestra è stretta, l'intero Picker collassa in un
                    // sottomenu "Vista" — senza testo, le due voci sarebbero due icone identiche
                    // di forma ma senza indicazione di cosa selezionano.
                    Label("Griglia", systemImage: "square.grid.2x2").tag(false)
                    Label("Lista", systemImage: "list.bullet").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
                .accessibilityIdentifier("library.layoutPicker")
            }
            ToolbarItem { addButton }
            ToolbarItem { newComicsButton }
            ToolbarItem { nowReadingButton }
            if !isKioskModeEnabled {
                ToolbarItem { accountsLink }
                ToolbarItem { toolsMenu }
            } else {
                ToolbarItem { settingsLink }
            }
        }
    }
    #endif

    /// Pannello, non una push a tutto schermo. È anche il punto da cui si importano i fumetti
    /// (Downloads / Web / iCloud Drive / altri servizi cloud): non c'è un pulsante "Importa"
    /// separato.
    private var accountsLink: some View {
        Button(action: { isAccountsPresented = true }) {
            // Label, non Image da sola: quando questo pulsante finisce nel menu di overflow
            // (finestra stretta su Mac, o iPhone in orizzontale), un'icona senza testo non
            // spiega cosa fa. Label mostra solo l'icona nella toolbar normale e icona+testo
            // quando collassato in un menu.
            Label("Account", systemImage: "cloud")
        }
    }

    /// Apre il pannello "Tools" (Colori/Impostazioni/Blocco genitori/Feedback/Informazioni).
    private var toolsMenu: some View {
        Button(action: { isToolsPresented = true }) {
            Label("Strumenti", systemImage: "wrench.and.screwdriver")
        }
    }

    /// Segna i fumetti selezionati come Non letto/In lettura/Terminato agendo direttamente su
    /// `lastReadPage`, l'unico stato che il modello già tiene traccia (non serve un campo
    /// dedicato).
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

    /// Auto ri-deriva il nome serie dal titolo (stessa euristica usata in import), altrimenti si
    /// assegna un gruppo esistente o se ne crea uno nuovo.
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
                // Selezione mista (o vuota): il picker mostra "In lettura" senza applicare nulla.
                guard statuses.count == 1, let onlyStatus = statuses.first else { return .reading }
                return onlyStatus
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
                guard names.count == 1, let onlyName = names.first else { return Self.autoGroupTag }
                return onlyName
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

    /// Apre il picker di sistema (Files su iOS, NSOpenPanel su Mac) per importare fumetti —
    /// altrimenti raggiungibile solo da ⌘O su Mac o dallo stato vuoto della libreria, quindi
    /// invisibile una volta che la libreria contiene già qualcosa.
    private var addButton: some View {
        Button(action: { isShowingFileImporter = true }) {
            Label("Aggiungi", systemImage: "plus")
        }
    }

    /// Testo, non icona: alterna tra vista raggruppata per serie e A-Z.
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
                Label("Ora in lettura", systemImage: "book")
            }
            .popover(isPresented: $isNowReadingPresented) {
                NowReadingView(comic: comic) {
                    isNowReadingPresented = false
                    openComic(comic)
                }
            }
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
                #if os(macOS)
                if usesTableLayout {
                    LibraryTableView(comics: filteredComics, onSelect: openComic)
                } else {
                    libraryGrid
                }
                #else
                libraryGrid
                #endif
            }
        }
    }

    private var filteredComics: [ComicEntity] {
        var result = Array(comics)
        if let group = selection.groupTitle {
            result = result.filter { ($0.seriesName ?? LibraryGrouping.ungroupedTitle) == group }
        }
        guard !searchText.isEmpty else { return result }
        return result.filter { comic in
            (comic.title ?? "").localizedCaseInsensitiveContains(searchText)
                || (comic.seriesName ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedSections: [LibraryGrouping.Section] {
        LibraryGrouping.sections(for: filteredComics)
    }

    private var libraryGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                switch displayMode {
                case .grouped:
                    ForEach(groupedSections) { section in
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
    /// il popover "Nuovi", non una sezione fissa in libreria.
    private var recentComics: [ComicEntity] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let clearedAt = Date(timeIntervalSince1970: newTrayClearedAtTimestamp)
        let effectiveCutoff = max(cutoff, clearedAt)
        return comics
            .filter { ($0.dateAdded ?? .distantPast) > effectiveCutoff }
            .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
    }

    /// Sempre visibile, anche senza fumetti nuovi.
    private var newComicsButton: some View {
        Button(action: { isNewComicsPresented = true }) {
            Label("Novità", systemImage: "envelope")
        }
        .popover(isPresented: $isNewComicsPresented) {
            NewComicsView(comics: recentComics) {
                openComic($0)
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
                    Text(LibraryGrouping.headerText(title: title, comics: comics))
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
            openComic(comic)
        }
    }

    /// Unico punto da cui si "apre" un fumetto: su iOS imposta lo stato che presenta il
    /// `fullScreenCover`, su Mac apre una finestra indipendente (vedi `ComicID`,
    /// `ReaderWindowContainer`).
    private func openComic(_ comic: ComicEntity) {
        #if os(macOS)
        guard let id = ComicID(comic) else {
            // In pratica non dovrebbe capitare (l'inserimento salva l'entity sincronamente
            // prima che compaia nella griglia, quindi il suo objectID è già permanente), ma
            // se succede il tap non deve restare senza alcun riscontro: si riusa lo stesso
            // canale d'errore già in uso per gli import falliti.
            viewModel.importError = "Impossibile aprire questo fumetto."
            return
        }
        openWindow(value: id)
        #else
        selectedComic = comic
        #endif
    }

    private func deleteSelected() {
        for comic in filteredComics where selectedIDs.contains(comic.objectID) {
            viewModel.delete(comic, from: context)
        }
        selectedIDs.removeAll()
        isEditing = false
    }

    // MARK: - Misc

    private var isErrorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.importError != nil },
            set: { if !$0 { viewModel.importError = nil } }
        )
    }

    /// Il testo lo decide il view model (`importStatus`): la stessa passata di scansione che
    /// gira in automatico a ogni foreground mostrava "Importazione…" anche quando non stava
    /// importando niente, senza dire cosa stesse facendo.
    ///
    /// Colori espliciti e non ereditati: il riquadro è scuro fisso, ma `.foregroundColor(theme.text)`
    /// e `.accentColor(theme.accent)` più in basso si applicano anche a questo overlay — con un
    /// tema dal testo scuro, spinner ed etichetta finivano neri su nero e restava solo un
    /// rettangolo vuoto senza nulla scritto dentro.
    private var importingOverlay: some View {
        Group {
            if viewModel.isImporting {
                HStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text(viewModel.importStatus ?? "Importazione…")
                        .font(.callout)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color(white: 0.15).opacity(0.92))
                .cornerRadius(12)
                .shadow(radius: 8)
                .accessibilityElement(children: .combine)
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
        ContentUnavailableView {
            Label("La tua libreria è vuota", systemImage: "books.vertical")
        } description: {
            Text("Importa fumetti in formato CBZ, CBR o PDF per iniziare a leggere.")
        } actions: {
            Button(action: { isShowingFileImporter = true }) {
                Label("Importa fumetti", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var noResultsState: some View {
        ContentUnavailableView(
            "Nessun risultato per \"\(searchText)\"",
            systemImage: "magnifyingglass"
        )
    }
}

private struct ComicCell: View {
    let comic: ComicEntity
    let isEditing: Bool
    let isSelected: Bool
    let allowsDeletion: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    /// Stessa fonte del badge sulla copertina: il comando di download deve comparire e sparire
    /// insieme al badge, non a seconda di quando la cella è stata ridisegnata.
    @ObservedObject private var downloadTracker = ICloudDownloadTracker.shared

    private var isPendingDownload: Bool {
        guard let relativePath = comic.relativePath else { return false }
        return downloadTracker.pendingRelativePaths.contains(relativePath)
    }

    var body: some View {
        Button(action: onSelect) {
            ComicGridItemView(comic: comic)
                .overlay(selectionBadge, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(comic.title ?? "Fumetto")
        .contextMenu {
            if !isEditing {
                Button(action: onSelect) {
                    Label("Apri", systemImage: "book")
                }
                Button(action: toggleFavorite) {
                    Label(comic.isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                          systemImage: comic.isFavorite ? "star.slash" : "star")
                }
                if isPendingDownload {
                    Button(action: downloadFromICloud) {
                        Label("Scarica da iCloud", systemImage: "icloud.and.arrow.down")
                    }
                }
                #if os(macOS)
                Button(action: revealInFinder) {
                    Label("Mostra nel Finder", systemImage: "folder")
                }
                #endif
                if allowsDeletion {
                    Divider()
                }
            }
            if !isEditing && allowsDeletion {
                Button(role: .destructive, action: onDelete) {
                    Label("Rimuovi", systemImage: "trash")
                }
            }
        }
    }

    private func toggleFavorite() {
        comic.isFavorite.toggle()
        try? comic.managedObjectContext?.save()
    }

    /// Scarica senza aprire il lettore: il progresso si segue dalla schermata Downloads. La
    /// copertina e il numero di pagine arrivano subito dopo, quando `ICloudDownloadTracker` si
    /// accorge che il file è locale e fa partire il completamento dei segnaposto.
    private func downloadFromICloud() {
        ComicDownloadService.downloadIfNeeded(comic: comic)
    }

    #if os(macOS)
    private func revealInFinder() {
        let url = LibraryStorage.fileURL(forRelativePath: comic.relativePath ?? "")
        RevealInFinder.reveal(url)
    }
    #endif

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

private struct NewGroupPromptModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var name: String
    let onCreate: (String) -> Void

    func body(content: Content) -> some View {
        content.alert("Nuovo gruppo", isPresented: $isPresented) {
            TextField("Nome gruppo", text: $name)
            Button("Annulla", role: .cancel) { name = "" }
            Button("Crea") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { onCreate(trimmed) }
                name = ""
            }
        }
    }
}

extension UTType {
    static let cbz = UTType(exportedAs: "com.scunio.chunky.cbz")
    static let cbr = UTType(exportedAs: "com.scunio.chunky.cbr")
}
