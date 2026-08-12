import Foundation

/// Metadati letti da `ComicInfo.xml` (standard ComicRack/ComicBookLover), quando presente
/// dentro l'archivio CBZ/CBR. È ciò che permette a una libreria di auto-organizzarsi per
/// serie invece di mostrare solo il nome del file.
struct ComicInfoMetadata {
    var series: String?
    var title: String?
    var number: String?

    static func parse(from data: Data) -> ComicInfoMetadata? {
        let parser = XMLParser(data: data)
        let delegate = ComicInfoXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        guard delegate.series != nil || delegate.title != nil || delegate.number != nil else { return nil }
        return ComicInfoMetadata(series: delegate.series, title: delegate.title, number: delegate.number)
    }
}

private final class ComicInfoXMLDelegate: NSObject, XMLParserDelegate {
    var series: String?
    var title: String?
    var number: String?

    private var currentElement: String?
    private var currentText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch elementName {
        case "Series": series = trimmed
        case "Title": title = trimmed
        case "Number": number = trimmed
        default: break
        }
        currentElement = nil
    }
}
