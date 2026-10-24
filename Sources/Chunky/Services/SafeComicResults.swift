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

    init(request: NSFetchRequest<NSFetchRequestResult>) {
        self.request = request
        request.resultType = .managedObjectResultType
    }

    func start(in context: NSManagedObjectContext) {
        if self.context !== context {
            stop()
            self.context = context
            notificationToken = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextObjectsDidChange,
                object: context,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        }
        refresh()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
            self.notificationToken = nil
        }
        context = nil
    }

    func retry() {
        refresh()
    }

    private func scheduleRefresh() {
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

    var comics: [ComicEntity] { items }
}
