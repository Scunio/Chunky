import Foundation

/// Grouping of the library by series.
///
/// Lives outside `LibraryView` because it's needed in two places — the grid and the Mac
/// sidebar — and duplicating it would mean seeing two different lists of groups in the
/// same window. Being pure logic, it's also the only part of the grouping that can be tested.
enum LibraryGrouping {
    /// Section for comics that don't belong to any series.
    static let ungroupedTitle = "Altri fumetti"

    struct Section: Identifiable {
        let title: String
        let comics: [ComicEntity]

        var id: String { title }
    }

    /// Series sorted alphabetically; comics without a series end up in a separate section,
    /// at the bottom.
    static func sections(for comics: [ComicEntity]) -> [Section] {
        let groups = Dictionary(grouping: comics) { $0.seriesName ?? ungroupedTitle }
        return groups.keys.sorted { lhs, rhs in
            if lhs == ungroupedTitle { return false }
            if rhs == ungroupedTitle { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { key in
            Section(title: key, comics: (groups[key] ?? []).sorted { ($0.title ?? "") < ($1.title ?? "") })
        }
    }

    /// "TOPOLINO 3594-3687" when the titles end with a number (e.g. periodical issues):
    /// otherwise just the series name.
    static func headerText(title: String, comics: [ComicEntity]) -> String {
        guard title != ungroupedTitle else { return title.uppercased() }
        let numbers = comics.compactMap { issueNumber(fromTitle: $0.title ?? "") }
        guard let min = numbers.min(), let max = numbers.max(), numbers.count == comics.count else {
            return title.uppercased()
        }
        return min == max ? "\(title.uppercased()) \(min)" : "\(title.uppercased()) \(min)-\(max)"
    }

    static func issueNumber(fromTitle title: String) -> Int? {
        let cleaned = titleWithoutTrailingDecorations(title)
        guard let range = cleaned.range(of: #"\d+\s*$"#, options: .regularExpression) else { return nil }
        return Int(cleaned[range].trimmingCharacters(in: .whitespaces))
    }

    /// Strips from the tail of the title what scanned releases append after the issue
    /// number, so the number lands at the end of the string again and is recognizable
    /// once more: parenthesized groups ("Topolino 3652 (Panini 2025-11-19) [c2c CPPT Edition]"),
    /// additions introduced by a "+" ("Topolino 3636 + Cover Abbonati"), and the release's
    /// version number ("… [c2c CPPT Edition] 1.0").
    ///
    /// The version must have at least one dot: that's what distinguishes it from the issue
    /// number, which never has one and must not be touched.
    ///
    /// The loop is needed because decorations are nested — "… [c2c CPPT Edition] 1.1 (corrected
    /// double pages)" has three of them, one inside another.
    static func titleWithoutTrailingDecorations(_ title: String) -> String {
        let patterns = [
            #"\s*\([^()]*\)\s*$"#,
            #"\s*\[[^\[\]]*\]\s*$"#,
            #"\s*\{[^{}]*\}\s*$"#,
            #"\s+\+\s+.*$"#,
            #"\s+v?\d+(?:\.\d+)+\s*$"#,
            #"\s+\d{4}-\d{2}-\d{2}\s*$"#
        ]
        var result = title.trimmingCharacters(in: .whitespaces)
        var keepGoing = true
        while keepGoing {
            keepGoing = false
            for pattern in patterns {
                guard let range = result.range(of: pattern, options: .regularExpression) else { continue }
                result.removeSubrange(range)
                result = result.trimmingCharacters(in: .whitespaces)
                keepGoing = true
            }
        }
        return result
    }
}
