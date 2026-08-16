import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Lets the user draw a rectangle over the current page (the one already visible in the
/// reader, behind this view) to share just that panel instead of the whole page — overlaid
/// directly on the same reading screen, not another screen: no opaque background, no image
/// reloaded on its own. In the top right the scissors (green) confirm the crop, the X (red)
/// cancels; the selection box is dashed, with no fill. The fitting geometry must stay
/// identical to the one the page is already drawn with (the same full-screen
/// `.scaledToFit()`), otherwise the selection wouldn't correspond to what's on screen.
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
                        // After a rotation the old selection (in screen coordinates)
                        // no longer corresponds to anything in the new geometry: it must be
                        // discarded, otherwise the displayed rectangle and the computed crop are wrong.
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
        // Only for the pixels to crop from: the page is already visible behind this view, it
        // doesn't need to be redrawn here.
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

    /// Converts the selected rectangle (screen coordinates, image displayed with
    /// scaledToFit) into pixel coordinates of the original image, then crops and shares it.
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
