import Foundation
import CoreData

enum RemoteAccountKind: String, CaseIterable, Identifiable {
    case opds
    case webdav
    case smb

    var id: String { rawValue }

    var label: String {
        switch self {
        case .opds: "OPDS (Calibre, Ubooquity...)"
        case .webdav: "WebDAV"
        case .smb: "SMB (NAS)"
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
    /// Il salvataggio è sincrono sul main thread, accodato (`perform`) da qualsiasi
    /// altro thread: un `save` diretto del viewContext da background crasherebbe,
    /// e un `performAndWait` rischierebbe il deadlock sotto test. La persistenza è
    /// comunque garantita dal backfill all'avvio più il save dei flussi di
    /// creazione/modifica (sempre su main subito dopo).
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
        } else {
            // Assegnazione immediata (stabilizza questo object graph per l'operazione
            // in corso), persistenza accodata senza bloccare il thread chiamante.
            context.perform {
                // Un altro thread potrebbe averlo già assegnato nel frattempo.
                if self.id == nil {
                    self.id = new
                    do {
                        try context.save()
                    } catch {
                        AppLog.log("stableID(bg): salvataggio id fallito: \(error.localizedDescription)")
                    }
                }
            }
            id = new
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
        let account = RemoteAccountEntity(context: context)
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
        return account
    }
}
