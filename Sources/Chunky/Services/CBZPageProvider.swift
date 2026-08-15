import Foundation
import ZIPFoundation

final class CBZPageProvider: ComicPageProvider {
    private let archive: Archive
    private let entries: [Entry]
    let comicInfoXML: Data?
    /// `Archive.extract` non è sicuro per chiamate concorrenti: legge da un file handle
    /// condiviso a un offset preciso, e due estrazioni in parallelo (es. le due pagine di uno
    /// spread in doppia pagina, caricate su thread diversi) possono interfogliare le letture e
    /// produrre dati corrotti — verificato dal vivo (`CompressionError.corruptedData` su
    /// entrambe le pagine quando caricate insieme). Serializza le estrazioni sullo stesso
    /// archivio senza dover cambiare la firma del protocollo né i chiamanti.
    private let extractionLock = NSLock()

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]

    var pageCount: Int { entries.count }

    init(fileURL: URL) throws {
        guard let archive = try? Archive(url: fileURL, accessMode: .read, pathEncoding: nil) else {
            throw ComicReadError.corruptArchive
        }
        self.archive = archive
        let allFileEntries = archive.filter { $0.type == .file }
        self.entries = allFileEntries
            .filter { entry in
                let ext = (entry.path as NSString).pathExtension.lowercased()
                return CBZPageProvider.imageExtensions.contains(ext)
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        if let metadataEntry = allFileEntries.first(where: { ($0.path as NSString).lastPathComponent.lowercased() == "comicinfo.xml" }) {
            var data = Data()
            _ = try? archive.extract(metadataEntry) { chunk in data.append(chunk) }
            self.comicInfoXML = data.isEmpty ? nil : data
        } else {
            self.comicInfoXML = nil
        }
    }

    func image(atPage index: Int) throws -> PlatformImage {
        guard let data = try rawData(atPage: index), let image = PlatformImage.from(data: data) else {
            throw ComicReadError.corruptArchive
        }
        return image
    }

    func rawData(atPage index: Int) throws -> Data? {
        guard entries.indices.contains(index) else {
            throw ComicReadError.pageOutOfRange
        }
        extractionLock.lock()
        defer { extractionLock.unlock() }
        var data = Data()
        _ = try archive.extract(entries[index]) { chunk in
            data.append(chunk)
        }
        return data
    }
}
