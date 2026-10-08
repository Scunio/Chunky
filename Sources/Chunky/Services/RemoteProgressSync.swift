import CloudKit
import CoreData
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Syncs reading progress of remote-library comics (SMB/WebDAV/OPDS) across devices,
/// Infuse-style: files stay on the share, only lightweight progress records travel via
/// the app's CloudKit private database.
///
/// Why a separate mechanism instead of the existing Core Data mirroring:
/// remote-sourced comics live in the local-only store that is never mirrored
/// (`ComicEntity.create`), and their `sourceAccountID` is a per-device random UUID that
/// cannot match anywhere else. So progress travels as explicit `CKRecord`s keyed by
/// `RemoteProgressSyncKey` (deterministic on every device), in a dedicated zone.
///
/// Deliberately best-effort and silent: like `RemoteAccountScanner` (which never fails
/// outward), every CloudKit error is logged via `DiagnosticLog` and never surfaced —
/// sync degrades to "this device only" instead of breaking reading.
///
/// Threading: only `snapshot(of:)` / `requestPush(_:)` are `@MainActor` (they read
/// managed objects) — call them via `Task { @MainActor in }` from synchronous UI code,
/// the same idiom used for `RemoteAccountScanner` (see `RemoteBrowserView`). Everything
/// else (`flushPush`, `fetchAndApply`, …) is thread-safe by construction and callable
/// from anywhere: snapshots are value types captured on main before any queue hop, so
/// nothing managed crosses threads.
///
/// CloudKit I/O itself is intentionally unit-untestable (needs entitlements + network);
/// every *decision* (keys, record names, last-writer-wins) lives in the pure
/// `RemoteProgressSyncKey` and is covered by `RemoteProgressSyncKeyTests`.
enum RemoteProgressSync {
    // MARK: - Configuration

    /// Explicit (not `CKContainer.default()`): the app has exactly one container, but the
    /// default one is resolved from entitlements order — spelling it out removes doubt.
    /// Present in all three targets' entitlements (tvOS: CloudKit only, no Drive).
    static let containerIdentifier = "iCloud.com.scunio.Chunky"
    /// Custom zone (not the default one): only custom zones support change tokens, which
    /// is what makes fetch incremental instead of a full query every time.
    static let zoneName = "RemoteProgress"
    static let recordType = "RemoteReadingProgress"
    static let defaultsTokenKey = "ckRemoteProgressZoneToken"
    static let enabledDefaultsKey = "remoteProgressSyncEnabled"

    /// Manual pairing-key override, stored in UserDefaults per account UUID — deliberately
    /// *not* a Core Data attribute, so adding it needs no model migration (and it never
    /// touches the CloudKit-mirrored store). Keyed by the account's stable per-device id:
    /// deleting and re-adding the account loses the override, by design (fail-closed).
    static func overrideDefaultsKey(forAccountID id: UUID) -> String {
        "remoteProgressSyncKeyOverride_" + id.uuidString
    }

    /// Raw override text ("" when unset). Normalization happens in
    /// `RemoteProgressSyncKey.effectiveAccountSyncKey`, so readers never diverge.
    static func syncKeyOverride(forAccountID id: UUID) -> String {
        UserDefaults.standard.string(forKey: overrideDefaultsKey(forAccountID: id)) ?? ""
    }

