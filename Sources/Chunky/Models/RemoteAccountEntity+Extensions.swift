import Foundation
import CoreData

enum RemoteAccountKind: String, CaseIterable, Identifiable {
    case opds
    case webdav
    case smb

    var id: String { rawValue }

    var label: String {
        switch self {
        case .opds: AppLocalization.localizedString("OPDS (Calibre, Ubooquity...)", comment: "Remote account type")
        case .webdav: AppLocalization.localizedString("WebDAV", comment: "Remote account type")
        case .smb: AppLocalization.localizedString("SMB (NAS)", comment: "Remote account type")
        }
    }

    var systemImage: String {
        switch self {
        case .opds: "books.vertical"
        case .webdav: "externaldrive.connected.to.line.below"
        case .smb: "server.rack"
        }
    }
}

extension RemoteAccountEntity {
    var kind: RemoteAccountKind {
        RemoteAccountKind(rawValue: kindRawValue ?? "") ?? .opds
    }

    var serverURL: URL? {
        URL(string: serverURLString ?? "")
    }

    /// ID stabile per il Keychain. `id` è opzionale nel modello e gli account creati
    /// prima della sua introduzione ce l'hanno a nil: un `id ?? UUID()` inline
    /// restituirebbe un UUID diverso a OGNI accesso e scrittura e lettura nel
    /// Keychain non si incontrerebbero mai — password "sbiancata" a ogni Modifica
    /// anche con l'entitlement a posto. Qui l'id viene assegnato una volta sola.
    /// L'assegnazione avviene sempre sulla coda del suo contesto, mai da un thread estraneo:
    /// - main thread: sincrona, come prima;
    /// - contesto privato (background, e i test): sincrona con `performAndWait`, che gira in linea
    ///   se siamo già sulla sua coda — si restituisce l'id davvero salvato, così due letture
    ///   ravvicinate non producono due UUID diversi;
    /// - contesto del main letto da un altro thread: accodata con `perform` (un `performAndWait`
    ///   verso il main rischierebbe il deadlock), senza scrivere sull'oggetto da qui.
    /// Prima il ramo "non main" accodava il save *e* scriveva `id` dal thread chiamante: le due
    /// scritture concorrenti sullo stesso contesto mandavano in crash Core Data
    /// ("-[__NSCFSet addObject:]: attempt to insert nil", visto nei test).
    /// La persistenza è comunque garantita dal backfill all'avvio più il save dei flussi di
    /// creazione/modifica.
    var stableID: UUID {
        if let id { return id }
        let new = UUID()
        // Se questa riga si ripete per lo stesso account, l'id non persiste
        // (save fallito) e ogni accesso usa un UUID diverso: smoking gun.
        AppLog.log("Account senza id: generato \(new.uuidString)")
        guard let context = managedObjectContext else {
            id = new
            return new
        }
        if Thread.isMainThread {
            id = new
            do {
                try context.save()
            } catch {
                AppLog.log("stableID: salvataggio id fallito: \(error.localizedDescription)")
            }
            return new
        }
        if context.concurrencyType == .privateQueueConcurrencyType {
            var result = new
            context.performAndWait {
                // Un altro thread potrebbe averlo già assegnato nel frattempo.
                if let existing = self.id {
                    result = existing
                    return
                }
                self.id = new
                do {
                    try context.save()
                } catch {
                    AppLog.log("stableID(bg): salvataggio id fallito: \(error.localizedDescription)")
                }
            }
            return result
        }
        context.perform {
            if self.id == nil {
                self.id = new
                do {
                    try context.save()
                } catch {
                    AppLog.log("stableID(main da bg): salvataggio id fallito: \(error.localizedDescription)")
                }
            }
        }
        return new
    }

    /// Assegna un `id` persistente agli account che ne sono privi (creati prima della
    /// sua introduzione) — chiamato all'avvio così da qui in poi ogni accesso al
    /// Keychain usa una chiave stabile. Idempotente: senza orfani non tocca lo store.
    static func backfillMissingIDs(in context: NSManagedObjectContext) {
        let request = RemoteAccountEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == nil")
        guard let orphans = try? context.fetch(request), !orphans.isEmpty else { return }
        for account in orphans { account.id = UUID() }
        do {
            try context.save()
            AppLog.log("CoreData: backfill id per \(orphans.count) account senza id")
        } catch {
            AppLog.log("CoreData: backfill id fallito: \(error.localizedDescription)")
        }
    }

