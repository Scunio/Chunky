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

    /// The id is set by `create(...)` on insertion and is never nil in practice;
    /// this accessor avoids having to unwrap the Core Data-generated Optional on every use.
    var resolvedID: UUID {
        id ?? UUID()
    }

    var password: String? {
        get { KeychainStore.password(forAccount: resolvedID) }
        set {
            if let newValue = newValue, !newValue.isEmpty {
                KeychainStore.savePassword(newValue, forAccount: resolvedID)
            } else {
                KeychainStore.deletePassword(forAccount: resolvedID)
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
