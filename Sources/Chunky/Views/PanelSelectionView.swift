import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Permette di disegnare un rettangolo sopra la pagina corrente (quella già visibile nel
/// lettore, dietro a questa vista) per condividere solo quella vignetta invece dell'intera
/// pagina — sovrapposta direttamente alla stessa schermata di lettura, non un'altra schermata:
/// nessuno sfondo opaco, nessuna immagine ricaricata a sé. In alto a destra le forbici (verdi)
/// confermano il ritaglio, la X (rossa) annulla; il riquadro di selezione è tratteggiato, senza
/// riempimento. La geometria di fitting deve restare identica a quella con cui la pagina è già
/// disegnata (stesso `.scaledToFit()` a schermo intero), altrimenti la selezione non
/// corrisponderebbe a quello che si vede.
struct PanelSelectionView: View {
    let pageIndex: Int
    let provider: ComicPageProvider
    let onShare: (PlatformImage) -> Void
    let onCancel: () -> Void

    @State private var fullImage: PlatformImage?
    @State private var displaySize: CGSize = .zero
    @State private var dragStart: CGPoint?
    @State private var selection: CGRect = .zero

    private var hasSelection: Bool { selection.width >= 8 && selection.height >= 8 }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .overlay(selectionOverlay)
                    .gesture(dragGesture(in: proxy.size))
                    .onAppear { displaySize = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in
                        // Dopo una rotazione la vecchia selezione (in coordinate schermo)
                        // non corrisponde più a nulla nella nuova geometria: va scartata,
                        // altrimenti il rettangolo mostrato e il ritaglio calcolato sono sbagliati.
                        displaySize = newSize
                        selection = .zero
                        dragStart = nil
                    }
            }

            VStack {
                Spacer()
                if !hasSelection {
                    Text("Trascina per selezionare un'area da condividere")
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(.bottom, 24)
                }
            }

            VStack {
                HStack(spacing: 12) {
                    Spacer()
                    if hasSelection {
                        Button(action: confirmSelection) {
                            Image(systemName: "scissors")
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Circle().fill(Color.green))
                        }
                    }
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Circle().fill(Color.red))
                    }
                }
                .padding()
                Spacer()
            }
        }
        .onAppear(perform: loadImage)
    }

    private func loadImage() {
        // Solo per i pixel da cui ritagliare: la pagina è già visibile dietro, non va
        // ridisegnata qui.
        DispatchQueue.global(qos: .userInitiated).async {
            let image = try? provider.image(atPage: pageIndex)
            DispatchQueue.main.async { fullImage = image }
        }
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if selection.width > 0 && selection.height > 0 {
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundColor(.white)
                .frame(width: selection.width, height: selection.height)
                .position(x: selection.midX, y: selection.midY)
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = dragStart ?? value.startLocation
                if dragStart == nil { dragStart = start }
                let rect = CGRect(
                    x: min(start.x, value.location.x),
                    y: min(start.y, value.location.y),
                    width: abs(value.location.x - start.x),
                    height: abs(value.location.y - start.y)
                )
                selection = rect.intersection(CGRect(origin: .zero, size: size))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Converte il rettangolo selezionato (coordinate schermo, immagine mostrata con
    /// scaledToFit) in coordinate pixel dell'immagine originale, poi ritaglia e condivide.
    private func confirmSelection() {
        guard let fullImage = fullImage, displaySize.width > 0, displaySize.height > 0,
              let cgImage = fullImage.cgImageRepresentation else { return }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let scale = min(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let originX = (displaySize.width - fittedSize.width) / 2
        let originY = (displaySize.height - fittedSize.height) / 2

        let pixelRect = CGRect(
            x: (selection.minX - originX) / scale,
            y: (selection.minY - originY) / scale,
            width: selection.width / scale,
            height: selection.height / scale
        )

        guard let cropped = ImageProcessing.crop(fullImage, to: pixelRect) else { return }
        onShare(cropped)
    }
}
