import Foundation

/// Raggruppamento della libreria per serie.
///
/// Vive fuori da `LibraryView` perché serve in due punti — la griglia e la sidebar del Mac —
/// e duplicarlo significherebbe vedere due elenchi di gruppi diversi nella stessa finestra.
/// Essendo logica pura è anche l'unica parte del raggruppamento che si possa testare.
enum LibraryGrouping {
    /// Sezione per i fumetti che non appartengono a nessuna serie.
    static let ungroupedTitle = "Altri fumetti"

    struct Section: Identifiable {
        let title: String
        let comics: [ComicEntity]

        var id: String { title }
    }

    /// Serie ordinate alfabeticamente; i fumetti senza serie finiscono in una sezione a parte,
    /// in fondo.
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

    /// "TOPOLINO 3594-3687" quando i titoli finiscono con un numero (es. testate periodiche):
    /// altrimenti solo il nome della serie.
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

    /// Toglie dalla coda del titolo quello che i rilasci scansionati ci appendono dopo il numero
    /// dell'albo — i gruppi fra parentesi ("Topolino 3652 (Panini 2025-11-19) [c2c CPPD]") e le
    /// aggiunte introdotte da un "+" ("Topolino 3636 + Cover Abbonati") — così il numero torna in
    /// fondo alla stringa ed è di nuovo riconoscibile.
    ///
    /// Il ciclo serve perché le decorazioni si alternano: tolta la parentesi finale può restare
    /// scoperta una coda con "+", e viceversa.
    static func titleWithoutTrailingDecorations(_ title: String) -> String {
        let patterns = [
            #"\s*\([^()]*\)\s*$"#,
            #"\s*\[[^\[\]]*\]\s*$"#,
            #"\s*\{[^{}]*\}\s*$"#,
            #"\s+\+\s+.*$"#
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
