import CoreData
import Foundation

/// Logs WHAT the Core Data mirror imported (not just that it did): per-entity change
/// counts plus, for updated comics, title and page. Driven by persistent history
/// (already enabled on the mirrored store) with our own token, so CloudKit's own
/// consumption is untouched. History is only ever read, never deleted.
///
/// Note: history holds every transaction (local saves and merged imports alike), so
/// the summary covers all recent movement — exactly what's needed to track a page
/// that should have traveled between devices.
enum MirrorHistoryLogger {
    private static let baselineDateDefaultsKey = "mirrorHistoryLogDate"
    private static let maxDetailComics = 5

    /// Entry point from any thread: summarizes transactions newer than the last
    /// logged one to Diagnostica. First call only establishes the baseline (no log)
    /// so a fresh install doesn't dump the whole library.
    static func logNewImports(in context: NSManagedObjectContext) {
        context.perform {
            logNewTransactions(in: context)
        }
    }

    /// Same, for callers already on the context's queue (e.g. tests).
    static func logNewTransactions(in context: NSManagedObjectContext) {
        summarizeNewTransactions(after: storedBaselineDate(), in: context)
    }

    static func summarizeNewTransactions(after baseline: Date?, in context: NSManagedObjectContext) {
        guard let baseline else {
            storeBaselineDate(Date())
            return
        }
        let historyFetch = NSPersistentHistoryChangeRequest.fetchHistory(after: baseline)
        guard let result = try? context.execute(historyFetch) as? NSPersistentHistoryResult,
              let transactions = result.result as? [NSPersistentHistoryTransaction],
              !transactions.isEmpty
        else { return }

        var inserts: [String: Int] = [:]
        var updates: [String: Int] = [:]
        var deletes: [String: Int] = [:]
        var updatedComics: [(title: String, page: Int)] = []
        for transaction in transactions {
            guard let changes = transaction.changes else { continue }
            for change in changes {
                let entity = change.changedObjectID.entity.name ?? "?"
                switch change.changeType {
                case .insert:
                    inserts[entity, default: 0] += 1
                case .update:
                    updates[entity, default: 0] += 1
                    // Small attributes only (title, page): the cover blob stays faulted.
                    if entity == "ComicEntity", updatedComics.count < maxDetailComics,
                       let comic = try? context.existingObject(with: change.changedObjectID) as? ComicEntity {
                        updatedComics.append((comic.title ?? "?", Int(comic.lastReadPage)))
                    }
                case .delete:
                    deletes[entity, default: 0] += 1
                @unknown default:
                    break
                }
            }
        }
        if let last = transactions.last {
            // Date-based (not token-based): tokens can't be re-derived after a store
            // rebuild, while a date baseline degrades to harmless duplicate lines.
            storeBaselineDate(last.timestamp)
        }

        var parts: [String] = []
        for entity in Set(inserts.keys).union(updates.keys).union(deletes.keys).sorted() {
            var bits: [String] = []
            if let n = updates[entity], n > 0 { bits.append("\(n) aggiornati") }
            if let n = inserts[entity], n > 0 { bits.append("\(n) inseriti") }
            if let n = deletes[entity], n > 0 { bits.append("\(n) eliminati") }
            parts.append("\(entity) (\(bits.joined(separator: ", ")))")
        }
        guard !parts.isEmpty else { return }
        var line = "Mirror: " + parts.joined(separator: ", ")
        if !updatedComics.isEmpty {
            line += " — " + updatedComics.map { "\($0.title) → pag \($0.page + 1)" }.joined(separator: "; ")
        }
        DiagnosticLog.log(line)
    }

    /// Remembers "now" without logging: the starting point for subsequent summaries.
    static func storeBaselineDate(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: baselineDateDefaultsKey)
    }

    static func storedBaselineDate() -> Date? {
        let stored = UserDefaults.standard.double(forKey: baselineDateDefaultsKey)
        guard stored > 0 else { return nil }
        return Date(timeIntervalSince1970: stored)
    }
}
