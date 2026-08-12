import SwiftUI

/// Popover con l'anteprima rapida dell'ultimo fumetto aperto: copertina, titolo, pagina
/// corrente, e un tocco per riprendere subito la lettura senza cercarlo in libreria.
struct NowReadingView: View {
    @ObservedObject var comic: ComicEntity
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ora in lettura")
                    .font(.subheadline.bold())
                    .foregroundColor(.secondary)
                HStack(spacing: 12) {
                    ComicGridItemView(comic: comic)
                        .frame(width: 70, height: 105)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(comic.title ?? "")
                            .font(.headline)
                            .lineLimit(2)
                        Text("\(min(Int(comic.lastReadPage) + 1, max(Int(comic.pageCount), 1))) / \(comic.pageCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding()
        .frame(width: 280)
    }
}
