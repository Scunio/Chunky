import SwiftUI
import CoreData
import UniformTypeIdentifiers

private enum LibraryDisplayMode: String {
    case grouped
    case alphabetical
}

struct LibraryView: View {
    /// On macOS the sidebar decides which series to show; on iOS there's no sidebar and the
    /// selection always stays `.all`, so the behavior doesn't change.
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
    #if os(iOS) || os(tvOS)
    // On Mac the reader lives in its own window (see `openComic`); this state
    // exists on iOS and tvOS for their shared `.fullScreenCover`.
    @State private var selectedComic: ComicEntity?
    #endif
    #if os(tvOS)
    // tvOS opens a detail screen (cover, metadata, "Leggi") before the reader — a cover tap
    // pushes here first; `TVComicDetailView`'s own button is what sets `selectedComic`.
    @State private var detailComic: ComicEntity?
    #endif
    #if os(iOS)
    // Mac picks `.favorites` from the sidebar, which sets `selection` directly; tvOS has its own
    // "Preferiti" tab that passes `selection: .favorites` in the same way (see `TVRootTabView`).
    // Only iOS has neither a sidebar nor a tab for it, so it gets a toolbar toggle instead,
    // layered on top via `effectiveSelection`.
    @State private var isFavoritesOnly = false
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
    /// Per window, not global: opening a second library window (in the future) shouldn't
    /// force it into the same display mode as the other one.
    @SceneStorage("libraryUsesTableLayout") private var usesTableLayout = false
    #endif
    @State private var isToolsPresented = false
    @State private var isAccountsPresented = false
    @State private var isNewGroupPromptPresented = false
    @State private var newGroupName = ""
    /// Only for the drag & drop visual indication: there's no other state to track, the
    /// drop itself is handled entirely inside `.dropDestination`.
    @State private var isDropTargeted = false

    private var effectiveSelection: LibrarySelection {
        #if os(iOS)
        isFavoritesOnly ? .favorites : selection
        #else
        selection
        #endif
    }

    private var libraryTitle: String {
        effectiveSelection == .favorites ? "Preferiti" : (effectiveSelection.groupTitle ?? "Chunky")
    }

    /// "Chunky" on the unfiltered library repeats what the "Libreria" tab already says —
    /// no real tvOS app (Apple TV app, Infuse, Netflix) re-announces its own name as a screen
    /// title on its home tab. Only worth a title row when it says something the tab bar
    /// doesn't: "Preferiti", or a series/group name.
    private var tvOSLibraryTitle: String? {
        effectiveSelection == .favorites ? "Preferiti" : effectiveSelection.groupTitle
    }

