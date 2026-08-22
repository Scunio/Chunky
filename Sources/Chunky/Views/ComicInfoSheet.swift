import SwiftUI

/// Info sheet for the comic, reachable from the reader's "info" icon. Also hosts
/// actions (jump to page, favorites, reading direction): on this target, Menus with
/// interactive content have proven unreliable (see ToolsPanelView), so here we use a
/// real List instead.
struct ComicInfoSheet: View {
    @ObservedObject var comic: ComicEntity
    let loadedPageCount: Int?
    var onJumpToPage: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onToggleReadingDirection: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        #if os(tvOS)
        TVPanel(title: "Info fumetto") {
            Button("Chiudi") { dismiss() }
        } content: {
            listContent
        }
        .sheetSized()
        #else
        NavigationStack {
            listContent
                .navigationTitle("Info fumetto")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Chiudi") { dismiss() }
                    }
                }
        }
        .sheetSized()
        #endif
    }

    private var listContent: some View {
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
                            dismiss()
                            onJumpToPage()
                        }) {
                            actionLabel("Vai a pagina...", systemImage: "number")
                        }
                    }
                    if let onToggleFavorite {
                        Button(action: onToggleFavorite) {
                            actionLabel(
                                comic.isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                                systemImage: comic.isFavorite ? "star.fill" : "star"
                            )
                        }
                    }
                    if let onToggleReadingDirection {
                        Button(action: onToggleReadingDirection) {
                            actionLabel(
                                comic.readingDirection == .rightToLeft ? "Direzione: occidentale" : "Direzione: manga",
                                systemImage: comic.readingDirection == .rightToLeft ? "arrow.right" : "arrow.left"
                            )
                        }
                    }
                }
                .foregroundColor(.primary)
            }
        }
    }

    /// tvOS renders `Label`'s icon and title with zero gap between them in list rows;
    /// an explicit layout keeps a readable spacing there while iOS/macOS keep the
    /// system label with its own metrics.
    private func actionLabel(_ title: String, systemImage: String) -> some View {
        #if os(tvOS)
        tvOSRowLabel(title, systemImage: systemImage)
        #else
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
        #endif
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
