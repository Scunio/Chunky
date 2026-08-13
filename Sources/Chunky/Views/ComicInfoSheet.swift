import SwiftUI

/// Scheda informativa del fumetto, raggiungibile dall'icona "info" del reader. Ospita anche
/// le azioni che prima stavano in un Menu a tendina nell'header: su questo target i Menu con
/// contenuti interattivi si sono già dimostrati inaffidabili (vedi commento in ToolsPanelView),
/// quindi qui usiamo una vera List, coerente col resto dell'app.
struct ComicInfoSheet: View {
    @ObservedObject var comic: ComicEntity
    let loadedPageCount: Int?
    var onJumpToPage: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onToggleReadingDirection: (() -> Void)?
    @Environment(\.presentationMode) private var presentationMode

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationView {
            List {
                Section {
                    row("Titolo", comic.title ?? "")
                    if let series = comic.seriesName, !series.isEmpty {
                        row("Serie", series)
                    }
                    row("Formato", comic.format.rawValue.uppercased())
                }
                Section {
                    let pageCount = loadedPageCount ?? Int(comic.pageCount)
                    row("Pagine", "\(pageCount)")
                    row("Pagina corrente", "\(min(Int(comic.lastReadPage) + 1, max(pageCount, 1)))")
                    row("Progresso", "\(Int(comic.progress * 100))%")
                }
                Section {
                    row("Aggiunto il", Self.dateFormatter.string(from: comic.dateAdded ?? Date()))
                    if let lastOpened = comic.dateLastOpened {
                        row("Ultima lettura", Self.dateFormatter.string(from: lastOpened))
                    }
                }
                if onJumpToPage != nil || onToggleFavorite != nil || onToggleReadingDirection != nil {
                    Section {
                        if let onJumpToPage {
                            Button(action: {
                                presentationMode.wrappedValue.dismiss()
                                onJumpToPage()
                            }) {
                                Label("Vai a pagina...", systemImage: "number")
                            }
                        }
                        if let onToggleFavorite {
                            Button(action: onToggleFavorite) {
                                Label(
                                    comic.isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                                    systemImage: comic.isFavorite ? "star.fill" : "star"
                                )
                            }
                        }
                        if let onToggleReadingDirection {
                            Button(action: onToggleReadingDirection) {
                                Label(
                                    comic.readingDirection == .rightToLeft ? "Direzione: occidentale" : "Direzione: manga",
                                    systemImage: comic.readingDirection == .rightToLeft ? "arrow.right" : "arrow.left"
                                )
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
            .navigationTitle("Info fumetto")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .sheetSized()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
}
