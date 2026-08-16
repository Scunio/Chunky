import Foundation

/// Anchor for tracing back to the test target's bundle. Without SwiftPM there's no
/// `Bundle.module`, and `Bundle.main` in a unit test is the host app, not the test bundle.
private final class BundleToken {}

enum Fixtures {
    static let bundle = Bundle(for: BundleToken.self)

    /// Fixtures are committed under `Tests/ChunkyTests/Fixtures` and copied into the test
    /// target's bundle. See `Scripts/make-fixtures.swift` for how to regenerate them.
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
