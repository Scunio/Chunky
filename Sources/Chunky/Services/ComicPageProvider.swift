import Foundation

enum ComicReadError: LocalizedError {
    case unsupportedFormat
    case corruptArchive
    case pageOutOfRange
    case notDownloaded
    case downloadCancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Formato di file non supportato."
        case .corruptArchive:
            return "Impossibile leggere l'archivio: il file potrebbe essere danneggiato o protetto da password."
        case .pageOutOfRange:
            return "Pagina non disponibile."
        case .notDownloaded:
            return "Il fumetto non è ancora stato scaricato da iCloud. Controlla la connessione e riprova."
        case .downloadCancelled:
            return "Download annullato."
        }
    }
}

/// Provides access to a comic's pages, independent of the source format.
protocol ComicPageProvider {
    var pageCount: Int { get }
    func image(atPage index: Int) throws -> PlatformImage

    /// Raw bytes of the page (e.g. the JPEG/PNG inside the archive), when available.
    /// Lets thumbnails be generated without having to re-encode an already-decoded image.
    func rawData(atPage index: Int) throws -> Data?

    /// Contents of ComicInfo.xml if present in the archive, used to populate series/title/number.
    var comicInfoXML: Data? { get }

    /// Already-digital text lines present in the file, if the format has any (the text layer of
    /// a PDF). `nil` means "this page has no extractable text, OCR is needed": that's the case
    /// for all CBZ/CBR files, which are images, and also for PDFs made up of scans only.
    func textLines(atPage index: Int) throws -> [RecognizedTextLine]?
}

extension ComicPageProvider {
    func rawData(atPage index: Int) throws -> Data? { nil }
    var comicInfoXML: Data? { nil }
    func textLines(atPage index: Int) throws -> [RecognizedTextLine]? { nil }
}

enum ComicPageProviderFactory {
    static func makeProvider(for url: URL, format: ComicFormat) throws -> ComicPageProvider {
        switch format {
        case .cbz:
            return try CBZPageProvider(fileURL: url)
        case .pdf:
            return try PDFPageProvider(fileURL: url)
        case .cbr:
            return try CBRPageProvider(fileURL: url)
        }
    }
}
