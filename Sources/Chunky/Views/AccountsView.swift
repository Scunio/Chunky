import SwiftUI
import CoreData
import UniformTypeIdentifiers

/// Service listed under "Add account": tapping it opens the system file picker, where
/// Dropbox/Google Drive/OneDrive show up automatically if the respective apps are installed
/// — there's no direct OAuth integration, and no in-app purchase system that would require
/// distinguishing "PRO" services from free ones.
private struct OpenRemoteService {
    let name: String
    let systemImage: String
    let tintColor: Color
}

struct AccountsView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.locale) private var locale
    @EnvironmentObject private var viewModel: LibraryViewModel
    @StateObject private var accountResults = SafeManagedObjectResults<RemoteAccountEntity>(request: {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "RemoteAccountEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \RemoteAccountEntity.dateAdded, ascending: true)]
        return request
    }())

    private var accounts: [RemoteAccountEntity] { accountResults.items }

    /// Two distinct `.fileImporter`s on the same view conflict in SwiftUI (one of them
    /// gets stuck mid-presentation, with a visual artifact of the system picker that never
    /// fully opens) — so there's a single importer, with the content type chosen based on this state.
    private enum ActiveImporter: Identifiable {
        case comics
        case folder
        var id: Self { self }
    }

    /// Unico sheet di questa vista (best practice SwiftUI): due `.sheet(isPresented:)`
    /// sulla stessa vista entrano in conflitto e presentano il foglio sbagliato o vuoto
    /// (schermata bianca da swipe → Modifica). Un enum identifica crea vs modifica.
    private enum AccountSheet: Identifiable {
        case add(RemoteAccountKind)
        case edit(RemoteAccountEntity)
        var id: String {
            switch self {
            case .add(let kind): return "add-\(kind.rawValue)"
            case .edit(let account): return account.objectID.uriRepresentation().absoluteString
            }
        }
    }

    @State private var activeSheet: AccountSheet?
    @State private var activeImporter: ActiveImporter?
    @State private var accountsToDelete: [RemoteAccountEntity] = []
    @State private var folderConversionError: String?
    /// "+" doesn't open another screen: it reveals the "Add account" section at the end of the
    /// same list and turns into "Done" to close it again. iOS/macOS only — tvOS's split view
    /// (see `tvOSSplitView`) always shows "Aggiungi account" as its own category instead.
    @State private var isAddingAccount = false
    #if os(tvOS)
    /// "Modifica" from a row's context menu: pushed programmatically (`navigationDestination`)
    /// — a `NavigationLink` inside a `.contextMenu` doesn't reliably push on tvOS, the menu is
    /// dismissed before the link's own navigation runs.
    @State private var accountBeingEdited: RemoteAccountEntity?
    /// "Sfoglia sul server" from a row's context menu: the row itself opens the account's comics
    /// in the library grid, the live browser stays one step away.
    @State private var accountBeingBrowsed: RemoteAccountEntity?
    #endif
    /// Closes the sheet from `toolbarDoneButton` (no-op on tvOS — see `View+ToolbarDoneButton.swift`
    /// — where dismissal is instead the system Menu-button behavior on a plain `.sheet`).
    @Environment(\.dismiss) private var dismiss

    /// No system file picker on tvOS, so folder-based import has nothing to open there.
    private var folderConversionAvailable: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    /// Scorciatoie al selettore file — non connessioni dirette. Solo voci per app
    /// con File Provider; niente protocolli non parlati (FTP/SFTP, AFP).
    private static let openServices: [OpenRemoteService] = [
        OpenRemoteService(name: "Dropbox", systemImage: "square.on.square", tintColor: .blue),
        OpenRemoteService(name: "Google Drive", systemImage: "triangle", tintColor: .green),
        OpenRemoteService(name: "OneDrive", systemImage: "icloud", tintColor: .blue)
    ]

    var body: some View {
        panel
            .confirmationDialog("Eliminare l'account?", isPresented: Binding(
                get: { !accountsToDelete.isEmpty },
                set: { if !$0 { accountsToDelete = [] } }
            ), titleVisibility: .visible) {
                Button("Elimina", role: .destructive, action: confirmDeleteAccounts)
                Button("Annulla", role: .cancel) { accountsToDelete = [] }
            }
            // Presented above the root lock screen, like the library's own sheets.
            .onReceive(ParentalLock.shared.$isLocked.removeDuplicates().filter { $0 }) { _ in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { activeSheet = nil }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .add(let kind):
                    AddAccountView(initialKind: kind)
                case .edit(let account):
                    AddAccountView(editing: account)
                }
            }
        // No system file picker on tvOS: the buttons that set `activeImporter` are hidden
        // there too (see below), so this never needs to present.
        #if !os(tvOS)
        .fileImporter(
            isPresented: Binding(
                get: { activeImporter != nil },
                set: { if !$0 { activeImporter = nil } }
            ),
            allowedContentTypes: activeImporter == .folder ? [.folder] : [.cbz, .cbr, .pdf],
            allowsMultipleSelection: activeImporter != .folder
        ) { result in
            switch (activeImporter, result) {
            case (.folder, .success(let urls)):
                if let folderURL = urls.first { convertFolder(folderURL) }
            case (.folder, .failure(let error)):
                folderConversionError = AppLocalization.userFacingError(error)
            case (_, .success(let urls)):
                viewModel.importFiles(urls, into: context)
            case (_, .failure):
                break
            }
        }
        #endif
        .onAppear { accountResults.start(in: context) }
        .onDisappear { accountResults.stop() }
    }

    /// iOS/macOS keep the system navigation bar and a single-column list; tvOS pushes into each
    /// destination instead (see `tvOSAccountList`) — matching Infuse's "Condivisioni" flow
    /// (confirmed via on-device photos), not a permanently-visible category/detail split.
    @ViewBuilder
    private var panel: some View {
        #if os(tvOS)
        tvOSAccountList
        #elseif os(macOS)
        macAccountForm
            .navigationTitle("Account")
            .frame(minWidth: 520, idealWidth: 560, minHeight: 420)
        #else
        accountList
            .navigationTitle("Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // Different placement per platform: on iOS `.primaryAction` lands on the same
                // side (trailing) as the "Close" of `toolbarDoneButton()` when this view is
                // presented as a sheet — the two end up crammed together.
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    addAccountToggleButton
                }
                #endif
            }
        #endif
    }

    #if os(macOS)
    /// System-Settings-style grouped form: the iOS list in a Mac sheet came out as cramped,
    /// tiny rows with no visible "+" (the sheet's toolbar isn't drawn there), so adding an
    /// account — the screen's main action — had no entry point at all.
    private var macAccountForm: some View {
        Form {
            Section {
                NavigationLink(destination: DownloadsView()) {
                    macRow(Text("Download"), systemImage: "arrow.down.circle", tint: .blue)
                }
                NavigationLink(destination: LocalUploadView()) {
                    macRow(Text("Web"), systemImage: "globe", tint: .teal, subtitle: AppLocalization.localizedString("Server web spento", comment: "Web upload server status"))
                }
                NavigationLink(destination: ICloudSyncFolderView()) {
                    macRow(Text("iCloud Drive"), systemImage: "icloud", tint: .cyan)
                }
            }

            Section(header: Text("I tuoi account")) {
                ForEach(accounts) { account in
                    let status = accountStatus(for: account)
                    NavigationLink(destination: RemoteBrowserView(account: account)) {
                        macRow(
                            Text(account.name ?? "Account"),
                            systemImage: account.kind.systemImage,
                            tint: .indigo,
                            subtitle: status.text,
                            subtitleIsError: status.isError
                        )
                    }
                    .contextMenu {
                        Button("Modifica") { activeSheet = .edit(account) }
                        Button("Elimina", role: .destructive) { accountsToDelete = [account] }
                    }
                }
                macAddAccountMenu
            }

            Section(
                header: Text("Strumenti"),
                footer: Text("Utile per una serie di pagine scansionate come immagini separate: verranno unite in un unico fumetto CBZ.")
            ) {
                Button(action: { activeImporter = .folder }) {
                    macRow(Text("Crea fumetto da cartella di immagini"), systemImage: "photo.stack", tint: .orange)
                }
                .buttonStyle(.plain)
                if let folderConversionError {
                    Text(folderConversionError).foregroundColor(.red).font(.footnote)
                }
                if let importError = viewModel.importError {
                    Text(importError).foregroundColor(.red).font(.footnote)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var macAddAccountMenu: some View {
        Menu {
            Button { activeSheet = .add(.opds) } label: {
                Label("Calibre / Ubooquity / OPDS", systemImage: RemoteAccountKind.opds.systemImage)
            }
            Button { activeSheet = .add(.webdav) } label: {
                Label("Nuovo account WebDAV", systemImage: "plus.circle")
            }
            Button { activeSheet = .add(.smb) } label: {
                Label("Nuovo account SMB", systemImage: RemoteAccountKind.smb.systemImage)
            }
            Divider()
            Section("Importa da file") {
                ForEach(Self.openServices, id: \.name) { service in
                    Button { activeImporter = .comics } label: {
                        Label(service.name, systemImage: service.systemImage)
                    }
                }
            }
        } label: {
            macRow(Text("Aggiungi account"), systemImage: "plus", tint: .green)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityIdentifier("accounts.add")
    }

    private func macRow(
        _ title: Text,
        systemImage: String,
        tint: Color,
        subtitle: String? = nil,
        subtitleIsError: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                title
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleIsError ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
    #endif

    private var accountList: some View {
        List {
            Section(footer: Text("Server web spento")) {
                NavigationLink(destination: DownloadsView()) {
                    rowLabel("Download", systemImage: "arrow.down.circle")
                }
                NavigationLink(destination: LocalUploadView()) {
                    rowLabel("Web", systemImage: "globe")
                }
                // No ubiquity container on tvOS (see `LibraryStorage.isICloudAvailable`), so
                // this screen would always show as permanently unavailable there.
                #if !os(tvOS)
                NavigationLink(destination: ICloudSyncFolderView()) {
                    rowLabel("iCloud Drive", systemImage: "icloud")
                }
                #endif
            }

            if !accounts.isEmpty {
                Section(header: Text("I tuoi account")) {
                    ForEach(accounts) { account in
                        NavigationLink(destination: RemoteBrowserView(account: account)) {
                            accountRow(for: account)
                        }
                        #if !os(tvOS)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Modifica") {
                                activeSheet = .edit(account)
                            }
                            .tint(.blue)
                        }
                        #endif
                        .contextMenu {
                            Button("Modifica") {
                                activeSheet = .edit(account)
                            }
                        }
                    }
                    .onDelete(perform: deleteAccounts)
                }
            }

            if isAddingAccount {
                Section(header: Text("Aggiungi account")) {
                    Button(action: { activeSheet = .add(.opds) }) {
                        rowLabel("Calibre / Ubooquity / OPDS", systemImage: RemoteAccountKind.opds.systemImage)
                    }
                    .foregroundColor(.primary)

                    Button(action: { activeSheet = .add(.webdav) }) {
                        rowLabel("Nuovo account WebDAV", systemImage: "plus.circle")
                    }
                    .foregroundColor(.primary)

                    Button(action: { activeSheet = .add(.smb) }) {
                        rowLabel("Nuovo account SMB", systemImage: RemoteAccountKind.smb.systemImage)
                    }
                    .foregroundColor(.primary)
                }

                // No system file picker on tvOS: these open one (see the `.fileImporter` above).
                #if !os(tvOS)
                Section(
                    header: Text("Importa da file"),
                    footer: Text("Apre il selettore file del sistema: i servizi cloud compaiono lì solo se hai le loro app installate.")
                ) {
                    ForEach(Self.openServices, id: \.name) { service in
                        Button(action: { activeImporter = .comics }) {
                            Label {
                                Text(service.name)
                            } icon: {
                                Image(systemName: service.systemImage)
                                    .foregroundColor(service.tintColor)
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }
                #endif
            // On tvOS, the folder-import feature this section exists for needs a system file
            // picker tvOS doesn't have (hidden below), so without a real import error to show
            // there'd be nothing left but an orphaned header/footer floating with no button.
            } else if viewModel.importError != nil || folderConversionAvailable {
                Section(
                    header: Group { if folderConversionAvailable { Text("Strumenti") } },
                    footer: Group {
                        if folderConversionAvailable {
                            Text("Utile per una serie di pagine scansionate come immagini separate: verranno unite in un unico fumetto CBZ.")
                        }
                    }
                ) {
                    #if !os(tvOS)
                    Button(action: { activeImporter = .folder }) {
                        Label("Crea fumetto da cartella di immagini", systemImage: "photo.stack")
                    }
                    if let folderConversionError = folderConversionError {
                        Text(folderConversionError)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                    #endif
                    // Also shown here (not just in LibraryView's alert) because that alert,
                    // tied to the view presenting this sheet, can stay invisible until
                    // the Accounts panel is closed.
                    if let importError = viewModel.importError {
                        Text(importError)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
        }
    }

    /// Infuse's "Condivisioni" pattern (confirmed via on-device photos): a persistent
    /// illustration panel on the left, a plain pushed list on the right — not a permanently
    /// split category/detail pane. Each row pushes into its destination via `NavigationLink`
    /// like every other tvOS screen in the app, instead of swapping a detail pane in place.
    /// Its own `NavigationStack`: this is the tvOS "Account" tab's root, nothing above it
    /// supplies one (see `TVRootTabView`).
    #if os(tvOS)
    private var tvOSAccountList: some View {
        NavigationStack {
            // Title in the layout (`TVScreenTitle`, same as the other tab roots). The nav bar is
            // left visible with an empty title, as in `TVSettingsView`: hiding it here left the
            // tab bar hidden after popping a scrolled-down pushed form (tvOS-design-patterns.md).
            VStack(alignment: .leading, spacing: 0) {
                TVScreenTitle(title: "Account")
                accountListBody
            }
            .navigationTitle("")
            .navigationDestination(item: $accountBeingEdited) { account in
                AddAccountView(editing: account)
            }
            .navigationDestination(item: $accountBeingBrowsed) { account in
                RemoteBrowserView(account: account)
            }
        }
    }

    private var accountListBody: some View {
        HStack(spacing: 0) {
            TVIllustrationPanel()
                .frame(width: 480)

            List {
                    Section {
                        NavigationLink(destination: DownloadsView()) {
                            rowLabel("Download", systemImage: "arrow.down.circle")
                        }
                        .tvOSRowBackground()
                        NavigationLink(destination: LocalUploadView()) {
                            rowLabel("Web", systemImage: "globe")
                        }
                        .tvOSRowBackground()
                    }

                    if !accounts.isEmpty {
                        Section {
                            ForEach(accounts) { account in
                                // The account's comics in the library grid (downloaded and not),
                                // instead of the live server browser: a big NAS import gets its
                                // own page, like the sidebar's "Sorgenti" on iPad and Mac.
                                NavigationLink(destination: LibraryView(selection: .source(account.id))) {
                                    accountRow(for: account)
                                }
                                .tvOSRowBackground()
                                .contextMenu {
                                    Button(action: { accountBeingBrowsed = account }) {
                                        Label("Sfoglia sul server", systemImage: "folder")
                                    }
                                    Button(action: { accountBeingEdited = account }) {
                                        Label("Modifica", systemImage: "pencil")
                                    }
                                }
                            }
                        } header: {
                            Text("I tuoi account").textCase(.uppercase)
                        }
                    }

                    Section {
                        NavigationLink(destination: AddAccountView(initialKind: .opds)) {
                            rowLabel("Calibre / Ubooquity / OPDS", systemImage: RemoteAccountKind.opds.systemImage)
                        }
                        .tvOSRowBackground()
                        NavigationLink(destination: AddAccountView(initialKind: .webdav)) {
                            rowLabel("Nuovo account WebDAV", systemImage: "plus.circle")
                        }
                        .tvOSRowBackground()
                        NavigationLink(destination: AddAccountView(initialKind: .smb)) {
                            rowLabel("Nuovo account SMB", systemImage: RemoteAccountKind.smb.systemImage)
                        }
                        .tvOSRowBackground()
                    } header: {
                        Text("Aggiungi account").textCase(.uppercase)
                    }
                }
            .listStyle(.plain)
            .tvOSListFocusFix()
        }
    }
    #endif

    /// tvOS renders `Label`'s icon and title with zero gap between them in list rows
    /// ("↓Downloads"); an explicit layout keeps a readable spacing there while iOS/macOS
    /// keep the system label with its own metrics.
    private func rowLabel(_ title: String, systemImage: String, tint: Color = .primary) -> some View {
        #if os(tvOS)
        tvOSRowLabel(title, systemImage: systemImage, tint: tint)
        #else
        Label {
            Text(LocalizedStringKey(title))
        } icon: {
            Image(systemName: systemImage).foregroundColor(tint)
        }
        #endif
    }

    private var scanDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = locale
        return formatter
    }

    /// Stato ultima scansione: errore (rosso) o data (grigia).
    private func accountStatus(for account: RemoteAccountEntity) -> (text: String, isError: Bool) {
        // Before the scan status: that one may come from the device where the account works.
        if account.needsPasswordOnThisDevice {
            return (AppLocalization.localizedString(
                "Password richiesta su questo dispositivo: modifica l'account per inserirla.",
                comment: "Remote account synced from another device without its password"
            ), true)
        }
        if let error = account.lastScanError, !error.isEmpty {
            return (error, true)
        }
        if let date = account.lastScanDate {
            return (AppLocalization.format(
                "Ultima scansione: %@",
                comment: "Account last scan date",
                arguments: [scanDateFormatter.string(from: date) as NSString]
            ), false)
        }
        return (AppLocalization.localizedString("Mai scansionato", comment: "Account has never been scanned"), false)
    }

    @ViewBuilder
    private func accountRow(for account: RemoteAccountEntity) -> some View {
        let status = accountStatus(for: account)
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 4) {
            tvOSRowLabel(account.name ?? "Account", systemImage: account.kind.systemImage)
            Text(status.text)
                // An error is the one thing on this row the user has to act on: readable from
                // the couch, not caption-sized.
                .font(status.isError ? .callout.weight(.semibold) : .caption)
                .foregroundColor(status.isError ? .red : .secondary)
                .lineLimit(3)
                .padding(.leading, 68)
        }
        #else
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name ?? "Account")
                Text(status.text)
                    .font(.caption)
                    .foregroundColor(status.isError ? .red : .secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: account.kind.systemImage)
        }
        #endif
    }

    private var addAccountToggleButton: some View {
        Button(action: { withAnimation { isAddingAccount.toggle() } }) {
            if isAddingAccount {
                Text("Fatto")
            } else {
                Image(systemName: "plus")
            }
        }
        .accessibilityIdentifier("accounts.add")
    }

    private func deleteAccounts(at offsets: IndexSet) {
        accountsToDelete = offsets.map { accounts[$0] }
    }

    private func confirmDeleteAccounts() {
        for account in accountsToDelete {
            // I segnaposto mai scaricati diventerebbero orfani: via subito.
            // I fumetti già scaricati restano in libreria, il NAS non si tocca.
            ComicEntity.deleteOrphanPlaceholders(ofAccountID: account.stableID, in: context)
            KeychainStore.deletePassword(forAccount: account.stableID)
            context.delete(account)
        }
        // Their downloads that an earlier version left in the iCloud root are the same files the
        // other devices list as iCloud comics: adopt them now instead of leaving orphans behind.
        ComicEntity.adoptOrphanedRootDownloads(in: context)
        accountsToDelete = []
        try? context.save()
    }

    private func convertFolder(_ folderURL: URL) {
        folderConversionError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let comicURL = try FolderToComicConverter.makeComic(fromFolder: folderURL)
                DispatchQueue.main.async {
                    viewModel.importFiles(
                        [comicURL],
                        into: context,
                        cleaningTemporaryDirectories: [comicURL.deletingLastPathComponent()]
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    folderConversionError = AppLocalization.userFacingError(error)
                }
            }
        }
    }
}

#Preview {
    let controller = PersistenceController(inMemory: true)
    return AccountsView()
        .environment(\.managedObjectContext, controller.container.viewContext)
        .environmentObject(LibraryViewModel())
}