    /// `.navigationTitle` on tvOS overlays a fixed screen position instead of a sticky header —
    /// confirmed on-device, the same bug already fixed in `ColorThemeView`/`ParentalLockSettingsView`,
    /// here on the library's own title: scrolling the grid ran comic cards right through "Chunky".
    /// Putting the title in the layout instead (a real row above the `ScrollView`, not `TVPanel`
    /// — this view keeps its own toolbar/fileImporter/sheet modifiers below, unlike those two)
    /// fixes it the same way. When there's nothing worth saying (see `tvOSLibraryTitle`), the
    /// row is skipped instead of showing an empty gap — `libraryGrid`'s own top padding already
    /// clears the focus-scale/safe-area margin.
    @ViewBuilder
    private var titledContent: some View {
        #if os(tvOS)
        // `gridColumns`' 6-column math (1760pt content + 80pt margin each side = 1920pt,
        // the full screen width) assumes that 80pt margin is the ONLY inset — but SwiftUI
        // applies the system's own safe-area inset to this content by default, on top of
        // it, starving the grid of real width and clipping the last column off the right
        // edge (confirmed live: the 6th card in a row was visibly cut off). `.ignoresSafeArea()`
        // makes the explicit 80pt margin the sole authority, matching that math.
        if let title = tvOSLibraryTitle {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.largeTitle.bold())
                    .padding(.horizontal, gridHorizontalPadding)
                    .padding(.top, 60)
                    .padding(.bottom, 8)
                content
            }
            .ignoresSafeArea()
        } else {
            content
                .ignoresSafeArea()
        }
        #else
        content
        #endif
    }

    var body: some View {
        titledContent
            #if os(tvOS)
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            #else
            .navigationTitle(libraryTitle)
            #endif
            #if !os(tvOS)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    leadingToolbarContent
                }
                // Each button must appear as a separate statement inside the ViewBuilder,
                // not grouped into a single "some View": only this way does iOS recognize them as
                // distinct native items and can put them in the "•••" overflow menu when there's
                // no room. An opaque view ends up in the overflow but doesn't respond to taps.
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
                        favoritesFilterButton
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
            #endif
            // No system file picker on tvOS: `isShowingFileImporter` never becomes true there
            // (the toolbar's `addButton` and the empty state's import button are both
            // iOS/macOS-only — see below), so this never needs to present.
            #if !os(tvOS)
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.cbz, .cbr, .pdf],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    viewModel.importFiles(urls, into: context)
                }
            }
            #endif
            .alert("Errore", isPresented: isErrorPresented) {
            } message: {
                Text(viewModel.importError ?? "")
            }
            // .sheet would leave a card with rounded corners that doesn't cover the whole screen.
            // On Mac the reader lives in its own window (see openComic), so there's
            // nothing to present here.
            #if os(iOS) || os(tvOS)
            .fullScreenCover(item: $selectedComic) { comic in
                ReaderView(comic: comic, libraryComics: filteredComics)
            }
            #endif
            #if os(tvOS)
            .navigationDestination(item: $detailComic) { comic in
                TVComicDetailView(comic: comic) { selectedComic = comic }
            }
            #endif
            #if os(iOS)
            // Same fallback as the Mac sidebar: the last favorite unfavorited from under
            // this filter would otherwise leave it stuck showing an empty grid.
            .onChange(of: comics.contains(where: \.isFavorite)) { _, hasFavorites in
                if isFavoritesOnly, !hasFavorites { isFavoritesOnly = false }
            }
            #endif
            .sheet(isPresented: $isToolsPresented) {
                ToolsPanelView()
            }
            #if !os(tvOS)
            // On tvOS "Novità" is a section inline in the grid (see `newComicsSection`) and
            // "Ora in lettura" is its own root tab (`TVRootTabView`) — neither needs a sheet
            // here. Account is a tab too, but its own sheet above stays shared: `AccountsView`
            // is still reached this way from `ReaderView`'s header.
            .sheet(isPresented: $isAccountsPresented) {
                NavigationStack { AccountsView().toolbarDoneButton { isAccountsPresented = false } }
                    .sheetSized()
            }
            #endif
            #if os(macOS)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Cerca per titolo o serie")
            #elseif os(tvOS)
            // tvOS's .searchable field has no cancel/collapse affordance in the remote-driven
            // focus model — it renders as a permanently pinned field the user can't dismiss.
            #else
            .searchable(text: $searchText, prompt: "Cerca per titolo o serie")
            #endif
            // Holds on both platforms: on iPad you can drag from Files, on Mac from the
            // Finder. `URL` is already a system `Transferable` (it represents itself as a file URL),
            // so nothing more is needed than filtering the supported extensions.
            // No drag-and-drop source on tvOS (no Files/Finder equivalent), so `dropDestination`
            // itself is unavailable there.
            #if !os(tvOS)
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
            #endif
            .modifier(NewGroupPromptModifier(isPresented: $isNewGroupPromptPresented, name: $newGroupName, onCreate: applyGroup))
            #if os(macOS)
            // `nil` while the parental lock is active: otherwise a keyboard command
            // (⌘O, ⇧⌘N) would still act on the library from underneath the lock screen.
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
    // Each control is its own `ToolbarItem`, not an `HStack` inside a single `ToolbarItem`:
    // a single opaque view doesn't break down correctly into the "»" menu when the window is
    // narrow — macOS can only turn recognizable native controls into a submenu
    // (e.g. the Picker below, which becomes "View").
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
                    // Label here too: if the window is narrow, the whole Picker collapses into a
                    // "View" submenu — without text, the two entries would be two icons identical
                    // in shape but with no indication of what they select.
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

    /// Panel, not a full-screen push. It's also the entry point for importing comics
    /// (Downloads / Web / iCloud Drive / other cloud services): there's no separate "Import"
    /// button.
    private var accountsLink: some View {
        Button(action: { isAccountsPresented = true }) {
            // Label, not a bare Image: when this button ends up in the overflow menu
            // (narrow window on Mac, or iPhone in landscape), an icon without text doesn't
            // explain what it does. Label shows only the icon in the normal toolbar and icon+text
            // when collapsed into a menu.
            Label("Account", systemImage: "cloud")
        }
    }

    /// Opens the "Tools" panel (Colors/Settings/Parental Lock/Feedback/Info).
    private var toolsMenu: some View {
        Button(action: { isToolsPresented = true }) {
            Label("Strumenti", systemImage: "wrench.and.screwdriver")
        }
    }

    /// Marks the selected comics as Unread/Reading/Finished by acting directly on
    /// `lastReadPage`, the only state the model already tracks (no need for a
    /// dedicated field).
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

    /// Auto re-derives the series name from the title (same heuristic used at import time), otherwise
    /// an existing group is assigned or a new one is created.
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

    private var statusBinding: Binding<ReadStatus> {
        Binding(
            get: {
                let statuses = Set(selectedComics.map(readStatus(for:)))
                // Mixed (or empty) selection: the picker shows "Reading" without applying anything.
                guard statuses.count == 1, let onlyStatus = statuses.first else { return .reading }
                return onlyStatus
            },
            set: applyStatus
        )
    }

    private func applyStatus(_ status: ReadStatus) {
        for comic in selectedComics {
            status.apply(to: comic)
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

    /// Opens the system picker (Files on iOS, NSOpenPanel on Mac) to import comics —
    /// otherwise reachable only via ⌘O on Mac or from the library's empty state, so
    /// invisible once the library already has something in it.
    private var addButton: some View {
        Button(action: { isShowingFileImporter = true }) {
            Label("Aggiungi", systemImage: "plus")
        }
    }

    /// Text, not an icon: toggles between the view grouped by series and A-Z.
    private var displayModeButton: some View {
        Button(displayMode == .grouped ? "Raggruppato" : "A-Z") {
            displayMode = displayMode == .grouped ? .alphabetical : .grouped
        }
    }

    /// The most recently opened comic, if there's at least one: feeds the "Now Reading" popover.
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
            .platformPopover(isPresented: $isNowReadingPresented) {
                NowReadingView(comic: comic) {
                    isNowReadingPresented = false
                    openComic(comic)
                }
            }
        }
    }

    #if os(iOS)
    // Mac gets this for free from the sidebar's `.favorites` row; tvOS gets its own "Preferiti"
    // tab (`TVRootTabView`) passing `selection: .favorites` directly. Only iOS has neither, so
    // this toggles the same `effectiveSelection` machinery directly from the toolbar.
    @ViewBuilder
    private var favoritesFilterButton: some View {
        if isFavoritesOnly || comics.contains(where: \.isFavorite) {
            Button(action: { isFavoritesOnly.toggle() }) {
                Label("Preferiti", systemImage: isFavoritesOnly ? "star.fill" : "star")
            }
        }
    }
    #endif

    // MARK: - Content

    private var content: some View {
        Group {
            if comics.isEmpty && !viewModel.isImporting {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredComics.isEmpty {
                noResultsState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                #if os(macOS)
                if usesTableLayout {
                    LibraryTableView(
                        comics: filteredComics,
                        allowsDeletion: !isKioskModeEnabled,
                        onSelect: openComic,
                        onDelete: { viewModel.delete($0, from: context) }
                    )
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
        if let group = effectiveSelection.groupTitle {
            result = result.filter { ($0.seriesName ?? LibraryGrouping.ungroupedTitle) == group }
        } else if effectiveSelection == .favorites {
            result = result.filter(\.isFavorite)
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

    /// Gap between whole sections (end of one section's grid, start of the next section's
    /// header) — same reasoning as `tvOSSectionHeaderSpacing`/`tvOSGridRowSpacing`: a focused
    /// card's `.card` scale needs real margin on every side, not just within one section.
    /// Confirmed on-device: at 8pt, the next section's header text ("ALTRI FUMETTI", its count)
    /// visually collided with the previous section's last row of card titles.
    private var tvOSSectionGap: CGFloat {
        #if os(tvOS)
        56
        #else
        8
        #endif
    }

    private var libraryGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: tvOSSectionGap) {
                #if os(tvOS)
                // No separate "Novità" tab/popover on tvOS (see `TVRootTabView`): recently
                // added comics get their own section at the top of the grid instead, same
                // `sectionView` used for every other group. Only on the unfiltered "Libreria"
                // tab (`effectiveSelection == .all`) — on "Preferiti" or a series view this
                // section listed comics outside that selection, defeating the point of being
                // there (confirmed live: the Preferiti tab showed non-favorite comics under
                // "Novità" even though `filteredComics` itself was correctly favorites-only).
                if effectiveSelection == .all && !recentComics.isEmpty {
                    sectionView(title: "Novità", comics: recentComics)
                }
                #endif
                switch displayMode {
                case .grouped:
                    ForEach(groupedSections) { section in
                        sectionView(title: section.title, comics: section.comics)
                    }
                case .alphabetical:
                    Text("TUTTI I FUMETTI (\(filteredComics.count))")
                        .font(.subheadline.bold())
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, gridHorizontalPadding)
                    LazyVGrid(columns: gridColumns, spacing: tvOSGridRowSpacing) {
                        ForEach(filteredComics) { comic in
                            cell(for: comic)
                        }
                    }
                    .padding(.horizontal, gridHorizontalPadding)
                }
            }
            .padding(.vertical)
            #if os(tvOS)
            // Extra top/bottom padding on the scroll container so `.card`'s focus-scale
            // doesn't get clipped at the very top/bottom of the grid — same idiom Apple's own
            // "Destination Video" sample uses ("In tvOS, add vertical padding to accommodate
            // card resizing").
            .padding(.vertical, 60)
            #endif
        }
    }

    /// Comics imported in the last 7 days and not yet "unmarked" with Clear: feed
    /// the "New" popover, not a fixed section in the library.
    private var recentComics: [ComicEntity] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let clearedAt = Date(timeIntervalSince1970: newTrayClearedAtTimestamp)
        let effectiveCutoff = max(cutoff, clearedAt)
        return comics
            .filter { ($0.dateAdded ?? .distantPast) > effectiveCutoff }
            .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
    }

    /// Always visible, even without new comics.
    private var newComicsButton: some View {
        Button(action: { isNewComicsPresented = true }) {
            Label("Novità", systemImage: "envelope")
        }
        .platformPopover(isPresented: $isNewComicsPresented) {
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
        #if os(tvOS)
        // Fixed-size columns, not `.adaptive` (phone/tablet/Mac's sizing): tvOS's focus engine
        // and `.card` button style behave more predictably with fixed geometry, per Apple's own
        // "Destination Video" sample. 6 columns of 260×390pt (2:3 covers) fill the HIG-recommended
        // 1760pt safe-area width (1920 − 80pt each side) with 40pt gaps between them.
        Array(repeating: GridItem(.fixed(260), spacing: 40), count: 6)
        #else
        [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 16)]
        #endif
    }

    /// HIG side margin on tvOS (80pt); the default small inset everywhere else.
    private var gridHorizontalPadding: CGFloat {
        #if os(tvOS)
        80
        #else
        16
        #endif
    }

    private func sectionHeaderContent(title: String, comics: [ComicEntity]) -> some View {
        HStack {
            #if !os(tvOS)
            Image(systemName: collapsedGroups.contains(title) ? "chevron.right" : "chevron.down")
                .font(.caption.bold())
            #endif
            Text(LibraryGrouping.headerText(title: title, comics: comics))
                .font(.subheadline.bold())
            // On tvOS's wide grid, pushing this metadata to the far edge with a full-width
            // Spacer leaves it looking like an unrelated stray number — keep it next to the
            // title instead, like the row content below it. No "started" badge here (unlike
            // non-tvOS): each card already shows its own progress badge, so a section-level
            // one is redundant, and a bare "· INIZIATA" reads as a cryptic status label
            // instead of a count.
            #if os(tvOS)
            Text("\(comics.count) fumetti")
                .font(.caption)
                .foregroundColor(theme.secondaryText)
            Spacer()
            #else
            Spacer()
            if comics.contains(where: { $0.progress > 0 }) {
                Text("INIZIATA")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            Text("\(comics.count)")
                .font(.caption)
                .foregroundColor(theme.secondaryText)
            #endif
        }
        .padding(.horizontal, gridHorizontalPadding)
    }

    /// `.card`'s tvOS focus-scale is a transform, not a layout change: a focused card in the
    /// first grid row visibly grows up into the section header above it. Confirmed on a real
    /// device — a screenshot taken via `XCUIApplication.screenshot()` did NOT show this overlap
    /// (the system compositor's focus-scale effect isn't captured by that API), so don't trust
    /// automated screenshots to validate spacing fixes in this area — only a real on-device look.
    private var tvOSSectionHeaderSpacing: CGFloat {
        #if os(tvOS)
        40
        #else
        8
        #endif
    }

    private func sectionView(title: String, comics: [ComicEntity]) -> some View {
        VStack(alignment: .leading, spacing: tvOSSectionHeaderSpacing) {
            #if os(tvOS)
            // No collapsible-section pattern on tvOS (a full-width focusable header bar
            // is jarring on a TV) — the header is just a static label, always expanded.
            sectionHeaderContent(title: title, comics: comics)
            #else
            Button {
                withAnimation {
                    if collapsedGroups.contains(title) {
                        collapsedGroups.remove(title)
                    } else {
                        collapsedGroups.insert(title)
                    }
                }
            } label: {
                sectionHeaderContent(title: title, comics: comics)
            }
            .buttonStyle(PlainButtonStyle())
            #endif

            if !collapsedGroups.contains(title) {
                LazyVGrid(columns: gridColumns, spacing: tvOSGridRowSpacing) {
                    ForEach(comics) { comic in
                        cell(for: comic)
                    }
                }
                .padding(.horizontal, gridHorizontalPadding)
            }
        }
    }

    /// Same reasoning as `tvOSSectionHeaderSpacing`: a focused card's `.card` scale grows up
    /// into the row above it, not just down toward its own title. `LazyVGrid`'s default row
    /// spacing (20pt, fine on iOS/macOS where nothing scales on focus) isn't enough margin.
    private var tvOSGridRowSpacing: CGFloat {
        #if os(tvOS)
        40
        #else
        20
        #endif
    }

    private func cell(for comic: ComicEntity) -> some View {
        ComicCell(
            comic: comic,
            isEditing: isEditing,
            isSelected: selectedIDs.contains(comic.objectID),
            allowsDeletion: !isKioskModeEnabled,
            existingGroupNames: existingGroupNames,
            onSelect: { handleTap(on: comic) },
            onDelete: { viewModel.delete(comic, from: context) },
            onAssignGroup: { assignGroup($0, to: comic) }
        )
    }

    /// Same effect as `applyGroup`, for a single comic instead of the current bulk selection —
    /// used by `ComicCell`'s own context menu, the only per-comic entry point to grouping.
    private func assignGroup(_ name: String?, to comic: ComicEntity) {
        comic.seriesName = name ?? LibraryViewModel.deriveSeriesName(fromFallbackTitle: comic.title ?? "")
        try? context.save()
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

    /// The single place from which a comic is "opened": on iOS it sets the state that presents the
    /// `fullScreenCover`, on Mac it opens an independent window (see `ComicID`,
    /// `ReaderWindowContainer`).
    private func openComic(_ comic: ComicEntity) {
        #if os(macOS)
        guard let id = ComicID(comic) else {
            // In practice this shouldn't happen (insertion saves the entity synchronously
            // before it appears in the grid, so its objectID is already permanent), but
            // if it does happen the tap shouldn't go without any feedback: the same
            // error channel already used for failed imports is reused.
            viewModel.importError = "Impossibile aprire questo fumetto."
            return
        }
        openWindow(value: id)
        #elseif os(tvOS)
        detailComic = comic
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

    /// The text is decided by the view model (`importStatus`): the same scan pass that
    /// runs automatically on every foreground used to show "Importing…" even when it wasn't
    /// importing anything, without saying what it was actually doing.
    ///
    /// Explicit, non-inherited colors: the box is fixed dark, but `.foregroundColor(theme.text)`
    /// and `.accentColor(theme.accent)` further down also apply to this overlay — with a
    /// theme with dark text, the spinner and label ended up black on black and all that was left
    /// was an empty rectangle with nothing written inside it.
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
            #if os(tvOS)
            Text("Se hai già una libreria su iPhone o Mac con lo stesso Apple ID, comparirà qui automaticamente. Altrimenti apri \"Account\" per caricare fumetti da un browser sulla stessa rete.")
            #else
            Text("Importa fumetti in formato CBZ, CBR o PDF per iniziare a leggere.")
            #endif
        } actions: {
            // No system file picker on tvOS: import there only happens via `accountsLink`
            // (LocalUploadServer / iCloud), already in the tvOS toolbar.
            #if !os(tvOS)
            Button(action: { isShowingFileImporter = true }) {
                Label("Importa fumetti", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            #endif
        }
    }

    @ViewBuilder
    private var noResultsState: some View {
        // A search-phrased message is wrong when there was no search at all — e.g. the
        // "Preferiti" tab/filter with a non-empty library that just has nothing favorited yet.
        if searchText.isEmpty && effectiveSelection == .favorites {
            ContentUnavailableView("Nessun preferito", systemImage: "star")
        } else {
            ContentUnavailableView(
                "Nessun risultato per \"\(searchText)\"",
                systemImage: "magnifyingglass"
            )
        }
    }
}

private struct ComicCell: View {
    let comic: ComicEntity
    let isEditing: Bool
    let isSelected: Bool
    let allowsDeletion: Bool
    let existingGroupNames: [String]
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onAssignGroup: (String?) -> Void
    /// Same source as the cover badge: the download command must appear and disappear
    /// together with the badge, not depending on when the cell was last redrawn.
    @ObservedObject private var downloadTracker = ICloudDownloadTracker.shared

    private var isPendingDownload: Bool {
        guard let relativePath = comic.relativePath else { return false }
        return downloadTracker.pendingRelativePaths.contains(relativePath)
    }

    @ViewBuilder
    private var cellButton: some View {
        #if os(tvOS)
        // The title sits outside the Button, not inside `ComicGridItemView`'s combined
        // cover+title stack: nested inside the container that gets `.card`'s focus-scale
        // transform, it scaled and clipped awkwardly when focused (same fix Swiftfin's
        // `PosterButton` documents as "layout required for tvOS focused offset label behavior").
        // The gap below the button also needs to be real margin, not just rest-state spacing:
        // `.card`'s focus-scale grows the cover past its own frame without pushing the title
        // down, confirmed by an on-device photo showing the focused cover overlapping the title.
        VStack(alignment: .leading, spacing: 30) {
            Button(action: onSelect) {
                ComicCoverView(comic: comic)
                    .overlay(selectionBadge, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.card)
            .accessibilityLabel(comic.title ?? "Fumetto")

            // A ghost two-line block behind the real title, so every cell in a row reserves
            // the same title height regardless of whether this particular title wraps to one
            // line or two. Without it, a longer title (e.g. "Temple of the Lost King") made
            // its own row taller, and `.card`'s cover above it — bound to the same VStack —
            // shrank to compensate, ending up visibly shorter than its neighbors' covers in
            // the same row (confirmed live: covers misaligned/uneven heights across a row).
            ZStack(alignment: .topLeading) {
                Text("Two\nLines")
                    .opacity(0)
                    .accessibilityHidden(true)
                Text(comic.title ?? "Senza titolo")
                    .lineLimit(2)
            }
            .font(.caption.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        Button(action: onSelect) {
            ComicGridItemView(comic: comic)
                .overlay(selectionBadge, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(comic.title ?? "Fumetto")
        #endif
    }

    var body: some View {
        cellButton
        .contextMenu {
            if !isEditing {
                Button(action: onSelect) {
                    Label("Apri", systemImage: "book")
                }
                Button(action: toggleFavorite) {
                    Label(comic.isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                          systemImage: comic.isFavorite ? "star.slash" : "star")
                }
                // Same two states the bulk-selection status menu offers, but only the
                // ones that make sense to jump to directly from a single comic: not
                // already finished → mark read, not already untouched → mark unread.
                // "Reading" (a specific mid-book page) isn't a one-tap action.
                if readStatus(for: comic) != .finished {
                    Button(action: { markStatus(.finished) }) {
                        Label("Segna come letto", systemImage: "checkmark.circle")
                    }
                }
                if readStatus(for: comic) != .unread {
                    Button(action: { markStatus(.unread) }) {
                        Label("Segna come non letto", systemImage: "circle")
                    }
                }
                if isPendingDownload {
                    Button(action: downloadFromICloud) {
                        Label("Scarica da iCloud", systemImage: "icloud.and.arrow.down")
                    }
                }
                // Per-comic equivalent of the bulk-selection group menu (`LibraryView.groupMenu`,
                // iOS/macOS only, needs a multi-select mode tvOS doesn't have): no "new group"
                // text entry here, just auto-derive or an existing name, reachable from any
                // single comic's own context menu regardless of platform.
                Menu("Assegna a gruppo") {
                    Button("Automatico") { onAssignGroup(nil) }
                    ForEach(existingGroupNames, id: \.self) { name in
                        Button(name) { onAssignGroup(name) }
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

    private func markStatus(_ status: ReadStatus) {
        status.apply(to: comic)
        try? comic.managedObjectContext?.save()
    }

    /// Downloads without opening the reader: progress can be followed from the Downloads screen. The
    /// cover and page count arrive right after, when `ICloudDownloadTracker` notices
    /// that the file is now local and kicks off the placeholder completion.
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

#Preview {
    let controller = PersistenceController(inMemory: true)
    return NavigationStack {
        LibraryView()
    }
    .environment(\.managedObjectContext, controller.container.viewContext)
    .environmentObject(LibraryViewModel())
}
