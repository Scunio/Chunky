import SwiftUI
#if os(iOS)
import UIKit

// Strato UIKit dello zoom del lettore (pinch, pan da zoomata, doppio tap), estratto da
// `ReaderSupportViews.swift`. `ZoomableImageView` e `SpreadZoomableImageView` sono internal e
// non più private perché il contenuto pagina, che le usa, ora sta in un altro file.

/// Pinch-to-zoom, pan da zoomata e doppio-tap sulla pagina come in Foto: un vero `UIScrollView`
/// con zoom nativo, non gesture SwiftUI sovrapposte al pager.
///
/// Il piano iniziale era lasciare che fosse lo `UIScrollView` stesso a "vincere" i tocchi a due
/// dita, appoggiandosi al riconoscimento simultaneo che UIKit gestisce già per gli scroll view
/// annidati. Non basta: `PageTapZones` (le zone invisibili tap-per-girare-pagina) sta *sopra*
/// il contenuto nello stesso ZStack e con `.contentShape(Rectangle())` copre l'intera pagina —
/// per le regole di hit-testing di UIKit è lei a vincere il tocco iniziale, sempre, a
/// prescindere da quale pager sta sotto. Verificato dal vivo con log su `touchesBegan`: zero
/// tocchi arrivavano allo scroll view, nemmeno un tap singolo.
///
/// La soluzione è la stessa già usata per la luminosità a due dita (vedi `WindowPanRelayView`
/// sotto): un recognizer agganciato alla `window`, non a questa view, con `hitTest` che
/// restituisce sempre `nil`. La `window` è antenata di *qualunque* vista colpita dall'hit-test
/// (`PageTapZones` compresa), quindi i suoi recognizer ricevono comunque tutti i tocchi — pinch
/// e pan a due dita compresi — indipendentemente da chi "vince" l'hit-test per il tocco
/// iniziale. Il pinch/pan native di `UIScrollView` (il suo `pinchGestureRecognizer` interno)
/// resta inutilizzato per lo stesso motivo per cui era morto il `MagnificationGesture` SwiftUI
/// originale: guida lo zoom "a mano" da un recognizer esterno, sullo stesso `UIScrollView`, che
/// resta comunque il modo più semplice per avere gratis il rendering con pan/rubber-banding.
///
/// Più `PageView` possono essere vive contemporaneamente (il pager tiene in cache le pagine
/// adiacenti per lo swipe fluido): ogni recognizer agisce solo se il punto del gesto cade nei
/// bounds del proprio scroll view, così solo la pagina davvero visibile risponde.
private final class ZoomingScrollView: UIScrollView {
    weak var coordinator: ZoomableImageView.Coordinator?

    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator?.layOutImage(in: self)
    }
}

/// Non intercetta mai l'hit-testing (vedi il commento su `ZoomableImageView` sopra): i suoi
/// recognizer, agganciati alla window, ricevono comunque ogni tocco perché la window è
/// antenata di qualunque vista colpita dall'hit-test.
private final class ZoomGestureRelayView: UIView {
    weak var coordinator: ZoomableImageView.Coordinator?
    private var recognizers: [UIGestureRecognizer] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        recognizers = []
        guard let window, let coordinator else { return }

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(ZoomableImageView.Coordinator.handlePinch(_:)))
        pinch.delegate = coordinator
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(ZoomableImageView.Coordinator.handlePan(_:)))
        pan.delegate = coordinator
        pan.maximumNumberOfTouches = 1
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(ZoomableImageView.Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coordinator

        for recognizer in [pinch, pan, doubleTap] as [UIGestureRecognizer] {
            recognizer.cancelsTouchesInView = false
            window.addGestureRecognizer(recognizer)
        }
        recognizers = [pinch, pan, doubleTap]
    }

    deinit {
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
    }
}

