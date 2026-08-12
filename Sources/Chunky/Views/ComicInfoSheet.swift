import SwiftUI

/// Scheda informativa del fumetto, raggiungibile dal menu "..." del reader.
struct ComicInfoSheet: View {
    @ObservedObject var comic: ComicEntity
    let loadedPageCount: Int?
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