    // MARK: - Password on this device

    /// UserDefaults (per device, never synced) marker: this device created or saved this
    /// account, so a missing Keychain password here is the user's choice, not a sync gap.
    private static func configuredOnThisDeviceKey(_ id: UUID) -> String {
        "remoteAccountConfiguredOnThisDevice_" + id.uuidString
    }

    static func markConfiguredOnThisDevice(_ id: UUID) {
        UserDefaults.standard.set(true, forKey: configuredOnThisDeviceKey(id))
    }

    /// True for an account that arrived through the CloudKit mirror from another device: the
    /// configuration syncs, the password (device-local Keychain) does not. Such an account has
    /// a user name but no password here, and was never saved on this device. Scanning it would
    /// only fail every few minutes — and write that failure into the mirrored `lastScanError`/
    /// `lastScanDate`, overwriting the other device's status — so scans skip it and the
    /// Accounts list asks for the password instead.
    ///
    /// Reads `id` directly, not `stableID`/`password`: those can save the context as a side
    /// effect, which a status check must never do.
    /// Accounts created before the marker existed: remote-account comics live in the
    /// local-only store, so an account with at least one comic *on this device* was set up
    /// here — including one with a user name and a deliberately empty password (SMB guest),
    /// which must keep scanning instead of asking for a password.
    static func markAccountsWithLocalComicsAsConfigured(in context: NSManagedObjectContext) {
        let request = NSFetchRequest<NSDictionary>(entityName: "ComicEntity")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["sourceAccountID"]
        request.returnsDistinctResults = true
        request.predicate = NSPredicate(format: "sourceAccountID != nil")
        guard let rows = try? context.fetch(request) else { return }
        for row in rows {
            if let id = row["sourceAccountID"] as? UUID { markConfiguredOnThisDevice(id) }
        }
    }

    var needsPasswordOnThisDevice: Bool {
        guard let id else { return false }
        let user = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { return false }
        guard !UserDefaults.standard.bool(forKey: Self.configuredOnThisDeviceKey(id)) else { return false }
        return KeychainStore.password(forAccount: id) == nil
    }

    var password: String? {
        get { KeychainStore.password(forAccount: stableID) }
        set {
            if let newValue = newValue, !newValue.isEmpty {
                KeychainStore.savePassword(newValue, forAccount: stableID)
            } else {
                KeychainStore.deletePassword(forAccount: stableID)
            }
        }
    }

    @discardableResult
    static func create(
        kind: RemoteAccountKind,
        name: String,
        serverURLString: String,
        username: String?,
        password: String?,
        portNumber: Int32 = 445,
        shareName: String? = nil,
        domainOrWorkgroup: String? = nil,
        resolvedAddressOverride: String? = nil,
        autoScanEnabled: Bool = true,
        smartFoldersEnabled: Bool = true,
        preCacheDetailsEnabled: Bool = true,
        preCacheCoversEnabled: Bool = true,
        in context: NSManagedObjectContext
    ) -> RemoteAccountEntity {
        // Come in `ComicEntity.create`: risoluzione nel modello del context, mai globale.
        guard let account = NSEntityDescription.insertNewObject(forEntityName: "RemoteAccountEntity", into: context) as? RemoteAccountEntity else {
            fatalError("RemoteAccountEntity non trovata nel modello del context")
        }
        let newID = UUID()
        account.id = newID
        account.kindRawValue = kind.rawValue
        account.name = name
        account.serverURLString = serverURLString
        account.username = username
        account.dateAdded = Date()
        account.portNumber = portNumber
        account.shareName = shareName
        account.domainOrWorkgroup = domainOrWorkgroup
        account.resolvedAddressOverride = resolvedAddressOverride
        account.autoScanEnabled = autoScanEnabled
        account.smartFoldersEnabled = smartFoldersEnabled
        account.preCacheDetailsEnabled = preCacheDetailsEnabled
        account.preCacheCoversEnabled = preCacheCoversEnabled
        if let password = password, !password.isEmpty {
            KeychainStore.savePassword(password, forAccount: newID)
        }
        markConfiguredOnThisDevice(newID)
        return account
    }
}
