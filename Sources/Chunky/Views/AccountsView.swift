import SwiftUI
import CoreData
import UniformTypeIdentifiers

struct AccountsView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var viewModel: LibraryViewModel
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \RemoteAccountEntity.dateAdded, ascending: true)]
    ) private var accounts: FetchedResults<RemoteAccountEntity>

    @State private var isShowingAddAccount = false
    @State private var isShowingFolderPicker = false
    @State private var folderConversionError: String?

    var body: some View {
        List {
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

            Section(header: Text("Rete locale")) {
                NavigationLink(destination: LocalUploadView()) {
                    Label("Upload dalla rete (Web)", systemImage: "wifi")
                }
            }

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

            Section(
                header: Text("Aggiungi account"),
                footer: Text("Dropbox, Google Drive e OneDrive si possono già importare da qui, se hai le rispettive app installate: compaiono automaticamente nel selettore file di sistema.")
            ) {
                Button(action: { isShowingAddAccount = true }) {
                    Label("Nuovo account OPDS o WebDAV", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Account")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
        .sheet(isPresented: $isShowingAddAccount) {
            AddAccountView()
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
