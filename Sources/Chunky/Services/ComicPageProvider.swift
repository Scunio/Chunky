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

/// Fornisce accesso alle pagine di un fumetto, indipendentemente dal formato sorgente.
protocol ComicPageProvider {
    var pageCount: Int { get }
    func image(atPage index: Int) throws -> PlatformImage

    /// Byte originali della pagina (es. il JPEG/PNG dentro l'archivio), quando disponibili.
    /// Permette di generare miniature senza dover ri-codificare un'immagine già decodificata.
    func rawData(atPage index: Int) throws -> Data?

    /// Contenuto di ComicInfo.xml se presente nell'archivio, per popolare serie/titolo/numero.
    var comicInfoXML: Data? { get }
}

extension ComicPageProvider {
    func rawData(atPage index: Int) throws -> Data? { nil }
    var comicInfoXML: Data? { nil }
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