    /// Persists the override; a blank value removes it (back to the derived key).
    static func setSyncKeyOverride(_ override: String, forAccountID id: UUID) {
        let key = overrideDefaultsKey(forAccountID: id)
        if override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(override, forKey: key)
        }
    }

    static func clearSyncKeyOverride(forAccountID id: UUID) {
        UserDefaults.standard.removeObject(forKey: overrideDefaultsKey(forAccountID: id))
    }

    /// The key actually used for matching: manual override when set, derived otherwise.
    /// Nil only when the account has no usable derived identity (fail-closed).
    static func effectiveSyncKey(for account: RemoteAccountEntity) -> String? {
        guard let descriptor = RemoteProgressSyncKey.descriptor(for: account),
              let id = account.id
        else { return nil }
        return RemoteProgressSyncKey.effectiveAccountSyncKey(
            descriptor: descriptor, override: syncKeyOverride(forAccountID: id)
        )
    }

    /// Global opt-out (Settings). Defaults to true when the user never touched it:
    /// `AppStorage` only writes after the first toggle, so absence means enabled.
    static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: enabledDefaultsKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    // MARK: - Push

    /// Value-type capture of a comic's progress, taken on main before any queue hop.
    struct Snapshot: Sendable {
        let recordName: String
        let accountSyncKey: String
        let serverPath: String
        let lastReadPage: Int
        let pageCount: Int
        let updatedAt: Date
        let title: String
        let deviceName: String
    }

    /// Builds a pushable snapshot, or nil when this comic must not sync (not from a
    /// remote account, account gone, or unresolvable server path — all fail-closed).
    @MainActor
    static func snapshot(of comic: ComicEntity) -> Snapshot? {
        guard let context = comic.managedObjectContext,
              let sourceAccountID = comic.sourceAccountID,
              let sourceAbsoluteString = comic.sourceRelativePath,
              !sourceAbsoluteString.isEmpty
        else { return nil }
        let request = RemoteAccountEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", sourceAccountID as CVarArg)
        request.fetchLimit = 1
        guard let account = try? context.fetch(request).first,
              let root = account.serverURL?.absoluteString,
              let serverPath = RemoteProgressSyncKey.serverPath(
                  rootAbsoluteString: root, sourceAbsoluteString: sourceAbsoluteString
              ),
              let syncKey = effectiveSyncKey(for: account)
        else { return nil }
        let progressKey = RemoteProgressSyncKey.progressKey(accountSyncKey: syncKey, serverPath: serverPath)
        return Snapshot(
            recordName: RemoteProgressSyncKey.recordName(forProgressKey: progressKey),
            accountSyncKey: syncKey,
            serverPath: serverPath,
            lastReadPage: Int(comic.lastReadPage),
            pageCount: Int(comic.pageCount),
            // `dateLastOpened` is the local progress clock (touched on every page turn):
            // an explicit "mark unread" nils it, and `Date()` then propagates the reset
            // as newer than any previous record instead of losing to it.
            updatedAt: comic.dateLastOpened ?? Date(),
            title: comic.title ?? "",
            deviceName: currentDeviceName
        )
    }

    /// Enqueues a push for remote comics (silently ignores anything else). Debounced per
    /// record (~10s): page turns already arrive throttled from the reader, this only
    /// coalesces bursts (bulk status changes, multi-window Mac).
    @MainActor
    static func requestPush(_ comics: [ComicEntity]) {
        guard isEnabled else { return }
        for comic in comics {
            guard let snapshot = snapshot(of: comic) else { continue }
            Engine.requestPush(snapshot)
        }
    }

    @MainActor
    static func requestPush(_ comic: ComicEntity) {
        requestPush([comic])
    }

    /// Pushes anything debounced immediately (best-effort, async). Called on exit and
    /// backgrounding so the last pages are never left only in memory.
    static func flushPush() {
        guard isEnabled else { return }
        Engine.flush()
    }

    // MARK: - Fetch

    /// Pulls remote changes and applies last-writer-wins. Foreground-triggered calls are
    /// throttled (~60s); post-scan calls pass `force: true` (scans already run at most
    /// every ~3 minutes, plus manual scans).
    static func fetchAndApply(in context: NSManagedObjectContext, force: Bool = false) {
        guard isEnabled else { return }
        Engine.fetchAndApply(in: context, force: force)
    }

    /// Drops the zone change token so the next fetch is a full one. Recovery path for
    /// token expiration/corruption (also handled automatically on `.changeTokenExpired`).
    static func resetFetchToken() {
        Engine.resetToken()
    }

    // MARK: - Private

    private static var currentDeviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    /// All CloudKit I/O and mutable engine state live here, behind one serial queue plus
    /// a lock: exactly one in-flight fetch-modify-save per record, no overlapping races
    /// between concurrent readers (multi-window Mac) or a push racing a fetch.
    ///
    /// `nonisolated(unsafe)` statics: every access is serialized through `lock`/`queue`
    /// (same pattern as `TestStore.cachedModel`).
    private enum Engine {
        private static let queue = DispatchQueue(
            label: "com.scunio.Chunky.remoteProgress", qos: .utility
        )
        private static let lock = NSLock()
        /// Latest requested snapshot per record: `pushLatest` pops it, so `flush()`
        /// pushes exactly the not-yet-pushed values and nothing stale.
        nonisolated(unsafe) private static var latest: [String: RemoteProgressSync.Snapshot] = [:]
        nonisolated(unsafe) private static var scheduled: [String: DispatchWorkItem] = [:]
        nonisolated(unsafe) private static var lastPush: [String: Date] = [:]
        nonisolated(unsafe) private static var lastFetch = Date.distantPast
        private static let pushDebounce: TimeInterval = 10
        private static let fetchThrottle: TimeInterval = 60

        private static var database: CKDatabase {
            CKContainer(identifier: RemoteProgressSync.containerIdentifier).privateCloudDatabase
        }

        private static var zoneID: CKRecordZone.ID {
            CKRecordZone.ID(zoneName: RemoteProgressSync.zoneName, ownerName: CKCurrentUserDefaultName)
        }

        // MARK: Push

        static func requestPush(_ snapshot: RemoteProgressSync.Snapshot) {
            lock.lock()
            latest[snapshot.recordName] = snapshot
            if Date().timeIntervalSince(lastPush[snapshot.recordName] ?? .distantPast) >= pushDebounce {
                lastPush[snapshot.recordName] = Date()
                scheduled[snapshot.recordName]?.cancel()
                scheduled[snapshot.recordName] = nil
                lock.unlock()
                queue.async { pushLatest(snapshot.recordName) }
            } else if scheduled[snapshot.recordName] == nil {
                let name = snapshot.recordName
                let work = DispatchWorkItem {
                    lock.lock()
                    scheduled[name] = nil
                    lastPush[name] = Date()
                    lock.unlock()
                    pushLatest(name)
                }
                scheduled[snapshot.recordName] = work
                lock.unlock()
                queue.asyncAfter(deadline: .now() + pushDebounce, execute: work)
            } else {
                lock.unlock()
            }
        }

        static func flush() {
            lock.lock()
            let snaps = latest
            latest = [:]
            for (_, work) in scheduled { work.cancel() }
            scheduled = [:]
            for name in snaps.keys { lastPush[name] = Date() }
            lock.unlock()
            for snapshot in snaps.values {
                queue.async { push(snapshot) }
            }
        }

        /// Pops the latest snapshot for one record and pushes it (no-op if a flush
        /// already consumed it).
        private static func pushLatest(_ recordName: String) {
            lock.lock()
            let snapshot = latest.removeValue(forKey: recordName)
            lock.unlock()
            guard let snapshot else { return }
            push(snapshot)
        }

        private static func push(_ snapshot: RemoteProgressSync.Snapshot) {
            let recordID = CKRecord.ID(recordName: snapshot.recordName, zoneID: zoneID)
            fetchRecord(id: recordID) { result in
                switch result {
                case .success(let existing):
                    guard let existing else {
                        saveRecord(newRecord(id: recordID, from: snapshot)) { push(snapshot) }
                        return
                    }
                    guard snapshot.updatedAt > (existing["updatedAt"] as? Date ?? .distantPast) else {
                        return // Remote is newer (or our own echo): nothing to do.
                    }
                    fill(record: existing, from: snapshot)
                    saveRecord(existing) { push(snapshot) }
                case .failure(let error):
                    handlePushError(error) { push(snapshot) }
                }
            }
        }

        private static func newRecord(id: CKRecord.ID, from snapshot: RemoteProgressSync.Snapshot) -> CKRecord {
            let record = CKRecord(recordType: RemoteProgressSync.recordType, recordID: id)
            fill(record: record, from: snapshot)
            return record
        }

        private static func fill(record: CKRecord, from snapshot: RemoteProgressSync.Snapshot) {
            record["accountSyncKey"] = snapshot.accountSyncKey as CKRecordValue
            record["serverPath"] = snapshot.serverPath as CKRecordValue
            record["lastReadPage"] = NSNumber(value: snapshot.lastReadPage)
            record["pageCount"] = NSNumber(value: snapshot.pageCount)
            record["updatedAt"] = snapshot.updatedAt as CKRecordValue
            record["deviceName"] = snapshot.deviceName as CKRecordValue
            record["title"] = snapshot.title as CKRecordValue
        }

        /// Refined-for-Swift CloudKit API: per-record outcomes arrive on
        /// `perRecordResultBlock`, the overall block only reports operation-level failure
        /// (auth, zone missing, …). The `completed` flag routes exactly one of them to
        /// `completion` — both fire on success.
        private static func fetchRecord(id: CKRecord.ID, completion: @escaping (Result<CKRecord?, Error>) -> Void) {
            let operation = CKFetchRecordsOperation(recordIDs: [id])
            let completedLock = NSLock()
            var completed = false
            let completeOnce: (Result<CKRecord?, Error>) -> Void = { result in
                completedLock.lock()
                defer { completedLock.unlock() }
                guard !completed else { return }
                completed = true
                completion(result)
            }
            operation.perRecordResultBlock = { recordID, result in
                guard recordID == id else { return }
                switch result {
                case .success(let record):
                    completeOnce(.success(record))
                case .failure(let error as CKError) where error.code == .unknownItem:
                    completeOnce(.success(nil))
                case .failure(let error):
                    completeOnce(.failure(error))
                }
            }
            operation.fetchRecordsResultBlock = { result in
                if case .failure(let error) = result {
                    completeOnce(.failure(error))
                }
            }
            database.add(operation)
        }

        /// Same exactly-once routing for saves: `.serverRecordChanged` surfaces per
        /// record (not just overall), which is precisely the conflict signal the
        /// `.ifServerRecordUnchanged` policy below is chosen to produce.
        private static func saveRecord(_ record: CKRecord, retryZoneNotFound retry: @escaping () -> Void) {
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            // Explicit conflict detection (not blind last-write): concurrent pushes from
            // two devices surface as `.serverRecordChanged`, resolved below by timestamp.
            operation.savePolicy = .ifServerRecordUnchanged
            let completedLock = NSLock()
            var completed = false
            let completeOnce: (Result<Void, Error>) -> Void = { result in
                completedLock.lock()
                defer { completedLock.unlock() }
                guard !completed else { return }
                completed = true
                if case .failure(let error) = result {
                    handleSaveError(error, record: record, retryZoneNotFound: retry)
                }
            }
            operation.perRecordSaveBlock = { recordID, result in
                guard recordID == record.recordID else { return }
                switch result {
                case .success:
                    completeOnce(.success(()))
                case .failure(let error):
                    completeOnce(.failure(error))
                }
            }
            operation.modifyRecordsResultBlock = { result in
                completeOnce(result)
            }
            database.add(operation)
        }

        private static func handleSaveError(_ error: Error, record: CKRecord, retryZoneNotFound retry: @escaping () -> Void) {
            guard let ckError = error as? CKError else {
                DiagnosticLog.log("RemoteProgress push fallito: \(error.localizedDescription)")
                return
            }
            switch ckError.code {
            case .serverRecordChanged:
                // The other device won the race but may still be older: re-evaluate by
                // timestamp against the authoritative server record, single retry — if it
                // conflicts again, the other side was newer and correctly wins.
                guard let serverRecord = ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                      let ours = record["updatedAt"] as? Date,
                      ours > (serverRecord["updatedAt"] as? Date ?? .distantPast)
                else { return }
                // Rebuild our values onto the server record (same field set `fill` writes).
                serverRecord["accountSyncKey"] = record["accountSyncKey"]
                serverRecord["serverPath"] = record["serverPath"]
                serverRecord["lastReadPage"] = record["lastReadPage"]
                serverRecord["pageCount"] = record["pageCount"]
                serverRecord["updatedAt"] = record["updatedAt"]
                serverRecord["deviceName"] = record["deviceName"]
                serverRecord["title"] = record["title"]
                saveRecordOnce(serverRecord)
            case .zoneNotFound:
                createZone(completion: retry)
            case .notAuthenticated, .networkFailure, .networkUnavailable, .quotaExceeded:
                DiagnosticLog.log("RemoteProgress push rinviato (\(ckError.code.rawValue))")
            default:
                DiagnosticLog.log("RemoteProgress push fallito: \(ckError.localizedDescription)")
            }
        }

        /// Single save without further conflict retry (the retry of a retry).
        private static func saveRecordOnce(_ record: CKRecord) {
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.modifyRecordsResultBlock = { result in
                if case .failure(let error) = result {
                    DiagnosticLog.log("RemoteProgress push (retry) fallito: \(error.localizedDescription)")
                }
            }
            database.add(operation)
        }

        private static func handlePushError(_ error: Error, retryZoneNotFound retry: @escaping () -> Void) {
            guard let ckError = error as? CKError else {
                DiagnosticLog.log("RemoteProgress push fallito: \(error.localizedDescription)")
                return
            }
            switch ckError.code {
            case .zoneNotFound:
                createZone(completion: retry)
            case .notAuthenticated, .networkFailure, .networkUnavailable, .quotaExceeded:
                DiagnosticLog.log("RemoteProgress push rinviato (\(ckError.code.rawValue))")
            default:
                DiagnosticLog.log("RemoteProgress push fallito: \(ckError.localizedDescription)")
            }
        }

        private static func createZone(completion: @escaping () -> Void) {
            let operation = CKModifyRecordZonesOperation(
                recordZonesToSave: [CKRecordZone(zoneName: RemoteProgressSync.zoneName)],
                recordZoneIDsToDelete: nil
            )
            operation.modifyRecordZonesResultBlock = { result in
                if case .failure(let error) = result {
                    DiagnosticLog.log("RemoteProgress zona non creata: \(error.localizedDescription)")
                    return
                }
                completion()
            }
            database.add(operation)
        }

        // MARK: Fetch

        static func fetchAndApply(in context: NSManagedObjectContext, force: Bool) {
            lock.lock()
            if !force, Date().timeIntervalSince(lastFetch) < fetchThrottle {
                lock.unlock()
                return
            }
            lastFetch = Date()
            lock.unlock()
            queue.async {
                fetchPage(accumulated: [], thenApplyIn: context)
            }
        }

        static func resetToken() {
            UserDefaults.standard.removeObject(forKey: RemoteProgressSync.defaultsTokenKey)
        }

        private static func storedToken() -> CKServerChangeToken? {
            guard let data = UserDefaults.standard.data(forKey: RemoteProgressSync.defaultsTokenKey),
                  let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
            else { return nil }
            return token
        }

        private static func storeToken(_ token: CKServerChangeToken?) {
            guard let token,
                  let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            else { return }
            UserDefaults.standard.set(data, forKey: RemoteProgressSync.defaultsTokenKey)
        }

        /// Fetches one page of zone changes, following `moreComing` recursively, then
        /// applies everything once on the context's queue. Record callbacks for a zone
        /// precede its fetch-result callback, so `changed` is complete when examined.
        private static func fetchPage(
            accumulated: [CKRecord],
            thenApplyIn context: NSManagedObjectContext
        ) {
            var configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuration.previousServerChangeToken = storedToken()
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: configuration]
            )
            let appendLock = NSLock()
            var changed = accumulated
            // Refined name (the `recordChangedBlock` spelling is the deprecated one):
            // per-record errors arrive here as `.failure` and are logged, never fatal.
            operation.recordWasChangedBlock = { _, result in
                switch result {
                case .success(let record):
                    appendLock.lock()
                    changed.append(record)
                    appendLock.unlock()
                case .failure(let error):
                    DiagnosticLog.log("RemoteProgress record scartato: \(error.localizedDescription)")
                }
            }
            operation.recordWithIDWasDeletedBlock = { _, _ in /* tombstones ignored: we never delete */ }
            operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in storeToken(token) }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let outcome):
                    storeToken(outcome.serverChangeToken)
                    appendLock.lock()
                    let page = changed
                    appendLock.unlock()
                    if outcome.moreComing {
                        fetchPage(accumulated: page, thenApplyIn: context)
                    } else {
                        context.perform {
                            let applied = apply(records: page, in: context)
                            if applied > 0 {
                                AppLog.log("RemoteProgress: applicati \(applied) progressi da altri dispositivi")
                            }
                        }
                    }
                case .failure(let error):
                    handleFetchError(error)
                }
            }
            database.add(operation)
        }

        private static func handleFetchError(_ error: Error) {
            guard let ckError = error as? CKError else {
                DiagnosticLog.log("RemoteProgress fetch fallito: \(error.localizedDescription)")
                return
            }
            switch ckError.code {
            case .zoneNotFound:
                // Nobody pushed yet (or zone deleted): nothing to fetch, not an error.
                break
            case .changeTokenExpired:
                resetToken()
                DiagnosticLog.log("RemoteProgress token scaduto, prossimo fetch completo")
            case .notAuthenticated, .networkFailure, .networkUnavailable:
                DiagnosticLog.log("RemoteProgress fetch rinviato (\(ckError.code.rawValue))")
            default:
                DiagnosticLog.log("RemoteProgress fetch fallito: \(ckError.localizedDescription)")
            }
        }

        /// Matches fetched records to local comics and applies last-writer-wins.
        /// Runs on the context's queue. Returns the number of comics updated.
        @discardableResult
        private static func apply(records: [CKRecord], in context: NSManagedObjectContext) -> Int {
            guard !records.isEmpty else { return 0 }
            // Accounts indexed by sync key (computed once): the stored per-device UUIDs
            // can never match across devices, so this is the only join that works.
            let accountRequest = RemoteAccountEntity.fetchRequest()
            guard let accounts = try? context.fetch(accountRequest), !accounts.isEmpty else { return 0 }
            var accountsByKey: [String: RemoteAccountEntity] = [:]
            var rootsByAccountID: [UUID: String] = [:]
            for account in accounts {
                guard let id = account.id,
                      let syncKey = effectiveSyncKey(for: account),
                      let root = account.serverURL?.absoluteString
                else { continue }
                accountsByKey[syncKey] = account
                rootsByAccountID[id] = root
            }
            var comicsByAccount: [UUID: [ComicEntity]] = [:]
            var applied = 0
            for record in records {
                guard let recordKey = record["accountSyncKey"] as? String,
                      let recordPath = record["serverPath"] as? String,
                      let account = accountsByKey[recordKey],
                      let accountID = account.id,
                      let root = rootsByAccountID[accountID]
                else { continue }
                if comicsByAccount[accountID] == nil {
                    let comicRequest = ComicEntity.fetchRequest()
                    comicRequest.predicate = NSPredicate(format: "sourceAccountID == %@", accountID as CVarArg)
                    comicsByAccount[accountID] = (try? context.fetch(comicRequest)) ?? []
                }
                let remotePage = (record["lastReadPage"] as? NSNumber)?.intValue ?? 0
                let remoteUpdatedAt = record["updatedAt"] as? Date ?? .distantPast
                for comic in comicsByAccount[accountID] ?? [] {
                    guard let source = comic.sourceRelativePath,
                          RemoteProgressSyncKey.serverPath(rootAbsoluteString: root, sourceAbsoluteString: source) == recordPath,
                          RemoteProgressSyncKey.shouldApply(remoteUpdatedAt: remoteUpdatedAt, localDateLastOpened: comic.dateLastOpened)
                    else { continue }
                    // Clamp only when the local page count is known (0 = never opened here):
                    // an unclamped value is corrected at open time by `openProvider`.
                    if comic.pageCount > 0 {
                        comic.lastReadPage = Int32(min(max(remotePage, 0), Int(comic.pageCount) - 1))
                    } else {
                        comic.lastReadPage = Int32(max(remotePage, 0))
                    }
                    comic.dateLastOpened = remoteUpdatedAt
                    applied += 1
                }
            }
            if applied > 0 {
                do {
                    try context.save()
                } catch {
                    DiagnosticLog.log("RemoteProgress apply: salvataggio fallito: \(error.localizedDescription)")
                    return 0
                }
            }
            return applied
        }
    }
}
