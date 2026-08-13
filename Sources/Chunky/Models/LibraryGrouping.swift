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

    /// "TOPOLINO 3594-3687" come nell'originale quando i titoli finiscono con un numero
    /// (es. testate periodiche): altrimenti solo il nome della serie.
    static func headerText(title: String, comics: [ComicEntity]) -> String {
        guard title != ungroupedTitle else { return title.uppercased() }
        let numbers = comics.compactMap { issueNumber(fromTitle: $0.title ?? "") }
        guard let min = numbers.min(), let max = numbers.max(), numbers.count == comics.count else {
            return title.uppercased()
        }
        return min == max ? "\(title.uppercased()) \(min)" : "\(title.uppercased()) \(min)-\(max)"
    }

    static func issueNumber(fromTitle title: String) -> Int? {
        guard let range = title.range(of: #"\d+\s*$"#, options: .regularExpression) else { return nil }
        return Int(title[range].trimmingCharacters(in: .whitespaces))
    }
}
