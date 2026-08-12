import SwiftUI
import CoreData
import UniformTypeIdentifiers

/// Servizio elencato in "Add account": qui il tocco apre il picker file di sistema, dove
/// Dropbox/Google Drive/OneDrive compaiono automaticamente se le rispettive app sono installate
/// — non essendoci integrazione OAuth diretta in questa ricostruzione, e nessun sistema di
/// acquisto in-app che richieda di distinguere servizi "PRO" da quelli gratuiti.
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

    @State private var isShowingAddAccount = false
    @State private var addAccountKind: RemoteAccountKind = .opds
    @State private var isShowingFolderPicker = false
    @State private var isShowingFileImporter = false
    @State private var folderConversionError: String?
    /// Come nell'originale: "+" non apre un altro schermo, rivela la sezione "Add account" in
    /// coda alla stessa lista e diventa "Done" per richiuderla — non è un secondo passo separato.
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
                Button(action: { isShowingFileImporter = true }) {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .foregroundColor(.primary)
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
                        Button(action: { isShowingFileImporter = true }) {
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
                    Button(action: { isShowingFolderPicker = true }) {
                        Label("Crea fumetto da cartella di immagini", systemImage: "photo.stack")
                    }
                    if let folderConversionError = folderConversionError {
                        Text(folderConversionError)
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
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { withAnimation { isAddingAccount.toggle() } }) {
                    if isAddingAccount {
                        Text("Done")
                    } else {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        #endif
        .sheet(isPresented: $isShowingAddAccount) {
            AddAccountView(initialKind: addAccountKind)
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
        .fileImporter(isPresented: $isShowingFolderPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folderURL):
                convertFolder(folderURL)
            case .failure(let error):
                folderConversionError = error.localizedDescription
            }
        }
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
