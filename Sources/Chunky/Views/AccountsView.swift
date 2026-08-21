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
    /// same list and turns into "Done" to close it again.
    @State private var isAddingAccount = false

    /// No system file picker on tvOS, so folder-based import has nothing to open there.
    private var folderConversionAvailable: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    private static let openServices: [OpenRemoteService] = [
        OpenRemoteService(name: "Windows / Mac Shared Folder", systemImage: "folder", tintColor: .primary),
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
        List {
            Section(footer: Text("Server web spento")) {
                NavigationLink(destination: DownloadsView()) {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                NavigationLink(destination: LocalUploadView()) {
                    Label("Web", systemImage: "globe")
                }
                NavigationLink(destination: ICloudSyncFolderView()) {
                    Label("iCloud Drive", systemImage: "icloud")
                }
            }

            if !accounts.isEmpty {
                Section(header: Text("I tuoi account")) {
                    ForEach(accounts) { account in
                        NavigationLink(destination: RemoteBrowserView(account: account)) {
                            Label(account.name ?? "Account", systemImage: account.kind.systemImage)
                        }
                    }
                    .onDelete(perform: deleteAccounts)
                }
            }

            if isAddingAccount {
                Section(header: Text("Add account")) {
                    Button(action: { addAccountKind = .opds; isShowingAddAccount = true }) {
                        Label("Calibre / Ubooquity / OPDS", systemImage: RemoteAccountKind.opds.systemImage)
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
                        Label("Nuovo account WebDAV", systemImage: "plus.circle")
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
