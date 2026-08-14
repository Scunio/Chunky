import SwiftUI
import CoreData
import UniformTypeIdentifiers

/// Servizio elencato in "Add account": qui il tocco apre il picker file di sistema, dove
/// Dropbox/Google Drive/OneDrive compaiono automaticamente se le rispettive app sono installate
/// — non essendoci integrazione OAuth diretta, e nessun sistema di acquisto in-app che richieda
/// di distinguere servizi "PRO" da quelli gratuiti.
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

    /// Due `.fileImporter` distinti sulla stessa view vanno in conflitto in SwiftUI (uno dei due
    /// resta a metà presentazione, con un artefatto visivo del picker di sistema che non si apre
    /// mai del tutto) — un solo importer, con il tipo di contenuto scelto in base a questo stato.
    private enum ActiveImporter: Identifiable {
        case comics
        case folder
        var id: Self { self }
    }

    @State private var isShowingAddAccount = false
    @State private var addAccountKind: RemoteAccountKind = .opds
    @State private var activeImporter: ActiveImporter?
    @State private var folderConversionError: String?
    /// "+" non apre un altro schermo: rivela la sezione "Add account" in coda alla stessa lista
    /// e diventa "Done" per richiuderla.
    @State private var isAddingAccount = false

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
        OpenRemoteService(name: "Amazon Cloud Drive", systemImage: "cloud", tintColor: .orange),
    ]

    var body: some View {
        List {
            Section {
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

                    Button(action: { addAccountKind = .webdav; isShowingAddAccount = true }) {
                        Label("Nuovo account WebDAV", systemImage: "plus.circle")
                    }
                    .foregroundColor(.primary)
                }
            } else {
                Section(
                    header: Text("Strumenti"),
                    footer: Text("Utile per una serie di pagine scansionate come immagini separate: verranno unite in un unico fumetto CBZ.")
                ) {
                    Button(action: { activeImporter = .folder }) {
                        Label("Crea fumetto da cartella di immagini", systemImage: "photo.stack")
                    }
                    if let folderConversionError = folderConversionError {
                        Text(folderConversionError)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                    // Mostrato anche qui (non solo nell'alert di LibraryView) perché quell'alert,
                    // legato alla view che presenta questo sheet, può restare invisibile finché
                    // il pannello Accounts non viene chiuso.
                    if let importError = viewModel.importError {
                        Text(importError)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }

            Section(footer: Text("Server web spento")) {
                EmptyView()
            }
        }
        .navigationTitle("Accounts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // Placement diverso per piattaforma: su iOS `.primaryAction` cade sullo stesso
            // lato (trailing) del "Chiudi" di `toolbarDoneButton()` quando questa vista è
            // presentata come sheet — i due finiscono ammassati insieme.
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
