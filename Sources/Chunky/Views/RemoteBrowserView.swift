import SwiftUI
import CoreData

struct RemoteBrowserView: View {
    let account: RemoteAccountEntity
    var startURL: URL?
    var title: String?

    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var viewModel: LibraryViewModel

    @State private var entries: [RemoteEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var downloadingEntryID: RemoteEntry.ID?

    private var browser: RemoteBrowsing { RemoteBrowsingFactory.makeBrowser(for: account.kind) }
    private var url: URL { startURL ?? account.serverURL ?? URL(string: "about:blank")! }

    var body: some View {
        Group {
            if isLoading && entries.isEmpty {
                ProgressView("Caricamento…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    Button("Riprova", action: load)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                Text("Nessun contenuto qui.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    row(for: entry)
                }
            }
        }
        .navigationTitle(title ?? account.name ?? "Sfoglia")
        .onAppear(perform: load)
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
                    if downloadingEntryID == entry.id {
                        ProgressView()
                    } else {
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .disabled(downloadingEntryID != nil)
        }
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let loaded = try await browser.listEntries(at: url, account: account)
                await MainActor.run {
                    entries = loaded
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func downloadAndImport(_ entry: RemoteEntry) {
        downloadingEntryID = entry.id
        Task {
            do {
                let localURL = try await browser.download(entry, account: account)
                await MainActor.run {
                    viewModel.importFiles([localURL], into: context)
                    downloadingEntryID = nil
                }
            } catch {
                await MainActor.run {
                    viewModel.importError = error.localizedDescription
                    downloadingEntryID = nil
                }
            }
        }
    }
}
