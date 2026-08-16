import Foundation
import ZIPFoundation

enum FolderToComicError: LocalizedError {
    case noImagesFound
    case archiveCreationFailed

    var errorDescription: String? {
        switch self {
        case .noImagesFound: return "La cartella scelta non contiene immagini."
        case .archiveCreationFailed: return "Impossibile creare il fumetto dalla cartella."
        }
    }
}

/// Turns a folder of images into a CBZ, so a set of loose scans (jpg/png) can
/// enter the library as a proper comic.
enum FolderToComicConverter {
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif"]

    static func makeComic(fromFolder folderURL: URL) throws -> URL {
        let needsSecurityScope = folderURL.startAccessingSecurityScopedResource()
        defer { if needsSecurityScope { folderURL.stopAccessingSecurityScopedResource() } }

        let contents = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let images = contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !images.isEmpty else { throw FolderToComicError.noImagesFound }

        // On iCloud Drive, the files of a folder not yet opened may just be
        // undownloaded placeholders: without waiting for them, they'd end up archived empty/truncated.
        for imageURL in images {
            try? LibraryStorage.ensureDownloaded(imageURL)
        }

        let comicName = folderURL.lastPathComponent.isEmpty ? "Fumetto" : folderURL.lastPathComponent
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(comicName).cbz")
        try? FileManager.default.removeItem(at: destination)

        guard let archive = try? Archive(url: destination, accessMode: .create, pathEncoding: nil) else {
            throw FolderToComicError.archiveCreationFailed
        }

        for (index, imageURL) in images.enumerated() {
            let paddedIndex = String(format: "%04d", index)
            let entryName = "page_\(paddedIndex).\(imageURL.pathExtension.lowercased())"
            try archive.addEntry(with: entryName, fileURL: imageURL, compressionMethod: .deflate)
        }

        return destination
    }
}
