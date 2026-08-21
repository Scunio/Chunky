import SwiftUI

/// Root of the app. It's the only place where navigation diverges between platforms:
/// the rest of the views don't know which system they're running on.
struct ContentView: View {
    #if os(macOS)
    @State private var selection: LibrarySelection = .all
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #endif

    @EnvironmentObject private var viewModel: LibraryViewModel
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var tracker = ICloudDownloadTracker.shared
    @AppStorage("icloudSyncFolderEnabled") private var isSyncFolderEnabled = false

    /// Coalesces updates to `tracker.allRelativePaths`: during the initial gathering of a
    /// non-trivial iCloud library, `NSMetadataQuery` publishes many incremental updates
    /// in rapid succession — without waiting for them to settle, each one
    /// would trigger a full library rescan.
    @State private var debounceTask: Task<Void, Never>?
    /// Safety net on top of `NSMetadataQuery`'s live updates: in practice the
    /// query doesn't always notify a change that happened while the app was in the background, so
    /// a low-frequency periodic rescan covers that case without relying on the event alone.
    @State private var periodicRescanTask: Task<Void, Never>?
    /// CloudKit's remote changes arrive in bursts of notifications: as with the tracker,
    /// a single deduplication pass after they've settled down.
    @State private var deduplicationTask: Task<Void, Never>?
    /// Same logic for comics that finish downloading from iCloud: see
    /// `scheduleDebouncedPlaceholderBackfill`.
    @State private var placeholderBackfillTask: Task<Void, Never>?

    var body: some View {
        rootNavigation
            // Started only once for the entire lifetime of the app (the query is inert if iCloud
            // isn't active): stopping and restarting it when entering/leaving the reader would force
            // a new gathering phase every time.
            .onAppear {
                ICloudDownloadTracker.shared.start()
                syncSyncFolderIfNeeded()
                adoptFilesDroppedInDocuments()
                viewModel.deduplicateLibrary(context: context)
                // At startup the metadata query starts from scratch, so its first
                // update is always a growth and doesn't trigger anything: a comic downloaded
                // from the Files app while Chunky was closed would stay without a cover until the
                // next download. This pass is a no-op when there are no placeholders.
                viewModel.backfillPlaceholderMetadata(context: context)
                startPeriodicRescan()
            }
            .onDisappear {
                debounceTask?.cancel()
                periodicRescanTask?.cancel()
                deduplicationTask?.cancel()
                placeholderBackfillTask?.cancel()
            }
            // Duplicates don't only originate here: the other device with the same account creates
            // its own record for the same file, and it arrives via CloudKit. This is the notification
            // that signals the arrival of remote changes — the sync folder can also be
            // disabled, so hooking into `rebuildLibrary` alone isn't enough.
            .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
                scheduleDebouncedDeduplication()
            }
            // ContentView is the root that's always alive for the whole session: updates to
            // `allRelativePaths` trigger the rescan here regardless of what the user
            // is currently looking at, instead of depending on a specific screen being open.
            .onChange(of: tracker.allRelativePaths) { _, _ in scheduleDebouncedSync() }
            // A comic that stops being "to download" is a file that just arrived
            // locally: this is the moment to open it and extract its cover and page count, which
            // weren't available at registration time (see `registerComic`). Only the
            // shrinking of the set is watched: when it grows, new placeholders have appeared, and
            // there's nothing to read there.
            .onChange(of: tracker.pendingRelativePaths) { previous, current in
                guard !previous.subtracting(current).isEmpty else { return }
                scheduleDebouncedPlaceholderBackfill()
            }
            .onChange(of: isSyncFolderEnabled) { _, newValue in if newValue { syncSyncFolderIfNeeded() } }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                syncSyncFolderIfNeeded()
                // The moment when files dragged from the Finder may have appeared is
                // exactly this one: the user copies them while the app is in the background and then reopens it.
                adoptFilesDroppedInDocuments()
                viewModel.deduplicateLibrary(context: context)
                viewModel.backfillPlaceholderMetadata(context: context)
            }
    }

    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            syncSyncFolderIfNeeded()
        }
    }

    /// As with the other hooks into `NSMetadataQuery`: when downloading several comics together
    /// the files become local one after another, and without waiting for the burst to settle each
    /// single arrival would trigger a pass over the entire library.
    private func scheduleDebouncedPlaceholderBackfill() {
        placeholderBackfillTask?.cancel()
        placeholderBackfillTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            viewModel.backfillPlaceholderMetadata(context: context)
        }
    }

    private func scheduleDebouncedDeduplication() {
        deduplicationTask?.cancel()
        deduplicationTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            viewModel.deduplicateLibrary(context: context)
        }
    }

    /// iOS only: on macOS there's no File Sharing and the app's Documents folder isn't
    /// a destination the user can drag something into.
    private func adoptFilesDroppedInDocuments() {
        #if os(iOS)
        viewModel.adoptFilesDroppedInDocuments(context: context)
        #endif
    }

    private func syncSyncFolderIfNeeded() {
        #if os(tvOS)
        // No ubiquity container on tvOS, so synced-but-fileless comics would linger forever.
        viewModel.rebuildLibrary(context: context)
        #else
        guard isSyncFolderEnabled, LibraryStorage.isICloudAvailable else { return }
        viewModel.rebuildLibrary(context: context)
        #endif
    }

    private func startPeriodicRescan() {
        periodicRescanTask?.cancel()
        periodicRescanTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000) // 3 minutes
                guard !Task.isCancelled else { return }
                syncSyncFolderIfNeeded()
                // Re-picks up files that adoption had skipped because the Finder was still
                // copying them: without this, staying in the foreground during a long transfer
                // would leave them out of the library until the app restarts.
                adoptFilesDroppedInDocuments()
                // No true background execution on any platform this app ships on: remote
                // accounts (SMB/WebDAV/OPDS) only get scanned while the app is open and in the
                // foreground, same limitation as the rest of this loop.
                await RemoteAccountScanner.scanAllEnabledAccounts(context: context)
            }
        }
    }

    @ViewBuilder
    private var rootNavigation: some View {
        #if os(macOS)
        // On Mac the library lives in the main window and the sidebar lists the series.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            LibraryView(selection: selection)
                .navigationSplitViewColumnWidth(min: 520, ideal: 900)
        }
        .navigationSplitViewStyle(.balanced)
        #else
        NavigationStack {
            LibraryView()
        }
        #endif
    }
}
