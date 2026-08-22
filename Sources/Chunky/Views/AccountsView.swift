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

#if os(tvOS)
private enum TVAccountCategory: Hashable {
    case downloads
    case web
    case account(NSManagedObjectID)
    case addAccount(RemoteAccountKind)
}
#endif

struct AccountsView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var viewModel: LibraryViewModel
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \RemoteAccountEntity.dateAdded, ascending: true)]
    ) private var accounts: FetchedResults<RemoteAccountEntity>

    /// Two distinct `.fileImporter`s on the same view conflict in SwiftUI (one of them
    /// gets stuck mid-presentation, with a visual artifact of the system picker that never
    /// fully opens) — so there's a single importer, with the content type chosen based on this state.
    private enum ActiveImporter: Identifiable {
        case comics
        case folder
        var id: Self { self }
    }

    @State private var isShowingAddAccount = false
    @State private var addAccountKind: RemoteAccountKind = .opds
    @State private var activeImporter: ActiveImporter?
    @State private var folderConversionError: String?
    /// "+" doesn't open another screen: it reveals the "Add account" section at the end of the
    /// same list and turns into "Done" to close it again. iOS/macOS only — tvOS's split view
    /// (see `tvOSSplitView`) always shows "Aggiungi account" as its own category instead.
    @State private var isAddingAccount = false
    /// Closes the sheet from `toolbarDoneButton` (no-op on tvOS — see `View+ToolbarDoneButton.swift`
    /// — where dismissal is instead the system Menu-button behavior on a plain `.sheet`).
    @Environment(\.dismiss) private var dismiss
    #if os(tvOS)
    @State private var selectedCategory: TVAccountCategory?
    #endif

    /// No system file picker on tvOS, so folder-based import has nothing to open there.
    private var folderConversionAvailable: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    private static let openServices: [OpenRemoteService] = [
        OpenRemoteService(name: "FTP / SFTP", systemImage: "network", tintColor: .primary),
        OpenRemoteService(name: "AFP", systemImage: "folder", tintColor: .primary),
        OpenRemoteService(name: "ComicStreamer", systemImage: "server.rack", tintColor: .primary),
        OpenRemoteService(name: "Image Comics", systemImage: "book.closed", tintColor: .primary),
        OpenRemoteService(name: "Transporter", systemImage: "shippingbox", tintColor: .primary),
        OpenRemoteService(name: "Dropbox", systemImage: "square.on.square", tintColor: .blue),
        OpenRemoteService(name: "Google Drive", systemImage: "triangle", tintColor: .green),
        OpenRemoteService(name: "OneDrive", systemImage: "icloud", tintColor: .blue),
        OpenRemoteService(name: "Amazon Cloud Drive", systemImage: "cloud", tintColor: .orange)
    ]

    var body: some View {
        panel
            .sheet(isPresented: $isShowingAddAccount) {
                AddAccountView(initialKind: addAccountKind)
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
                folderConversionError = error.localizedDescription
            case (_, .success(let urls)):
                viewModel.importFiles(urls, into: context)
            case (_, .failure):
                break
            }
        }
        #endif
    }

    /// iOS/macOS keep the system navigation bar and a single-column list; tvOS is a genuine
    /// split view (category list + detail pane) — see `tvOSSplitView`.
    @ViewBuilder
    private var panel: some View {
        #if os(tvOS)
        tvOSSplitView
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
                #else
                ToolbarItem(placement: .primaryAction) {
                    addAccountToggleButton
                }
                #endif
            }
        #endif
    }

    private var accountList: some View {
        List {
            Section(footer: Text("Server web spento")) {
                NavigationLink(destination: DownloadsView()) {
                    rowLabel("Downloads", systemImage: "arrow.down.circle")
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
                            rowLabel(account.name ?? "Account", systemImage: account.kind.systemImage)
                        }
                    }
                    .onDelete(perform: deleteAccounts)
                }
            }

            if isAddingAccount {
                Section(header: Text("Add account")) {
                    Button(action: { addAccountKind = .opds; isShowingAddAccount = true }) {
                        rowLabel("Calibre / Ubooquity / OPDS", systemImage: RemoteAccountKind.opds.systemImage)
                    }
                    .foregroundColor(.primary)

                    // No system file picker on tvOS: these open one (see the `.fileImporter` above).
                    #if !os(tvOS)
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
                    #endif

                    Button(action: { addAccountKind = .webdav; isShowingAddAccount = true }) {
                        rowLabel("Nuovo account WebDAV", systemImage: "plus.circle")
                    }
                    .foregroundColor(.primary)

                    Button(action: { addAccountKind = .smb; isShowingAddAccount = true }) {
                        rowLabel("Nuovo account SMB", systemImage: RemoteAccountKind.smb.systemImage)
                    }
                    .foregroundColor(.primary)
                }
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

    /// tvOS's native pattern for a filter→results screen (per the HIG's split-view guidance):
    /// categories (Downloads/Web/accounts/add-account) on the left, the selected one's content
    /// on the right — not a single-column list scrolling top to bottom like iOS/macOS. No
    /// NavigationStack here: both call sites already wrap this view in one.
    #if os(tvOS)
    private var tvOSSplitView: some View {
        NavigationSplitView {
            tvOSCategoryList
                .navigationTitle("Account")
                .tvOSListFocusFix()
        } detail: {
            tvOSDetailContent
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var tvOSCategoryList: some View {
        List(selection: $selectedCategory) {
            Section {
                rowLabel("Downloads", systemImage: "arrow.down.circle")
                    .tag(TVAccountCategory.downloads)
                    .tvOSRowBackground()
                rowLabel("Web", systemImage: "globe")
                    .tag(TVAccountCategory.web)
                    .tvOSRowBackground()
            }

            if !accounts.isEmpty {
                Section("I tuoi account") {
                    ForEach(accounts) { account in
                        rowLabel(account.name ?? "Account", systemImage: account.kind.systemImage)
                            .tag(TVAccountCategory.account(account.objectID))
                            .tvOSRowBackground()
                    }
                }
            }

            Section("Aggiungi account") {
                rowLabel("Calibre / Ubooquity / OPDS", systemImage: RemoteAccountKind.opds.systemImage)
                    .tag(TVAccountCategory.addAccount(.opds))
                    .tvOSRowBackground()
                rowLabel("Nuovo account WebDAV", systemImage: "plus.circle")
                    .tag(TVAccountCategory.addAccount(.webdav))
                    .tvOSRowBackground()
                rowLabel("Nuovo account SMB", systemImage: RemoteAccountKind.smb.systemImage)
                    .tag(TVAccountCategory.addAccount(.smb))
                    .tvOSRowBackground()
            }
        }
    }

    @ViewBuilder
    private var tvOSDetailContent: some View {
        switch selectedCategory {
        case .downloads:
            DownloadsView()
        case .web:
            LocalUploadView()
        case .account(let objectID):
            if let account = accounts.first(where: { $0.objectID == objectID }) {
                RemoteBrowserView(account: account)
            }
        case .addAccount(let kind):
            AddAccountView(initialKind: kind) { selectedCategory = .downloads }
        case nil:
            ContentUnavailableView("Scegli una categoria", systemImage: "cloud")
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
            Text(title)
        } icon: {
            Image(systemName: systemImage).foregroundColor(tint)
        }
        #endif
    }

    private var addAccountToggleButton: some View {
        Button(action: { withAnimation { isAddingAccount.toggle() } }) {
            if isAddingAccount {
                Text("Done")
            } else {
                Image(systemName: "plus")
            }
        }
        .accessibilityIdentifier("accounts.add")
    }

    private func deleteAccounts(at offsets: IndexSet) {
        for index in offsets {
            let account = accounts[index]
            KeychainStore.deletePassword(forAccount: account.resolvedID)
            context.delete(account)
        }
        try? context.save()
    }

    private func convertFolder(_ folderURL: URL) {
        folderConversionError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let comicURL = try FolderToComicConverter.makeComic(fromFolder: folderURL)
                DispatchQueue.main.async {
                    viewModel.importFiles([comicURL], into: context)
                }
            } catch {
                DispatchQueue.main.async {
                    folderConversionError = error.localizedDescription
                }
            }
        }
    }
}
