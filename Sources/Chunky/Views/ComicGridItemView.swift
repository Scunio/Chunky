import SwiftUI

struct ComicGridItemView: View {
    @ObservedObject var comic: ComicEntity
    /// Unica fonte di verità per il badge "da scaricare": una `NSMetadataQuery` viva a livello
    /// di libreria, così il badge si aggiorna da solo quando il download termina invece di
    /// dipendere da un ridisegno della griglia per altri motivi.
    @ObservedObject private var downloadTracker = ICloudDownloadTracker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // .overlay(alignment:), non uno ZStack con figli condizionali: dentro una
            // LazyVGrid uno ZStack a volte non ridimensiona/posiziona correttamente i figli
            // aggiunti via "if" (osservato empiricamente — la stessa barra di progresso
            // compariva nella tray orizzontale "Nuovi" ma non nella griglia sottostante).
            coverImage
                .aspectRatio(2/3, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
                .cornerRadius(8)
                // Un fumetto già finito si vede a colpo d'occhio, come una spunta fatta
                // su una lista: non serve leggere il badge per capire lo stato.
                .saturation(comic.isFinished ? 0 : 1)
                .opacity(comic.isFinished ? 0.55 : 1)
                .overlay(progressBar, alignment: .bottom)
                .overlay(finishedBadge, alignment: .topTrailing)
                .overlay(favoriteBadge, alignment: .topLeading)
                .overlay(pendingDownloadBadge, alignment: .bottomTrailing)

            Text(comic.title ?? "Senza titolo")
                .font(.caption.bold())
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isPendingDownload: Bool {
        guard let relativePath = comic.relativePath else { return false }
        return downloadTracker.pendingRelativePaths.contains(relativePath)
    }

    @ViewBuilder
    private var progressBar: some View {
        // ProgressView nativo invece di calcolare a mano la larghezza con GeometryReader:
        // in una LazyVGrid quest'ultimo si è dimostrato inaffidabile (a volte non riceveva
        // una larghezza valida e la barra spariva del tutto, in modo incoerente tra celle).
        if comic.progress > 0 && !comic.isFinished {
            // Il valore mostrato è alzato a un minimo visivo (non il vero progresso salvato):
            // a inizio lettura di un fumetto lungo il progresso reale è troppo piccolo per
            // essere percepito come una barra, anche col contrasto qui sotto.
            ProgressView(value: max(comic.progress, 0.08))
                .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                .frame(height: 5)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
                .background(
                    Capsule().fill(Color.black.opacity(0.4))
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                )
        }
    }

    private func badge(systemImage: String, foreground: Color, background: Color) -> some View {
        Image(systemName: systemImage)
            .foregroundColor(foreground)
            .padding(6)
            .background(background)
            .clipShape(Circle())
            .padding(6)
    }

    @ViewBuilder
    private var finishedBadge: some View {
        if comic.isFinished {
            badge(systemImage: "checkmark.circle.fill", foreground: .white, background: .accentColor)
        }
    }

    @ViewBuilder
    private var favoriteBadge: some View {
        if comic.isFavorite {
            badge(systemImage: "star.fill", foreground: .yellow, background: Color.black.opacity(0.5))
        }
    }

    /// Mostrato se il fumetto è solo un placeholder iCloud, non ancora scaricato in locale:
    /// senza questo indizio, aprirlo può far comparire un errore dopo un lungo caricamento
    /// senza che sia chiaro il motivo.
    @ViewBuilder
    private var pendingDownloadBadge: some View {
        if isPendingDownload {
            badge(systemImage: "icloud.and.arrow.down", foreground: .white, background: Color.black.opacity(0.5))
        }
    }

    @ViewBuilder
    private var coverImage: some View {
        if let data = comic.coverImageData, let platformImage = PlatformImage.from(data: data) {
            platformImage.asSwiftUIImage
                .resizable()
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .overlay(
                    Image(systemName: "book.closed")
                        .font(.title)
                        .foregroundColor(.secondary)
                )
        }
    }
}
