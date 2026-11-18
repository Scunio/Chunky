import SwiftUI
import CoreData

struct RemoteBrowserView: View {
    let account: RemoteAccountEntity
    var startURL: URL?
    var title: String?

    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [RemoteEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var downloadingEntryIDs: Set<RemoteEntry.ID> = []
    @State private var searchText = ""
    @State private var isRefreshingLibrary = false
    /// Preflight "Rete locale" per gli account SMB: conferma il blocco privacy
    /// (PolicyDenied) invece di dedurlo dal solo EPERM del server (TN3179).
    @StateObject private var localNetwork = LocalNetworkPermission()
    /// Sheet modifica (best practice: stesso form di creazione in modalità edit).
    /// Solo root (`startURL == nil`): le sottocartelle non offrono modifica per non
    /// duplicare l'entry point in ogni livello di navigazione.
    @State private var isShowingEdit = false
    #if os(tvOS)
    /// Download/import failure shown right here: on tvOS the shared `importError` alert lives at
    /// the tab-bar root, and the user is on the Account tab looking at this list when it fails.
    @State private var downloadError: String?
    @Environment(\.tvOpenReader) private var openReader
    @Environment(\.tvPresentedReaderComicID) private var presentedReaderComicID
    @FocusState private var focusedEntryURL: URL?
    @State private var lastOpenedURL: URL?
    @State private var openedComicID: NSManagedObjectID?
    #elseif os(iOS)
    @State private var readerComic: ComicEntity?
    #elseif os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    /// `entry.url.absoluteString` of this account's files already downloaded into the library
    /// (non-placeholder records) — they get a checkmark and open in the reader on select.
    @State private var localSourcePaths: Set<String> = []

    private var browser: RemoteBrowsing { RemoteBrowsingFactory.makeBrowser(for: account.kind) }
    private var url: URL { startURL ?? account.serverURL ?? URL(string: "about:blank")! }

    var body: some View {
        // Same fix as `DownloadsView`/`ColorThemeView`: `.navigationTitle` overlays a fixed
        // screen position on tvOS instead of a sticky header, and a remote folder listing is
        // unbounded. `TVPanel` puts the title in the layout instead.
        #if os(tvOS)
        TVPanel(title: title ?? account.name ?? "Sfoglia") {
            HStack(spacing: 24) {
                if startURL == nil {
                    NavigationLink(destination: AddAccountView(editing: account, onDeleted: { dismiss() })) {
                        Text("Modifica")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.card)
                }
                // Nome esplicito: qui parte la scansione del NAS (segnaposto
                // leggeri, mai download se il pre-cache è spento), non un semplice
                // ricaricamento della vista come il pull-to-refresh su iOS.
                Button(action: refreshLibrary) {
                    Label(isRefreshingLibrary ? "Aggiornamento…" : "Aggiorna libreria", systemImage: "arrow.triangle.2.circlepath")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.card)
                .disabled(isLoading || isRefreshingLibrary)
            }
        } content: {
            browserContent
        }
        // Same missing-affordance fix as `DownloadsView` — pushed from the Account tab's
        // hidden-nav-bar `NavigationStack` root, so Menu would otherwise exit the whole app
        // instead of popping back (one level, whether that's the Account list or a parent
        // folder — recursion into a subfolder pushes another instance of this same view).
        .onExitCommand { dismiss() }
        .onChange(of: presentedReaderComicID) { old, new in
            guard new == nil, old != nil, old == openedComicID, let url = lastOpenedURL else { return }
            DispatchQueue.main.async { focusedEntryURL = url }
        }
        .onAppear { startPreflightIfNeeded(); load() }
        .onDisappear { localNetwork.stop() }
        .searchable(text: $searchText, prompt: "Cerca qui")
        .alert("Download non riuscito", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
        } message: {
            Text(downloadError ?? "")
        }
        #else
        browserContent
            .navigationTitle(title ?? account.name ?? "Sfoglia")
            .searchable(text: $searchText, prompt: "Cerca qui")
            .refreshable { await reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: refreshLibrary) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isLoading || isRefreshingLibrary)
                    .accessibilityLabel("Aggiorna libreria da qui")
                    .help("Cerca le novità sul NAS e ricarica (con il pre-cache spento non scarica niente)")
                }
                if startURL == nil {
                    ToolbarItem {
                        Button("Modifica") { isShowingEdit = true }
                    }
                }
            }
            .sheet(isPresented: $isShowingEdit) {
                AddAccountView(editing: account, onDeleted: { dismiss() })
            }
            #if os(iOS)
            .fullScreenCover(item: $readerComic) { comic in
                ReaderView(comic: comic)
            }
            #endif
            .onAppear { startPreflightIfNeeded(); load() }
            .onDisappear { localNetwork.stop() }
        #endif
    }

    /// Avvia il preflight "Rete locale" solo per SMB (unico a usare socket
    /// diretti con EPERM ambiguo). OPDS/WebDAV usano URLSession e non ne hanno bisogno.

    /// Voci filtrate dalla ricerca (filtro locale sui titoli già caricati).
    private var visibleEntries: [RemoteEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private var browserContent: some View {
        if isLoading && entries.isEmpty {
            ProgressView("Caricamento…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = errorMessage {
            ContentUnavailableView {
                Label("Impossibile caricare", systemImage: "exclamationmark.triangle")
            } description: {
                // Niente tasti qui di proposito: "Riprova" duplicherebbe il refresh
                // già sopra (toolbar/pull-to-refresh), e il deep-link alle
                // Impostazioni apre la pagina vuota dell'app — il toggle sta sotto
                // Privacy e sicurezza, raggiungibile solo a mano (vedi nota sotto).
                Text(errorMessage)
                if localNetwork.status == .denied {
                    #if os(tvOS)
                    Text("Percorso: Impostazioni → App → Chunky → \"Rete locale\".")
                    #elseif os(iOS)
                    Text("Percorso: Impostazioni → Privacy e sicurezza → Rete locale → Chunky.")
                    #elseif os(macOS)
                    Text("Percorso: Impostazioni di Sistema → Privacy e sicurezza → Rete locale → Chunky.")
                    #endif
                }
            } actions: {
                // tvOS has no pull-to-refresh and the header's "Aggiorna libreria" also rescans
                // the NAS: a plain retry of the listing belongs right on the error.
                #if os(tvOS)
                Button("Riprova", action: load)
                    .disabled(isLoading)
                #endif
            }
        } else if entries.isEmpty {
            ContentUnavailableView("Nessun contenuto qui.", systemImage: "folder")
        } else if visibleEntries.isEmpty {
            ContentUnavailableView(
                "Nessun risultato",
                systemImage: "magnifyingglass",
                description: Text(AppLocalization.format(
                    "Niente che contenga \"%@\".",
                    comment: "No remote browse results match the search query",
                    arguments: [searchText.trimmingCharacters(in: .whitespacesAndNewlines) as NSString]
                ))
            )
        } else {
            let folders = visibleEntries.filter(\.isContainer).count
            let folderSummary = AppLocalization.plural(
                folders,
                singularKey: "%d cartella",
                pluralKey: "%d cartelle",
                comment: "Remote browser folder count"
            )
            let comicCount = visibleEntries.count - folders
            let comicSummary = AppLocalization.plural(
                comicCount,
                singularKey: "%d fumetto",
                pluralKey: "%d fumetti",
                comment: "Remote browser comic count"
            )
            List {
                Section(header: Text("\(folderSummary) · \(comicSummary)")) {
                    ForEach(visibleEntries) { entry in
                        row(for: entry)
                    }
                }
            }
            .tvOSListFocusFix()
        }
    }

    @ViewBuilder
    private func row(for entry: RemoteEntry) -> some View {
        if entry.isContainer {
            NavigationLink(
                destination: RemoteBrowserView(account: account, startURL: entry.url, title: entry.title)
            ) {
                #if os(tvOS)
                tvOSEntryLabel(entry.title, systemImage: "folder")
                #else
                Label(entry.title, systemImage: "folder")
                #endif
            }
            #if os(tvOS)
            .tvOSRowBackground()
            #endif
        } else {
            Button(action: { select(entry) }) {
                HStack {
                    #if os(tvOS)
                    tvOSEntryLabel(entry.title, systemImage: "book.closed")
                    #else
                    Label(entry.title, systemImage: "book.closed")
                        .foregroundColor(.primary)
                    #endif
                    Spacer()
                    if downloadingEntryIDs.contains(entry.id) {
                        ProgressView()
                    } else if isDownloaded(entry) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .accessibilityLabel(Text("Scaricato"))
                    } else {
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundColor(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .disabled(downloadingEntryIDs.contains(entry.id))
            #if os(tvOS)
            .focused($focusedEntryURL, equals: entry.url)
            .tvOSRowBackground()
            #endif
        }
    }

    #if os(tvOS)
    /// Same spacing as `tvOSRowLabel` (tvOS draws `Label` with no icon–text gap), but the title
    /// is a file/folder name on the server: shown verbatim, never looked up as a localization
    /// key (a "%" in a file name would otherwise be read as a format specifier).
    private func tvOSEntryLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 24) {
            Image(systemName: systemImage)
                .frame(width: 44)
                .accessibilityHidden(true)
            Text(verbatim: title)
        }
    }
    #endif

    private func isDownloaded(_ entry: RemoteEntry) -> Bool {
        localSourcePaths.contains(entry.url.absoluteString)
    }

    /// Where a download failure goes: the shared library alert on iOS/macOS (unchanged), this
    /// screen's own alert on tvOS (see `downloadError`).
    private func reportDownloadFailure(_ error: Error) {
        #if os(tvOS)
        downloadError = error.chunkyFriendlyDescription
        #else
        viewModel.importError = error.chunkyFriendlyDescription
        #endif
    }

    /// Marks a finished download with a checkmark. "Finished" means the file arrived and
    /// its import was queued — `importFiles` has no completion, so a later import failure still
    /// surfaces through the shared alert at the tab-bar root.
    private func markDownloaded(_ entry: RemoteEntry) {
        localSourcePaths.insert(entry.url.absoluteString)
    }

    private func load() {
        Task { await reload() }
    }

    private func startPreflightIfNeeded() {
        if account.kind == .smb {
            localNetwork.check()
        } else {
            localNetwork.stop()
        }
    }

    private func reload() async {
        // Snapshot dei valori salvati sul MainActor PRIMA della chiamata di rete:
        // leggere un NSManagedObject dopo un await (altro executor) è unsafe e
        // senza questi il log non distinguerebbe "test OK" da "salvato diverso".
        // Mai la password, solo se presente o no.
        let savedDesc: String = await MainActor.run {
            let host = account.serverURL?.host ?? "?"
            let share = account.shareName ?? "?"
            let userDesc = (account.username?.isEmpty ?? true) ? "no" : (account.username ?? "si")
            let passDesc = (account.password?.isEmpty ?? true) ? "no" : "si"
            let shortID = account.stableID.uuidString.prefix(8)
            let kr = KeychainStore.readStatus(forAccount: account.stableID)
            return "id=\(shortID) host=\(host) share=\(share) port=\(account.portNumber) user=\(userDesc) pass=\(passDesc) kr=\(kr)"
        }
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        do {
            let loaded = try await browser.listEntries(at: url, account: account)
            await MainActor.run {
                entries = loaded
                isLoading = false
                refreshLocalSourcePaths()
            }
        } catch {
            let preflight = await MainActor.run { localNetwork.status }
            AppLog.log("SMB browse saved[\(savedDesc)] EPERM=\(error.isLocalNetworkDenied) preflight=\(preflight) err=\(error.localizedDescription)")
            await MainActor.run {
                errorMessage = error.chunkyFriendlyDescription
                isLoading = false
            }
        }
    }

    /// Riscansiona l'account (registra eventuali fumetti nuovi in libreria) e
    /// ricarica la cartella: la scansione automatica gira ogni 3 minuti, ma da
    /// qui l'utente non deve aspettarla.
    private func refreshLibrary() {
        isRefreshingLibrary = true
        Task {
            await RemoteAccountScanner.scan(account: account, context: context)
            await reload()
            await MainActor.run { isRefreshingLibrary = false }
        }
    }

    private func refreshLocalSourcePaths() {
        let request = ComicEntity.fetchRequest()
        request.predicate = NSPredicate(format: "sourceAccountID == %@ AND isRemotePlaceholder == NO", account.stableID as CVarArg)
        localSourcePaths = Set(((try? context.fetch(request)) ?? []).compactMap(\.sourceRelativePath))
    }

    /// Select on a file row: already downloaded -> open it; known placeholder -> download into it
    /// (the scan's pre-cache and this tap converge on one record, no "X 1" duplicate). With no
    /// record at all tvOS creates the placeholder like the scan does; iOS/macOS keep importing
    /// into the regular library (unless a legacy import of the same file name already exists).
    private func select(_ entry: RemoteEntry) {
        downloadingEntryIDs.insert(entry.id)
        // `@MainActor`: `account` è del view context e `browser.download` lo legge
        // in modo sincrono prima del primo await (stesso vincolo documentato in
        // `ComicDownloadService.downloadRemotePlaceholder`).
        Task { @MainActor in
            let sourcePath = entry.url.absoluteString
            let request = ComicEntity.fetchRequest()
            request.predicate = NSPredicate(format: "sourceAccountID == %@ AND sourceRelativePath == %@", account.stableID as CVarArg, sourcePath)
            request.fetchLimit = 1
            var comic = (try? context.fetch(request))?.first
            #if os(tvOS)
            if comic == nil {
                comic = RemoteAccountScanner.findOrCreatePlaceholder(entry: entry, account: account, context: context)
            }
            #else
            if comic == nil {
                let legacy = ComicEntity.fetchRequest()
                legacy.predicate = NSPredicate(format: "relativePath ==[c] %@ AND sourceAccountID == nil AND isRemotePlaceholder == NO", entry.title)
                legacy.fetchLimit = 1
                comic = (try? context.fetch(legacy))?.first
            }
            #endif

            if let comic {
                if !comic.isRemotePlaceholder {
                    markDownloaded(entry)
                    downloadingEntryIDs.remove(entry.id)
                    open(comic, entry: entry)
                    return
                }
                ComicDownloadService.downloadIfNeeded(comic: comic, completion: { error in
                    Task { @MainActor in
                        if let error {
                            reportDownloadFailure(error)
                        } else {
                            markDownloaded(entry)
                        }
                        downloadingEntryIDs.remove(entry.id)
                    }
                })
                return
            }
            do {
                let localURL = try await browser.download(entry, account: account)
                viewModel.importFiles(
                    [localURL],
                    into: context,
                    cleaningTemporaryDirectories: [localURL.deletingLastPathComponent()]
                )
                markDownloaded(entry)
                downloadingEntryIDs.remove(entry.id)
            } catch {
                reportDownloadFailure(error)
                downloadingEntryIDs.remove(entry.id)
            }
        }
    }

    private func open(_ comic: ComicEntity, entry: RemoteEntry) {
        #if os(tvOS)
        openedComicID = comic.objectID
        lastOpenedURL = entry.url
        openReader(comic, libraryComics: [])
        #elseif os(macOS)
        if let id = ComicID(comic) { openWindow(value: id) }
        #else
        readerComic = comic
        #endif
    }
}

#Preview {
    let controller = PersistenceController(inMemory: true)
    let context = controller.container.viewContext
    let account = RemoteAccountEntity.create(
        kind: .opds,
        name: "Anteprima",
        serverURLString: "http://192.168.1.10:8080/opds",
        username: nil,
        password: nil,
        in: context
    )
    return NavigationStack {
        RemoteBrowserView(account: account)
    }
    .environment(\.managedObjectContext, context)
    .environmentObject(LibraryViewModel())
}
