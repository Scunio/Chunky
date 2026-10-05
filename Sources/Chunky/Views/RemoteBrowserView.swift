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
                    }
                    .buttonStyle(.card)
                }
                Button("Aggiorna", action: refreshLibrary)
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
        .onAppear { startPreflightIfNeeded(); load() }
        .onDisappear { localNetwork.stop() }
        .searchable(text: $searchText, prompt: "Cerca qui")
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
            }
        } else if entries.isEmpty {
            ContentUnavailableView("Nessun contenuto qui.", systemImage: "folder")
        } else if visibleEntries.isEmpty {
            ContentUnavailableView(
                "Nessun risultato",
                systemImage: "magnifyingglass",
                description: Text("Niente che contenga \"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\".")
            )
        } else {
            let folders = visibleEntries.filter(\.isContainer).count
            List {
                Section(header: Text("\(folders) cartelle · \(visibleEntries.count - folders) fumetti")) {
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
                Label(entry.title, systemImage: "folder")
            }
        } else {
            Button(action: { downloadAndImport(entry) }) {
                HStack {
                    Label(entry.title, systemImage: "book.closed")
                        .foregroundColor(.primary)
                    Spacer()
                    if downloadingEntryIDs.contains(entry.id) {
                        ProgressView()
                    } else {
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .disabled(downloadingEntryIDs.contains(entry.id))
        }
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
            return "host=\(host) share=\(share) port=\(account.portNumber) user=\(userDesc) pass=\(passDesc)"
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
            }
        } catch {
            let preflight = await MainActor.run { localNetwork.status }
            DiagnosticLog.log("SMB browse saved[\(savedDesc)] EPERM=\(error.isLocalNetworkDenied) preflight=\(preflight) err=\(error.localizedDescription)")
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

    private func downloadAndImport(_ entry: RemoteEntry) {
        downloadingEntryIDs.insert(entry.id)
        Task {
            do {
                let localURL = try await browser.download(entry, account: account)
                await MainActor.run {
                    viewModel.importFiles([localURL], into: context)
                    downloadingEntryIDs.remove(entry.id)
                }
            } catch {
                await MainActor.run {
                    viewModel.importError = error.chunkyFriendlyDescription
                    downloadingEntryIDs.remove(entry.id)
                }
            }
        }
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
