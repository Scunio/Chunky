import SwiftUI
import CoreData

struct RemoteBrowserView: View {
    let account: RemoteAccountEntity
    var startURL: URL?
    var title: String?

    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var viewModel: LibraryViewModel
    #if os(tvOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    @State private var entries: [RemoteEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var downloadingEntryIDs: Set<RemoteEntry.ID> = []

    private var browser: RemoteBrowsing { RemoteBrowsingFactory.makeBrowser(for: account.kind) }
    private var url: URL { startURL ?? account.serverURL ?? URL(string: "about:blank")! }

    var body: some View {
        // Same fix as `DownloadsView`/`ColorThemeView`: `.navigationTitle` overlays a fixed
        // screen position on tvOS instead of a sticky header, and a remote folder listing is
        // unbounded. `TVPanel` puts the title in the layout instead.
        #if os(tvOS)
        TVPanel(title: title ?? account.name ?? "Sfoglia") {
            EmptyView()
        } content: {
            browserContent
        }
        // Same missing-affordance fix as `DownloadsView` — pushed from the Account tab's
        // hidden-nav-bar `NavigationStack` root, so Menu would otherwise exit the whole app
        // instead of popping back (one level, whether that's the Account list or a parent
        // folder — recursion into a subfolder pushes another instance of this same view).
        .onExitCommand { dismiss() }
        .onAppear(perform: load)
        #else
        browserContent
            .navigationTitle(title ?? account.name ?? "Sfoglia")
            .onAppear(perform: load)
        #endif
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
                Text(errorMessage)
            } actions: {
                Button("Riprova", action: load)
            }
        } else if entries.isEmpty {
            ContentUnavailableView("Nessun contenuto qui.", systemImage: "folder")
        } else {
            List(entries) { entry in
                row(for: entry)
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
                    errorMessage = error.chunkyFriendlyDescription
                    isLoading = false
                }
            }
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
