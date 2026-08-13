import Foundation

/// Ancora per risalire al bundle del test target. Senza SwiftPM non esiste `Bundle.module`,
/// e `Bundle.main` in un unit test è l'app ospite, non il bundle dei test.
private final class BundleToken {}

enum Fixtures {
    static let bundle = Bundle(for: BundleToken.self)

    /// Le fixture sono committate sotto `Tests/ChunkyTests/Fixtures` e copiate nel bundle
    /// del test target. Vedi `Scripts/make-fixtures.swift` per come rigenerarle.
    static func url(_ name: String) -> URL? {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return bundle.url(forResource: base, withExtension: ext)
    }

    static func data(_ name: String) throws -> Data {
        guard let url = url(name) else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case .missing(let name):
                return "Fixture mancante nel bundle di test: \(name)"
            }
        }
    }
}
