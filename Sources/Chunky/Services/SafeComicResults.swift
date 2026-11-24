import CoreData
import Combine
import Foundation

/// Live main-context results fetched inside an Objective-C exception boundary.
/// SwiftUI's `@FetchRequest` uses an `NSFetchedResultsController` that cannot catch
/// `NSException` raised while Core Data materializes rows from a damaged store.
@MainActor
final class SafeManagedObjectResults<Object: NSManagedObject>: ObservableObject {
    @Published private(set) var items: [Object] = []
    @Published private(set) var error: Error?

    private weak var context: NSManagedObjectContext?
    private var notificationToken: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private let request: NSFetchRequest<NSFetchRequestResult>
    #if os(macOS)
    /// See `ProgressChangePolicy`.
    private let progressChangePolicy: ProgressChangePolicy
    private var progressRefreshWorkItem: DispatchWorkItem?

    /// How a change that touches *only* reading progress (`lastReadPage`/`dateLastOpened`, what
    /// the reader writes in memory on every page turn) is handled. Refetching the whole library
    /// — in every open window — and republishing it on each turn made every library and reader
    /// window re-render mid-animation.
    enum ProgressChangePolicy {
        /// Coalesced: a few seconds after the last progress change observers are told to
        /// re-render (no refetch: the rows and their title order can't have changed), so views
        /// that derive from progress (status filters, "Now Reading") still catch up.
        case coalesce
        /// Ignored entirely: for consumers that never depend on progress (the reader window's
        /// "next comic" list, ordered by title).
        case ignore
    }

    private nonisolated static var progressOnlyKeys: Set<String> { ["lastReadPage", "dateLastOpened"] }
    private nonisolated static var progressRefreshDelay: TimeInterval { 3 }

    init(request: NSFetchRequest<NSFetchRequestResult>, progressChangePolicy: ProgressChangePolicy = .coalesce) {
        self.request = request
        self.progressChangePolicy = progressChangePolicy
        request.resultType = .managedObjectResultType
    }
    #else
    init(request: NSFetchRequest<NSFetchRequestResult>) {
        self.request = request
        request.resultType = .managedObjectResultType
    }
    #endif

    func start(in context: NSManagedObjectContext) {
        if self.context !== context {
            stop()
            self.context = context
            notificationToken = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextObjectsDidChange,
                object: context,
                queue: .main
            ) { [weak self] notification in
                #if os(macOS)
                // Evaluated here, synchronously on the main queue (where the view context
                // posts it): `changedValuesForCurrentEvent()` is only meaningful during the
                // notification itself.
                let progressOnly = Self.isProgressOnlyChange(notification)
                Task { @MainActor in
                    if progressOnly {
                        self?.handleProgressOnlyChange()
                    } else {
                        self?.scheduleRefresh()
                    }
                }
                #else
                Task { @MainActor in self?.scheduleRefresh() }
                #endif
            }
        }
        refresh()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        #if os(macOS)
        progressRefreshWorkItem?.cancel()
        progressRefreshWorkItem = nil
        #endif
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
            self.notificationToken = nil
        }
        context = nil
    }

    func retry() {
        refresh()
    }

    #if os(macOS)
    private nonisolated static func isProgressOnlyChange(_ notification: Notification) -> Bool {
        let info = notification.userInfo ?? [:]
        for key in [NSInsertedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey, NSInvalidatedObjectsKey] {
            if let objects = info[key] as? Set<NSManagedObject>, !objects.isEmpty { return false }
        }
        if info[NSInvalidatedAllObjectsKey] != nil { return false }
        guard let updated = info[NSUpdatedObjectsKey] as? Set<NSManagedObject>, !updated.isEmpty else { return false }
        return updated.allSatisfy { object in
            guard object is ComicEntity else { return false }
            let changed = Set(object.changedValuesForCurrentEvent().keys)
            return !changed.isEmpty && changed.isSubset(of: progressOnlyKeys)
        }
    }

    private func handleProgressOnlyChange() {
        switch progressChangePolicy {
        case .ignore:
            return
        case .coalesce:
            progressRefreshWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.progressRefreshWorkItem = nil
                self?.objectWillChange.send()
            }
            progressRefreshWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.progressRefreshDelay, execute: work)
        }
    }
    #endif

    private func scheduleRefresh() {
        #if os(macOS)
        progressRefreshWorkItem?.cancel()
        progressRefreshWorkItem = nil
        #endif
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        guard let context else { return }
        var fetchError: NSError?
        guard let objects = ObjCExceptionCatcher.safeFetchRequest(
            request,
            in: context,
            failure: &fetchError
        ) as? [Object], fetchError == nil else {
            let error = fetchError ?? NSError(
                domain: "com.scunio.chunky.coredata-fetch",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Core Data non ha restituito i dati richiesti."]
            )
            self.error = error
            DiagnosticLog.log("Fetch Core Data intercettata: \((error as NSError).localizedDescription) \((error as NSError).userInfo)")
            return
        }
        error = nil
        items = objects
    }
}

typealias SafeComicResults = SafeManagedObjectResults<ComicEntity>

extension SafeManagedObjectResults where Object == ComicEntity {
    convenience init() {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "ComicEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ComicEntity.title, ascending: true)]
        self.init(request: request)
    }

    #if os(macOS)
    convenience init(progressChangePolicy: ProgressChangePolicy) {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "ComicEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ComicEntity.title, ascending: true)]
        self.init(request: request, progressChangePolicy: progressChangePolicy)
    }
    #endif

    var comics: [ComicEntity] { items }
}
