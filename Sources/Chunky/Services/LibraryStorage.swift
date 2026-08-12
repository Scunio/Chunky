import Foundation

/// Gestisce la cartella fisica in cui vengono copiati i fumetti importati.
/// Se l'utente ha iCloud Drive attivo, usa il container ubiquity dell'app (i file
/// sincronizzano automaticamente su tutti i dispositivi); altrimenti ricade sulla
/// cartella Documents locale della sandbox.
enum LibraryStorage {
    private static let ubiquityContainerID = "iCloud.com.scunio.Chunky"
    private static let comicsFolderName = "Comics"

    nonisolated(unsafe) private static var cachedRootURL: URL?

    /// True se l'utente ha iCloud Drive attivo e il container ubiquity dell'app è raggiungibile:
    /// in tal caso i fumetti importati sincronizzano automaticamente su tutti i dispositivi.
    static var isICloudAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: ubiquityContainerID) != nil
    }

    static func rootFolderURL() -> URL {
        if let cached = cachedRootURL {
            return cached
        }
        let root: URL
        if let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: ubiquityContainerID) {
            root = ubiquityURL.appendingPathComponent("Documents").appendingPathComponent(comicsFolderName)
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            root = documents.appendingPathComponent(comicsFolderName)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cachedRootURL = root
        return root
    }

    static func fileURL(forRelativePath relativePath: String) -> URL {
        rootFolderURL().appendingPathComponent(relativePath)
    }

    /// Copia un file scelto dall'utente (via file importer / document picker) nella libreria,
    /// gestendo eventuali nomi duplicati, e restituisce il percorso relativo salvato nel modello.
    static func importFile(from sourceURL: URL) throws -> String {
        let needsSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if needsSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let root = rootFolderURL()
        var destinationName = sourceURL.lastPathComponent
        var destinationURL = root.appendingPathComponent(destinationName)

        var suffix = 1
        let baseName = (destinationName as NSString).deletingPathExtension
        let ext = (destinationName as NSString).pathExtension
        while FileManager.default.fileExists(atPath: destinationURL.path) {
            destinationName = "\(baseName) \(suffix).\(ext)"
            destinationURL = root.appendingPathComponent(destinationName)
            suffix += 1
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationName
    }

    static func removeFile(relativePath: String) {
        let url = fileURL(forRelativePath: relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    /// Su un secondo dispositivo un file nella libreria iCloud può essere solo un
    /// placeholder non ancora scaricato: lo richiede e attende (bloccando, va quindi
    /// chiamata fuori dal thread principale) prima che venga aperto come archivio.
    static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 30) throws {
        guard FileManager.default.isUbiquitousItem(at: url) else { return }

        func currentStatus() -> URLUbiquitousItemDownloadingStatus? {
            try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        }

        if currentStatus() == .current { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentStatus() == .current { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ComicReadError.notDownloaded
    }

    /// Include o esclude la cartella della libreria dai backup di iCloud/iTunes. Rilevante solo
    /// quando si ricade sulla cartella locale (senza iCloud Drive attivo, quella iCloud è già
    /// gestita dalla sincronizzazione stessa).
    static func setExcludedFromBackup(_ excluded: Bool) {
        var url = rootFolderURL()
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = excluded
        try? url.setResourceValues(resourceValues)
    }
}