/// Identico a `ZoomGestureRelayView`, ma per `SpreadZoomableImageView.Coordinator`: i selettori
/// `#selector` sono legati al tipo concreto, quindi non è possibile riusare la stessa classe fra
/// le due (la duplicazione qui è il prezzo di quel vincolo di Objective-C, non una scelta).
private final class SpreadZoomGestureRelayView: UIView {
    weak var coordinator: SpreadZoomableImageView.Coordinator?
    private var recognizers: [UIGestureRecognizer] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        recognizers = []
        guard let window, let coordinator else { return }

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(SpreadZoomableImageView.Coordinator.handlePinch(_:)))
        pinch.delegate = coordinator
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(SpreadZoomableImageView.Coordinator.handlePan(_:)))
        pan.delegate = coordinator
        pan.maximumNumberOfTouches = 1
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(SpreadZoomableImageView.Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coordinator

        for recognizer in [pinch, pan, doubleTap] as [UIGestureRecognizer] {
            recognizer.cancelsTouchesInView = false
            window.addGestureRecognizer(recognizer)
        }
        recognizers = [pinch, pan, doubleTap]
    }

    deinit {
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    let isZoomed: Binding<Bool>
    var isActive: Bool = true
    /// Vero solo nel percorso a doppia pagina (`pairedContent`), dove la larghezza deve
    /// derivare dall'altezza proposta invece che dalla larghezza — vedi `sizeThatFits`.
    var widthFollowsHeight: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(isZoomed: isZoomed) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ZoomingScrollView()
        scrollView.coordinator = context.coordinator
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.isUserInteractionEnabled = false
        scrollView.bounces = false
        scrollView.bouncesZoom = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        let relay = ZoomGestureRelayView(frame: .zero)
        relay.coordinator = context.coordinator
        scrollView.addSubview(relay)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.isZoomed = isZoomed
        context.coordinator.isActive = isActive
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
            // Cambio pagina: si riparte sempre da non zoomato, come nell'app originale (lo
            // zoom non "segue" da una pagina all'altra).
            scrollView.setZoomScale(1, animated: false)
        }
        context.coordinator.layOutImage(in: scrollView)
    }

    /// Permette a `ZoomableImageView` di dimensionarsi come farebbe `Image().scaledToFit()`:
    /// senza questo, un `UIViewRepresentable` non sa calcolare da sé una dimensione dalle
    /// proporzioni dell'immagine, e finirebbe o senza dimensioni o grande quanto lo spazio
    /// disponibile invece che quanto l'immagine.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIScrollView, context: Context) -> CGSize? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let aspect = image.size.width / image.size.height
        func usable(_ value: CGFloat?) -> CGFloat? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
        let width = usable(proposal.width)
        let height = usable(proposal.height)
        // Solo in doppia pagina la larghezza deve derivare dall'altezza a prescindere (vedi
        // `pairedContent`): lì l'HStack propone comunque una larghezza sua, che non è quella
        // che vogliamo. Altrove la larghezza proposta è quella reale del viewport.
        if widthFollowsHeight, let height {
            return CGSize(width: height * aspect, height: height)
        }
        switch (width, height) {
        case let (width?, height?):
            // Tutto il riquadro proposto, non la sagoma della pagina: l'adattamento
            // dell'immagine avviene DENTRO lo scroll view (`layOutImage`), che la centra
            // lasciando le bande di sfondo. Dimensionare invece la vista sulla pagina la
            // incastrava nel proprio rettangolo: a riposo si vedeva uguale, ma da zoomata il
            // contenuto restava tagliato lì dentro e le bande sopra e sotto non venivano mai
            // riempite. (Dare la priorità all'altezza, come faceva il codice originale, è
            // l'errore opposto: la vista diventava più larga dello schermo e il `.clipped()`
            // di `PageView` tagliava la pagina ai lati.)
            return CGSize(width: width, height: height)
        case let (width?, nil):
            return CGSize(width: width, height: width / aspect)
        case let (nil, height?):
            return CGSize(width: height * aspect, height: height)
        case (nil, nil):
            return nil
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var isZoomed: Binding<Bool>
        /// Vedi `ZoomableImageView.isActive` / `PageSpreadView.isActive`: senza questo, pinch,
        /// pan e doppio-tap agiscono anche sulla pagina vicina che il pager tiene viva per lo
        /// swipe, non solo su quella davvero mostrata — verificato dal vivo, tre `Coordinator`
        /// diversi ricevevano lo stesso pinch.
        var isActive = true
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        private var pinchStartScale: CGFloat = 1

        init(isZoomed: Binding<Bool>) { self.isZoomed = isZoomed }

        func layOutImage(in scrollView: UIScrollView) {
            guard let imageView, let image = imageView.image else { return }
            // `layoutSubviews` (che chiama questo metodo, vedi `ZoomingScrollView`) scatta
            // anche DURANTE un pinch o un pan da zoomata, non solo ai cambi di pagina: senza
            // questa guardia, ricalcolare qui il fit "a riposo" e ri-centrare rimetteva la
            // vista a ogni passaggio nella posizione non zoomata, mentre lo zoom/pan restava
            // applicato sopra — il risultato visibile era lo zoom che finiva sempre in alto a
            // sinistra e il contenuto tagliato. Da zoomata la posizione/dimensione la governano
            // `handlePinch`/`handlePan` tramite `zoomScale`/`contentOffset`, non questo metodo.
            guard scrollView.zoomScale <= 1.01 else { return }
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0, image.size.width > 0, image.size.height > 0 else { return }
            let aspect = image.size.width / image.size.height
            var fitSize = boundsSize
            if boundsSize.width / boundsSize.height > aspect {
                fitSize.width = boundsSize.height * aspect
            } else {
                fitSize.height = boundsSize.width / aspect
            }
            if imageView.bounds.size != fitSize {
                imageView.bounds = CGRect(origin: .zero, size: fitSize)
                scrollView.contentSize = fitSize
            }
            center(imageView, in: scrollView)
        }

        private func center(_ imageView: UIImageView, in scrollView: UIScrollView) {
            let boundsSize = scrollView.bounds.size
            var frame = imageView.frame
            frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
            frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
            imageView.frame = frame
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Solo da non-zoomata: da zoomata, ricentrare qui combatterebbe contro il pan
            // dell'utente esattamente come in `layOutImage` — vedi il commento lì.
            if let imageView, scrollView.zoomScale <= 1.01 { center(imageView, in: scrollView) }
            let zoomed = scrollView.zoomScale > 1.01
            if isZoomed.wrappedValue != zoomed { isZoomed.wrappedValue = zoomed }
        }

        /// Riceve ogni tocco a prescindere da chi vince l'hit-test (vedi commento su
        /// `ZoomableImageView`): deve quindi coesistere con tap zone, swipe pagina e con gli
        /// altri recognizer di questo stesso relay.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        private func location(of recognizer: UIGestureRecognizer, in scrollView: UIScrollView) -> CGPoint? {
            guard scrollView.window != nil else { return nil }
            let point = recognizer.location(in: scrollView)
            return scrollView.bounds.contains(point) ? point : nil
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard isActive, let scrollView else { return }
            switch recognizer.state {
            case .began:
                guard location(of: recognizer, in: scrollView) != nil else { return }
                pinchStartScale = scrollView.zoomScale
            case .changed:
                guard location(of: recognizer, in: scrollView) != nil || scrollView.zoomScale > 1.01 else { return }
                let target = min(max(pinchStartScale * recognizer.scale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
                scrollView.zoomScale = target
            default:
                break
            }
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            // Solo pan-da-zoomata: a riposo (scala 1) il trascinamento a un dito resta allo
            // swipe pagina/tap zone sottostanti, esattamente come nella versione SwiftUI
            // originale (`including: scale > 1 ? .all : .subviews`).
            guard isActive, let scrollView, scrollView.zoomScale > 1.01 else { return }
            switch recognizer.state {
            case .began:
                guard location(of: recognizer, in: scrollView) != nil else { return }
            case .changed:
                let translation = recognizer.translation(in: scrollView)
                var offset = scrollView.contentOffset
                offset.x -= translation.x
                offset.y -= translation.y
                let maxX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
                let maxY = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
                offset.x = min(max(offset.x, 0), maxX)
                offset.y = min(max(offset.y, 0), maxY)
                scrollView.contentOffset = offset
                recognizer.setTranslation(.zero, in: scrollView)
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard isActive, let scrollView, let point = location(of: recognizer, in: scrollView) else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let targetScale: CGFloat = 2.5
                let size = scrollView.bounds.size
                let width = size.width / targetScale
                let height = size.height / targetScale
                let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

/// Come `ZoomableImageView`, ma per due pagine affiancate zoomabili come un'unica unità (vedi
/// il commento su `SpreadPairView`): un solo `UIScrollView`, contenuto = le due `UIImageView`
/// una accanto all'altra. Stesso trucco della window per pinch/pan/doppio-tap, per lo stesso
/// motivo — vedi il commento su `ZoomableImageView`.
struct SpreadZoomableImageView: UIViewRepresentable {
    /// Esattamente due immagini, già nell'ordine visivo (sinistra, destra).
    let images: [UIImage]
    let isZoomed: Binding<Bool>
    var isActive: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(isZoomed: isZoomed) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = SpreadZoomingScrollView()
        scrollView.coordinator = context.coordinator
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.isUserInteractionEnabled = false
        scrollView.bounces = false
        scrollView.bouncesZoom = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let container = UIView()
        let leadingImageView = UIImageView()
        let trailingImageView = UIImageView()
        for imageView in [leadingImageView, trailingImageView] {
            imageView.contentMode = .scaleAspectFit
            container.addSubview(imageView)
        }
        scrollView.addSubview(container)
        context.coordinator.container = container
        context.coordinator.leadingImageView = leadingImageView
        context.coordinator.trailingImageView = trailingImageView
        context.coordinator.scrollView = scrollView

        let relay = SpreadZoomGestureRelayView(frame: .zero)
        relay.coordinator = context.coordinator
        scrollView.addSubview(relay)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.isZoomed = isZoomed
        context.coordinator.isActive = isActive
        let spreadChanged = context.coordinator.images.count != images.count
            || zip(context.coordinator.images, images).contains { $0 !== $1 }
        context.coordinator.images = images
        if spreadChanged {
            // Cambio spread: si riparte sempre da non zoomato, esattamente come nel percorso a
            // pagina singola (`ZoomableImageView.updateUIView`). Senza questo lo zoom "seguiva"
            // da uno spread all'altro, e per di più `layOutImages` restava bloccato dalla
            // guardia sullo zoom, lasciando le pagine nuove dentro i frame di quelle vecchie.
            scrollView.setZoomScale(1, animated: false)
        }
        context.coordinator.layOutImages(in: scrollView)
    }

    /// Ricalcola il layout a ogni cambio di bounds reale, non solo quando SwiftUI richiama
    /// `updateUIView` — stesso motivo di `ZoomingScrollView`.
    final class SpreadZoomingScrollView: UIScrollView {
        weak var coordinator: Coordinator?

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.layOutImages(in: self)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var isZoomed: Binding<Bool>
        /// Vedi `ZoomableImageView.Coordinator.isActive`: stesso problema, stessa soluzione,
        /// per lo spread a due pagine.
        var isActive = true
        var images: [UIImage] = []
        weak var container: UIView?
        weak var leadingImageView: UIImageView?
        weak var trailingImageView: UIImageView?
        weak var scrollView: UIScrollView?

        init(isZoomed: Binding<Bool>) { self.isZoomed = isZoomed }

        func layOutImages(in scrollView: UIScrollView) {
            guard
                let container, let leadingImageView, let trailingImageView,
                images.count == 2
            else { return }
            // Le immagini si assegnano solo insieme al ricalcolo dei frame, sotto le guardie:
            // assegnarle prima significherebbe disegnare pagine nuove dentro i frame di quelle
            // vecchie (proporzioni diverse) ogni volta che lo spread cambia da zoomato.
            // Vedi il commento su `ZoomableImageView.Coordinator.layOutImage`: `layoutSubviews`
            // scatta anche durante il pinch/pan da zoomata, e ricalcolare qui la larghezza "a
            // riposo" delle due pagine da `scrollView.bounds` (il viewport, non scalato)
            // rimetteva `container` a dimensione non zoomata mentre lo zoom restava applicato
            // al suo `frame` — risultato: contenuto tagliato o disallineato durante lo zoom.
            guard scrollView.zoomScale <= 1.01 else { return }
            let boundsHeight = scrollView.bounds.height
            guard boundsHeight > 0 else { return }
            if leadingImageView.image !== images[0] { leadingImageView.image = images[0] }
            if trailingImageView.image !== images[1] { trailingImageView.image = images[1] }

            func fitWidth(_ image: UIImage) -> CGFloat {
                guard image.size.height > 0 else { return 0 }
                return boundsHeight * image.size.width / image.size.height
            }
            let leadingWidth = fitWidth(images[0])
            let trailingWidth = fitWidth(images[1])
            leadingImageView.frame = CGRect(x: 0, y: 0, width: leadingWidth, height: boundsHeight)
            trailingImageView.frame = CGRect(x: leadingWidth, y: 0, width: trailingWidth, height: boundsHeight)

            let contentSize = CGSize(width: leadingWidth + trailingWidth, height: boundsHeight)
            if container.bounds.size != contentSize {
                container.bounds = CGRect(origin: .zero, size: contentSize)
                scrollView.contentSize = contentSize
            }
            center(container, in: scrollView)
        }

        private func center(_ container: UIView, in scrollView: UIScrollView) {
            let boundsSize = scrollView.bounds.size
            var frame = container.frame
            frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
            frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
            container.frame = frame
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if let container, scrollView.zoomScale <= 1.01 { center(container, in: scrollView) }
            let zoomed = scrollView.zoomScale > 1.01
            if isZoomed.wrappedValue != zoomed { isZoomed.wrappedValue = zoomed }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        private func location(of recognizer: UIGestureRecognizer, in scrollView: UIScrollView) -> CGPoint? {
            guard scrollView.window != nil else { return nil }
            let point = recognizer.location(in: scrollView)
            return scrollView.bounds.contains(point) ? point : nil
        }

        private var pinchStartScale: CGFloat = 1

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard isActive, let scrollView else { return }
            switch recognizer.state {
            case .began:
                guard location(of: recognizer, in: scrollView) != nil else { return }
                pinchStartScale = scrollView.zoomScale
            case .changed:
                guard location(of: recognizer, in: scrollView) != nil || scrollView.zoomScale > 1.01 else { return }
                let target = min(max(pinchStartScale * recognizer.scale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
                scrollView.zoomScale = target
            default:
                break
            }
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard
                isActive,
                let scrollView,
                scrollView.zoomScale > 1.01
            else { return }
            switch recognizer.state {
            case .began:
                guard location(of: recognizer, in: scrollView) != nil else { return }
            case .changed:
                let translation = recognizer.translation(in: scrollView)
                var offset = scrollView.contentOffset
                offset.x -= translation.x
                offset.y -= translation.y
                let maxX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
                let maxY = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
                offset.x = min(max(offset.x, 0), maxX)
                offset.y = min(max(offset.y, 0), maxY)
                scrollView.contentOffset = offset
                recognizer.setTranslation(.zero, in: scrollView)
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard
                isActive,
                let scrollView,
                let point = location(of: recognizer, in: scrollView)
            else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let targetScale: CGFloat = 2.5
                let size = scrollView.bounds.size
                let width = size.width / targetScale
                let height = size.height / targetScale
                let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

#endif
