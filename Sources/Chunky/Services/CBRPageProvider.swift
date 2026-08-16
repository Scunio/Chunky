import Foundation
import Unrar

final class CBRPageProvider: ComicPageProvider {
    private let archive: Archive
    private let entries: [Entry]
    let comicInfoXML: Data?
    /// Same reason as `CBZPageProvider.extractionLock`: `Archive.extract` is not safe for
    /// concurrent calls, and double-page spread loads two pages in parallel on different
    /// threads.
    private let extractionLock = NSLock()

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]

    var pageCount: Int { entries.count }

    init(fileURL: URL) throws {
        do {
            let archive = try Archive(fileURL: fileURL)
            self.archive = archive
            let allEntries = try archive.entries().filter { !$0.directory }
            self.entries = allEntries
                .filter { entry in
                    let ext = (entry.fileName as NSString).pathExtension.lowercased()
                    return CBRPageProvider.imageExtensions.contains(ext)
                }
                .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }

            if let metadataEntry = allEntries.first(where: { ($0.fileName as NSString).lastPathComponent.lowercased() == "comicinfo.xml" }) {
                self.comicInfoXML = try? archive.extract(metadataEntry)
            } else {
                self.comicInfoXML = nil
            }
        } catch {
            throw ComicReadError.corruptArchive
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
        guard let data = try? archive.extract(entries[index]) else {
            throw ComicReadError.corruptArchive
        }
        return data
    }
}
