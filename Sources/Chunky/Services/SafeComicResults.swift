import CoreData
import Combine
import Foundation

/// A live, main-context comic query that turns Core Data exceptions into a recoverable
/// view state. SwiftUI's `@FetchRequest` owns an `NSFetchedResultsController` whose later
/// fetches aren't inside an Objective-C exception boundary; a malformed or temporarily
/// unavailable store can therefore abort the process instead of returning an error.
@MainActor
final class SafeComicResults: ObservableObject {
    @Published private(set) var comics: [ComicEntity] = []
    @Published private(set) var error: Error?

    private weak var context: NSManagedObjectContext?
    private var notificationToken: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?

    private let request: NSFetchRequest<NSFetchRequestResult> = {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "ComicEntity")
        request.resultType = .managedObjectResultType
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ComicEntity.title, ascending: true)]
        return request
    }()

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
        ) as? [ComicEntity], fetchError == nil else {
            let error = fetchError ?? NSError(
                domain: "com.scunio.chunky.coredata-fetch",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Core Data non ha restituito i fumetti della libreria."]
            )
            self.error = error
            DiagnosticLog.log("Fetch libreria intercettata: \((error as NSError).localizedDescription) \((error as NSError).userInfo)")
            return
        }
        error = nil
        comics = objects
    }
}
