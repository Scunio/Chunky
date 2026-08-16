import Foundation
import ZIPFoundation

final class CBZPageProvider: ComicPageProvider {
    private let archive: Archive
    private let entries: [Entry]
    let comicInfoXML: Data?
    /// `Archive.extract` is not safe for concurrent calls: it reads from a shared file
    /// handle at a precise offset, and two extractions in parallel (e.g. the two pages of a
    /// double-page spread, loaded on different threads) can interleave the reads and
    /// produce corrupted data — confirmed live (`CompressionError.corruptedData` on
    /// both pages when loaded together). Serializes extractions on the same
    /// archive without having to change the protocol's signature or its callers.
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
