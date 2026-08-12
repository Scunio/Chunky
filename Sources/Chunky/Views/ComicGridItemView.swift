import SwiftUI

struct ComicGridItemView: View {
    @ObservedObject var comic: ComicEntity

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
                // .overlay(_:alignment:) (non la variante a closure, iOS15+) per restare
                // compatibili con il target minimo iOS14.
                .overlay(progressBar, alignment: .bottom)
                .overlay(finishedBadge, alignment: .topTrailing)
                .overlay(favoriteBadge, alignment: .topLeading)

            Text(comic.title ?? "Senza titolo")
                .font(.caption.bold())
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    @ViewBuilder
    private var finishedBadge: some View {
        if comic.isFinished {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.white)
                .padding(6)
                .background(Color.accentColor)
                .clipShape(Circle())
                .padding(6)
        }
    }

    @ViewBuilder
    private var favoriteBadge: some View {
        if comic.isFavorite {
            Image(systemName: "star.fill")
                .foregroundColor(.yellow)
                .padding(6)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
                .padding(6)
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
