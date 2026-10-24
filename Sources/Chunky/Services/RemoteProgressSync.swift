import CloudKit
import CoreData
import Foundation
#if os(macOS)
import Security
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Syncs reading progress across devices, Infuse-style: only lightweight progress
/// records travel via the app's CloudKit private database.
/// Two populations share this engine and its zone:
/// - remote-library comics (SMB/WebDAV/OPDS): files stay on the share, keyed by
///   `RemoteProgressSyncKey` (deterministic on every device);
/// - iCloud-library comics: files already sync via Drive in the shared ubiquity
///   container, so `relativePath` is identical on every device and needs no pairing —
///   the key is `localLibrarySyncKey` + `relativePath`. This covers what the Core Data
///   mirror can't: near-realtime progress (~10s + manual flush/fetch) instead of
///   Apple's opaque minute-scale latency, with logs showing who wrote which page last.
///
/// Why a separate mechanism instead of relying on the existing Core Data mirroring:
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
    /// Flag: la `CKRecordZoneSubscription` è già stata salvata lato server (una volta
    /// basta, resta lì finché la zona esiste).
    static let subscriptionSavedKey = "ckRemoteProgressSubscriptionSaved"
    /// ID fisso della subscription: ri-salvarla è un upsert idempotente.
    static let pushSubscriptionID = "remote-progress-changes"
    /// Sync key for iCloud-library comics (see the enum docs). Disjoint by construction
    /// from every remote key: derived ones start with `smb/`, `webdav/` or `opds/`,
    /// manual overrides with `custom/`.
    static let localLibrarySyncKey = "icloud-library"

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

    /// Builds a pushable snapshot, or nil when this comic must not sync (remote comic
    /// with gone account or unresolvable server path — all fail-closed).
    @MainActor
    static func snapshot(of comic: ComicEntity) -> Snapshot? {
        if comic.sourceAccountID != nil {
            return remoteSnapshot(of: comic)
        }
        // iCloud-library comic: no account to resolve, `relativePath` is the key.
        guard let relativePath = comic.relativePath, !relativePath.isEmpty else { return nil }
        let progressKey = RemoteProgressSyncKey.progressKey(accountSyncKey: localLibrarySyncKey, serverPath: relativePath)
        return Snapshot(
            recordName: RemoteProgressSyncKey.recordName(forProgressKey: progressKey),
            accountSyncKey: localLibrarySyncKey,
            serverPath: relativePath,
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

    /// Snapshot for a remote-account comic (see the enum docs for why these need
    /// a derived account identity instead of `relativePath`).
    @MainActor
    private static func remoteSnapshot(of comic: ComicEntity) -> Snapshot? {
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

    /// Enqueues a push for comics with syncable progress (remote and iCloud-library;
    /// anything else is silently ignored). Debounced per
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
    /// every ~3 minutes, plus manual scans). Push-triggered calls always pass `force: true`
    /// with a completion so the AppDelegate can answer the system. `completion` reports
    /// how many comics were updated (0 also when the fetch found nothing or failed).
    static func fetchAndApply(in context: NSManagedObjectContext, force: Bool = false, completion: ((Int) -> Void)? = nil) {
        guard isEnabled else { completion?(0); return }
        Engine.fetchAndApply(in: context, force: force, completion: completion)
    }

    /// Creates the server-side zone subscription once, so zone changes arrive as silent
    /// pushes instead of only via polling. Cheap to call on every launch: gated by the
    /// saved flag, CloudKit untouched otherwise. No-op on tvOS (no push delivery there).
    static func ensurePushSubscription() {
        #if os(tvOS)
        return
        #else
        Engine.ensureSubscription()
        #endif
    }

    /// Entry point for the AppDelegate silent-push callbacks (iOS/macOS). Parses the
    /// payload, ignores anything not from our zone, and fetches immediately instead of
    /// waiting for the next poll. The fetch runs on the shared view context directly so
    /// it works even with no UI mounted (background wake). `completion` reports how many
    /// comics were updated.
    static func handlePushNotification(_ userInfo: [AnyHashable: Any], completion: @escaping (Int) -> Void) {
        Engine.handlePushNotification(userInfo, completion: completion)
    }

    /// Drops the zone change token so the next fetch is a full one. Recovery path for
    /// token expiration/corruption (also handled automatically on `.changeTokenExpired`).
    static func resetFetchToken() {
        Engine.resetToken()
    }

    /// One-shot CloudKit account check, logged to Diagnostica at launch: tells "different
    /// iCloud account / sync disabled" apart from delivery problems when mirrored imports
    /// never arrive. Gated like every other entry point (entitlement-less builds never
    /// touch `CKContainer`).
    static func logAccountStatus() {
        Engine.logAccountStatus()
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
        /// Cached result of `checkCloudKitUsable` (entitlements don't change at runtime).
        nonisolated(unsafe) private static var cachedUsable: Bool?
        /// Latest requested snapshot per record: `pushLatest` pops it, so `flush()`
        /// pushes exactly the not-yet-pushed values and nothing stale.
        nonisolated(unsafe) private static var latest: [String: RemoteProgressSync.Snapshot] = [:]
        nonisolated(unsafe) private static var scheduled: [String: DispatchWorkItem] = [:]
        nonisolated(unsafe) private static var lastPush: [String: Date] = [:]
        nonisolated(unsafe) private static var lastFetch = Date.distantPast
        private static let pushDebounce: TimeInterval = 10
        private static let fetchThrottle: TimeInterval = 60

        /// False when this build cannot use CloudKit at all — ad-hoc signing without
        /// the iCloud entitlement (UI tests, sideloaded builds with stripped
        /// entitlements). `CKContainer(identifier:)` doesn't fail gracefully there: it
        /// traps (EXC_BREAKPOINT) instead of returning errors, so every entry point
        /// bails out before touching it. Production builds (App Store/TestFlight/dev
        /// signed, entitlement present) are unaffected.
        static var cloudKitUsable: Bool {
            lock.lock()
            defer { lock.unlock() }
            if let cachedUsable { return cachedUsable }
            let usable = checkCloudKitUsable()
            cachedUsable = usable
            return usable
        }

        private static func checkCloudKitUsable() -> Bool {
            // UI automation runs the app without CloudKit entitlements and with local-only
            // persistence. Keep every CloudKit entry point inert on iOS too; unlike macOS,
            // iOS has no public entitlement-introspection API to detect the stripped build.
            if CommandLine.arguments.contains("--uitesting") { return false }

            #if os(macOS)
            // SecTask is macOS-only (unavailable on iOS/tvOS): verified by probe that
            // `CKContainer(identifier:)` traps (SIGTRAP) instead of failing when the
            // entitlement is missing, so an explicit check is mandatory here.
            guard let task = SecTaskCreateFromSelf(nil),
                  let value = SecTaskCopyValueForEntitlement(
                      task,
                      "com.apple.developer.icloud-container-identifiers" as CFString,
                      nil
                  ) as? [String]
            else { return false }
            return value.contains(RemoteProgressSync.containerIdentifier)
            #else
            // No public entitlement-introspection API on iOS/tvOS; failures there surface
            // as regular CloudKit errors (handled per-operation), never traps — observed
            // on ad-hoc-signed simulator builds. If that ever changes, gate like above.
            return true
            #endif
        }

        private static var database: CKDatabase {
            CKContainer(identifier: RemoteProgressSync.containerIdentifier).privateCloudDatabase
        }

        private static var zoneID: CKRecordZone.ID {
            CKRecordZone.ID(zoneName: RemoteProgressSync.zoneName, ownerName: CKCurrentUserDefaultName)
        }

        // MARK: Push

        static func requestPush(_ snapshot: RemoteProgressSync.Snapshot) {
            guard cloudKitUsable else { return }
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
            guard cloudKitUsable else { return }
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
                // Ricreare la zona invalida anche la subscription ai suoi cambi (es. zona
                // persa dopo un aggiornamento di iOS o un ripristino): la si ricrea, così
                // i push realtime ripartono invece di restare muti col flag già salvato.
                UserDefaults.standard.set(false, forKey: RemoteProgressSync.subscriptionSavedKey)
                saveSubscription()
                completion()
            }
            database.add(operation)
        }

        // MARK: Push subscription (realtime async)

        /// Saves the server-side `CKRecordZoneSubscription` once, so zone changes arrive
        /// as silent pushes instead of only via polling. Gated by the saved flag: the
        /// launch-time call costs nothing once subscribed. Ensures the zone first —
        /// saving the zone is idempotent, so this also heals the "zone never created"
        /// state without a separate code path.
        static func ensureSubscription() {
            guard cloudKitUsable else { return }
            guard !UserDefaults.standard.bool(forKey: RemoteProgressSync.subscriptionSavedKey) else { return }
            let zone = CKRecordZone(zoneName: RemoteProgressSync.zoneName)
            let operation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            operation.modifyRecordZonesResultBlock = { _ in saveSubscription() }
            database.add(operation)
        }

        private static func saveSubscription() {
            let info = CKSubscription.NotificationInfo()
            // Solo content-available: nessun alert/suono/badge, wake silenzioso.
            info.shouldSendContentAvailable = true
            let subscription = CKRecordZoneSubscription(
                zoneID: zoneID, subscriptionID: RemoteProgressSync.pushSubscriptionID
            )
            subscription.notificationInfo = info
            let operation = CKModifySubscriptionsOperation(
                subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil
            )
            operation.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success:
                    UserDefaults.standard.set(true, forKey: RemoteProgressSync.subscriptionSavedKey)
                case .failure(let error as CKError) where error.code == .serverRecordChanged:
                    // Già esistente (es. flag perso): la si considera valida.
                    UserDefaults.standard.set(true, forKey: RemoteProgressSync.subscriptionSavedKey)
                case .failure(let error):
                    DiagnosticLog.log("RemoteProgress subscription non creata: \(error.localizedDescription)")
                }
            }
            database.add(operation)
        }

        /// Handles an incoming silent push: parses the payload, ignores anything not
        /// from our zone, and fetches immediately. Runs on the shared view context
        /// directly (via `perform`, as the polled path does) so it works with no UI
        /// mounted, e.g. on background wake. `completion` reports applied comics.
        static func handlePushNotification(_ userInfo: [AnyHashable: Any], completion: @escaping (Int) -> Void) {
            guard cloudKitUsable else { completion(0); return }
            var dict: [String: NSObject] = [:]
            for (key, value) in userInfo {
                guard let key = key as? String, let value = value as? NSObject else { continue }
                dict[key] = value
            }
            // `note as?` senza optional binding: l'inizializer è failable solo su alcuni
            // SDK, il cast condizionale funziona in entrambi i casi.
            let note = CKNotification(fromRemoteNotificationDictionary: dict)
            guard let zoneNote = note as? CKRecordZoneNotification,
                  zoneNote.recordZoneID?.zoneName == RemoteProgressSync.zoneName
            else {
                completion(0)
                return
            }
            fetchAndApply(in: PersistenceController.shared.container.viewContext, force: true, completion: completion)
        }

        // MARK: Fetch

        static func fetchAndApply(in context: NSManagedObjectContext, force: Bool, completion: ((Int) -> Void)? = nil) {
            guard cloudKitUsable else { completion?(0); return }
            lock.lock()
            if !force, Date().timeIntervalSince(lastFetch) < fetchThrottle {
                lock.unlock()
                completion?(0)
                return
            }
            lastFetch = Date()
            lock.unlock()
            // No remote accounts and no local comics → no record can ever match: skip
            // before touching CloudKit at all. Besides saving pointless traffic for empty
            // libraries, this keeps entitlement-less builds (UI tests) off CloudKit APIs
            // entirely — `CKContainer(identifier:)` traps instead of failing there.
            // (iCloud-library comics match by filename with no account involved, so the
            // gate must count them too, not just remote accounts.)
            // `perform` (not `performAndWait`): safe from any thread, no deadlock risk.
            context.perform {
                let accountCount = (try? context.count(for: RemoteAccountEntity.fetchRequest())) ?? 0
                let comicCount = (try? context.count(for: ComicEntity.fetchRequest())) ?? 0
                guard accountCount > 0 || comicCount > 0 else { completion?(0); return }
                queue.async {
                    fetchPage(accumulated: [], thenApplyIn: context, completion: completion)
                }
            }
        }

        static func resetToken() {
            UserDefaults.standard.removeObject(forKey: RemoteProgressSync.defaultsTokenKey)
        }

        /// Reports `CKContainer.accountStatus` to Diagnostica (see `logAccountStatus`).
        /// The completion handler runs off-main; `DiagnosticLog` is thread-safe.
        static func logAccountStatus() {
            guard cloudKitUsable else {
                DiagnosticLog.log("CloudKit account: non verificabile (build senza entitlement)")
                return
            }
            let container = CKContainer(identifier: RemoteProgressSync.containerIdentifier)
            container.accountStatus { status, error in
                if let error {
                    DiagnosticLog.log("CloudKit account: errore verifica (\(error.localizedDescription))")
                    return
                }
                switch status {
                case .available:
                    DiagnosticLog.log("CloudKit account: disponibile")
                case .noAccount:
                    DiagnosticLog.log("CloudKit account: nessun account iCloud su questo device")
                    return
                case .restricted:
                    DiagnosticLog.log("CloudKit account: con restrizioni")
                    return
                case .couldNotDetermine:
                    DiagnosticLog.log("CloudKit account: non determinabile")
                    return
                @unknown default:
                    DiagnosticLog.log("CloudKit account: stato sconosciuto")
                    return
                }
                // Opaque per-account identifier (local log only): equal on two devices
                // means the same iCloud account, which is what mirrored sync requires.
                container.fetchUserRecordID { recordID, error in
                    if let recordID {
                        DiagnosticLog.log("CloudKit utente: \(recordID.recordName)")
                    } else if let error {
                        DiagnosticLog.log("CloudKit utente: non leggibile (\(error.localizedDescription))")
                    }
                }
            }
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
            thenApplyIn context: NSManagedObjectContext,
            completion: ((Int) -> Void)? = nil
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
                        fetchPage(accumulated: page, thenApplyIn: context, completion: completion)
                    } else {
                        context.perform {
                            let applied = apply(records: page, in: context)
                            if applied > 0 {
                                AppLog.log("RemoteProgress: applicati \(applied) progressi da altri dispositivi")
                            }
                            completion?(applied)
                        }
                    }
                case .failure(let error):
                    handleFetchError(error)
                    completion?(0)
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

        /// Matches one iCloud-library record to local comics by `relativePath` (identical
        /// on every device sharing the ubiquity container) and applies last-writer-wins.
        /// Remote-account comics are skipped even on a path hit: their progress flows
        /// through their own account key, never the shared filename.
        /// Applies to the deterministic survivor only (oldest `dateAdded`, then `id` — the same
        /// order deduplication uses to pick who stays): updating every duplicate would stamp a
        /// fresh `dateLastOpened` on records about to be collapsed, and touching a loser the other
        /// device just deleted re-exports it via the mirror, resurrecting the duplicate.
        /// Returns the number of comics updated. Runs on the context's queue.
        @discardableResult
        private static func applyLocalRecord(
            recordPath: String, remotePage: Int, remoteUpdatedAt: Date,
            in context: NSManagedObjectContext
        ) -> Int {
            let request = ComicEntity.fetchRequest()
            request.predicate = NSPredicate(format: "relativePath == %@", recordPath)
            guard let comics = try? context.fetch(request), !comics.isEmpty else { return 0 }
            // I duplicati condividono lo stesso file: ne resta uno solo dopo la dedup, e il
            // superstite è deterministico (`ComicEntity.precedesAsSurvivor`, lo stesso della dedup).
            // `dateAdded` e `id` sono attributi sincronizzati, quindi ogni device sceglie lo stesso.
            let survivor = ComicEntity.survivor(of: comics.filter { $0.sourceAccountID == nil })
            guard let comic = survivor,
                  RemoteProgressSyncKey.shouldApply(remoteUpdatedAt: remoteUpdatedAt, localDateLastOpened: comic.dateLastOpened)
            else { return 0 }
            if comic.pageCount > 0 {
                comic.lastReadPage = Int32(min(max(remotePage, 0), Int(comic.pageCount) - 1))
            } else {
                comic.lastReadPage = Int32(max(remotePage, 0))
            }
            comic.dateLastOpened = remoteUpdatedAt
            return 1
        }

        /// Matches fetched records to local comics and applies last-writer-wins.
        /// Runs on the context's queue. Returns the number of comics updated.
        @discardableResult
        private static func apply(records: [CKRecord], in context: NSManagedObjectContext) -> Int {
            guard !records.isEmpty else { return 0 }
            // Accounts indexed by sync key (computed once): the stored per-device UUIDs
            // can never match across devices, so this is the only join that works.
            // Empty when there are no remote accounts — iCloud-library records below
            // don't need accounts, so that's not an early return.
            let accountRequest = RemoteAccountEntity.fetchRequest()
            let accounts = (try? context.fetch(accountRequest)) ?? []
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
                      let recordPath = record["serverPath"] as? String
                else { continue }
                let remotePage = (record["lastReadPage"] as? NSNumber)?.intValue ?? 0
                let remoteUpdatedAt = record["updatedAt"] as? Date ?? .distantPast
                if recordKey == RemoteProgressSync.localLibrarySyncKey {
                    applied += applyLocalRecord(
                        recordPath: recordPath, remotePage: remotePage,
                        remoteUpdatedAt: remoteUpdatedAt, in: context
                    )
                    continue
                }
                guard let account = accountsByKey[recordKey],
                      let accountID = account.id,
                      let root = rootsByAccountID[accountID]
                else { continue }
                if comicsByAccount[accountID] == nil {
                    let comicRequest = ComicEntity.fetchRequest()
                    comicRequest.predicate = NSPredicate(format: "sourceAccountID == %@", accountID as CVarArg)
                    comicsByAccount[accountID] = (try? context.fetch(comicRequest)) ?? []
                }
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
