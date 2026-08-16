import SwiftUI
#if os(iOS)
import UIKit
#endif

// Contenuto di una pagina o di uno spread: quale immagine mostrare, come caricarla e come
// dimensionarla. Estratto da `ReaderSupportViews.swift`; lo strato di zoom sta in
// `ReaderZoomViews.swift`, il pager in `ReaderPagerViews.swift`.

/// Mostra una singola pagina, o due affiancate in modalità doppia pagina. In un ambiente
/// con layoutDirection .rightToLeft, l'HStack viene automaticamente rispecchiato da SwiftUI:
/// la pagina con indice più basso resta quindi a destra, come da convenzione manga.
struct PageSpreadView: View {
    let provider: ComicPageProvider
    let leadingIndex: Int
    /// Con la copertina "da sola" attiva, non tutti gli spread hanno la stessa larghezza (la
    /// copertina è 1 pagina, il resto 2), quindi serve la paginazione intera per sapere se
    /// *questo* spread specifico ne mostra una o due.
    let pagination: ReaderPagination
    let isZoomed: Binding<Bool>
    /// Solo macOS: quando presente, le `PageView` la consultano invece di ridecodificare da
    /// disco a ogni ricomparsa. `nil` su iOS, dove il problema non esiste (la cache di
    /// `UIHostingController` in `PageTurnPager` evita già la ricomparsa).
    var imageCache: PageImageCache?
    #if os(iOS)
    /// Vero solo per lo spread davvero mostrato: il pager tiene vivi anche 1-2 spread vicini
    /// per lo swipe, e ognuno monta il proprio `ZoomableImageView`/`SpreadZoomableImageView`
    /// con gesture recognizer agganciati alla `window` (vedi il commento lì). Senza questo
    /// flag, il pinch/doppio-tap su QUALUNQUE spread arriva anche a quelli fuori schermo —
    /// verificato dal vivo con log di debug: un pinch su una pagina faceva scattare `.began`
    /// su tre `Coordinator` diversi contemporaneamente, e uno spread pre-caricato poteva
    /// restare con uno zoom "fantasma" che poi appariva ritagliato non appena diventava quello
    /// visibile.
    var isActive: Bool = true
    @Environment(\.layoutDirection) private var layoutDirection
    #endif

    /// Vero solo se questo specifico spread contiene due pagine: con `coverIsAlone`, lo
    /// spread che inizia alla copertina (indice 0) resta largo 1 anche a passo 2.
    private var showsSecondPage: Bool {
        guard pagination.pageStep > 1, leadingIndex + 1 < pagination.pageCount else { return false }
        let starts = pagination.spreadStarts
        guard let spreadIndex = starts.firstIndex(of: leadingIndex) else { return pagination.pageStep > 1 }
        let nextStart = spreadIndex + 1 < starts.count ? starts[spreadIndex + 1] : pagination.pageCount
        return nextStart - leadingIndex >= 2
    }

    var body: some View {
        // Il GeometryReader qui (non più dentro ogni PageView) è ciò che permette alle due
        // pagine di uno spread di toccarsi: passando un'altezza fissa e lasciando che la
        // larghezza segua le proporzioni dell'immagine, l'HStack le dimensiona in base al
        // loro contenuto invece di dividere lo spazio a metà a prescindere — che è quello che
        // causava la fascia nera tra le pagine (ciascuna centrata nella propria metà, con
        // margini indipendenti anziché uniti).
        GeometryReader { proxy in
            #if os(iOS)
            // Su iOS, con due pagine, un unico contenitore di zoom per l'intera coppia (come fa
            // Aidoku, `ReaderDoublePageViewController`) invece di due `PageView` indipendenti:
            // permette di ingrandire un dettaglio a cavallo delle due pagine, cosa impossibile
            // con due scroll view separate — ed è anche il motivo per cui, coi due indipendenti,
            // servirebbe indovinare quale delle due il pinch dovrebbe "vincere".
            if showsSecondPage {
                SpreadPairView(
                    provider: provider,
                    leadingIndex: leadingIndex,
                    rightToLeft: layoutDirection == .rightToLeft,
                    height: proxy.size.height,
                    isZoomed: isZoomed,
                    imageCache: imageCache,
                    isActive: isActive
                )
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            } else {
                PageView(
                    provider: provider, index: leadingIndex, isDoublePage: pagination.pageStep > 1,
                    isZoomed: isZoomed, imageCache: imageCache, pairedHeight: nil, isActive: isActive
                )
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            }
            #else
            HStack(spacing: 0) {
                PageView(
                    provider: provider, index: leadingIndex, isDoublePage: pagination.pageStep > 1,
                    isZoomed: isZoomed, imageCache: imageCache,
                    pairedHeight: showsSecondPage ? proxy.size.height : nil
                )
                if showsSecondPage {
                    PageView(
                        provider: provider, index: leadingIndex + 1, isDoublePage: pagination.pageStep > 1,
                        isZoomed: isZoomed, imageCache: imageCache, pairedHeight: proxy.size.height
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            #endif
        }
    }
}

#if os(iOS)
/// Le due pagine di uno spread, caricate insieme e mostrate in un unico `UIScrollView`
/// zoomabile (vedi `SpreadZoomableImageView`) invece di due indipendenti: permette il pinch
/// su un dettaglio a cavallo del confine tra le pagine, e non serve decidere quale delle due
/// "vince" il gesto.
private struct SpreadPairView: View {
    let provider: ComicPageProvider
    let leadingIndex: Int
    let rightToLeft: Bool
    let height: CGFloat
    let isZoomed: Binding<Bool>
    var imageCache: PageImageCache?
    var isActive: Bool = true

    @ObservedObject private var theme = AppTheme.shared
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    @State private var leadingImage: PlatformImage?
    @State private var trailingImage: PlatformImage?
    @State private var leadingFailed = false
    @State private var trailingFailed = false

    var body: some View {
        Group {
            if let leadingImage, let trailingImage {
                // L'ordine visivo (quale pagina sta a sinistra) segue il verso di lettura: nei
                // manga (RTL) l'indice più basso sta a destra.
                let ordered = rightToLeft ? [trailingImage, leadingImage] : [leadingImage, trailingImage]
                SpreadZoomableImageView(images: ordered, isZoomed: isZoomed, isActive: isActive)
                    .frame(height: height)
                    .overlay(tintOverlay)
            } else {
                // Stima 2:3 a testa finché non si conoscono le proporzioni reali.
                HStack(spacing: 0) {
                    pageSlot(index: leadingIndex, failed: leadingFailed) {
                        loadPage(index: leadingIndex) { leadingImage = $0 } onFailure: { leadingFailed = true }
                    }
                    .frame(width: height * 2 / 3, height: height)
                    pageSlot(index: leadingIndex + 1, failed: trailingFailed) {
                        loadPage(index: leadingIndex + 1) { trailingImage = $0 } onFailure: { trailingFailed = true }
                    }
                    .frame(width: height * 2 / 3, height: height)
                }
            }
        }
        .onAppear {
            loadPage(index: leadingIndex) { leadingImage = $0 } onFailure: { leadingFailed = true }
            loadPage(index: leadingIndex + 1) { trailingImage = $0 } onFailure: { trailingFailed = true }
        }
    }

    /// Spinner finché si carica, bottone "Riprova" se la lettura è fallita — invece di uno
    /// spinner bloccato per sempre e nessuna traccia visibile del problema (comportamento
    /// originale, verificato dal vivo: bastava un fallimento di lettura, anche transitorio,
    /// per bloccare la pagina indefinitamente). Vedi `ReaderDoublePageViewController` di
    /// Aidoku, che ha lo stesso bottone per lo stesso motivo.
    @ViewBuilder
    private func pageSlot(index: Int, failed: Bool, retry: @escaping () -> Void) -> some View {
        if failed {
            Button("Riprova", action: retry)
                .buttonStyle(.bordered)
        } else {
            ProgressView().accentColor(.white)
        }
    }

    @ViewBuilder
    private var tintOverlay: some View {
        if let tint = theme.pageTint, theme.pageTintOpacity > 0 {
            tint.opacity(theme.pageTintOpacity).blendMode(.multiply)
        }
    }

    private func loadPage(index: Int, onSuccess: @escaping (PlatformImage) -> Void, onFailure: @escaping () -> Void) {
        let autoCrop = isAutoCropEnabled
        let upscale = isUpscalingEnabled
        let autoTintContrast = isAutoTintContrastEnabled
        // Larghezza target stimata 2:3 solo per l'eventuale upscaling — non influisce sul
        // layout, che deriva comunque dalle proporzioni reali una volta caricata l'immagine.
        let targetSize = CGSize(width: height * 2 / 3, height: height)

        if let imageCache {
            let options = PageImageCache.ProcessingOptions(
                autoCrop: autoCrop,
                autoTintContrast: autoTintContrast,
                upscaleTargetSize: upscale ? targetSize : nil
            )
            Task {
                if let loaded = await imageCache.image(at: index, options: options) {
                    await MainActor.run { onSuccess(loaded) }
                } else {
                    await MainActor.run { onFailure() }
                }
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var loaded: PlatformImage
            do {
                loaded = try provider.image(atPage: index)
            } catch {
                DiagnosticLog.log("Lettura pagina \(index) fallita: \((error as NSError).localizedDescription)")
                DispatchQueue.main.async { onFailure() }
                return
            }
            if autoCrop {
                loaded = ImageProcessing.autoCropWhiteBorders(loaded)
            }
            if autoTintContrast {
                loaded = ImageProcessing.autoTintAndContrast(loaded)
            }
            if upscale {
                loaded = ImageProcessing.upscaleIfNeeded(loaded, targetSize: targetSize)
            }
            let final = loaded
            DispatchQueue.main.async { onSuccess(final) }
        }
    }
}
#endif

private struct PageView: View {
    let provider: ComicPageProvider
    let index: Int
    let isDoublePage: Bool
    let isZoomed: Binding<Bool>
    var imageCache: PageImageCache?
    /// Non-nil solo per una pagina che fa davvero parte di uno spread a due, affiancata a
    /// un'altra pagina "toccante" (vedi `PageSpreadView`): in quel caso la larghezza segue le
    /// proporzioni dell'immagine invece di riempire una metà fissa del riquadro.
    var pairedHeight: CGFloat?
    /// Solo iOS: vero solo per la pagina davvero mostrata, non per le vicine tenute vive dal
    /// pager per lo swipe — vedi il commento su `PageSpreadView.isActive`. Ignorato su macOS,
    /// dove non esiste questo pre-caricamento e lo zoom resta su gesture SwiftUI ordinarie.
    var isActive: Bool = true
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    @AppStorage("singlePageZoomMode") private var singlePageZoomMode = PageZoomMode.auto
    @AppStorage("doublePageZoomMode") private var doublePageZoomMode = PageZoomMode.auto
    @AppStorage("motionBlurEnabled") private var isMotionBlurEnabled = true
    @State private var image: PlatformImage?
    @State private var loadFailed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// Sfoca leggermente l'immagine in proporzione alla velocità del trascinamento mentre si fa
    /// pan su una pagina ingrandita — non un filtro estetico permanente, sparisce a fine gesto.
    @State private var motionBlurRadius: CGFloat = 0

    /// "Automatico"/"Adatta pagina" mostrano l'intera pagina (comportamento storico, invariato).
    /// "Adatta larghezza" è l'unico caso che cambia layout: scala alla larghezza disponibile e,
    /// se il risultato eccede l'altezza dello schermo, rende la pagina scorrevole verticalmente.
    private var effectiveZoomMode: PageZoomMode {
        isDoublePage ? doublePageZoomMode : singlePageZoomMode
    }

    var body: some View {
        if let pairedHeight, effectiveZoomMode != .fitWidth {
            pairedContent(height: pairedHeight)
        } else {
            GeometryReader { proxy in
                Group {
                    if let image = image {
                        if effectiveZoomMode == .fitWidth {
                            ScrollView(.vertical, showsIndicators: false) {
                                image.asSwiftUIImage
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: proxy.size.width)
                                    .overlay(tintOverlay)
                            }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        } else {
                            #if os(iOS)
                            // `MagnificationGesture`/`DragGesture` SwiftUI, sovrapposti al pager a
                            // scorrimento (`TabView(.page)`, backed da `UIPageViewController`), perdono
                            // l'arbitraggio dei tocchi a due dita col suo scroll view interno — pinch e
                            // pan restano morti (verificato dal vivo su device). Un vero `UIScrollView`
                            // con zoom nativo (come fa l'app Foto: pinch/pan sono il comportamento di
                            // sistema di uno scroll view zoomabile, non gesture aggiunte sopra) partecipa
                            // allo stesso protocollo di coordinamento gesture di UIKit invece di dover
                            // reinventarlo a mano.
                            ZoomableImageView(image: image, isZoomed: isZoomed, isActive: isActive)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .overlay(tintOverlay)
                            #else
                            image.asSwiftUIImage
                                .resizable()
                                .scaledToFit()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .scaleEffect(scale)
                                .offset(offset)
                                .blur(radius: motionBlurRadius)
                                .overlay(tintOverlay)
                                .gesture(magnifyGesture)
                                // Attivo solo da zoomata: a scale 1 non deve intercettare il drag,
                                // altrimenti ruba il tocco allo swipe-pagina sottostante anche se poi
                                // non fa nulla (guard scale > 1).
                                .gesture(dragGesture, including: scale > 1 ? .all : .subviews)
                                .onTapGesture(count: 2) { toggleZoom() }
                            #endif
                        }
                    } else {
                        pageSlot(targetSize: proxy.size) { loadImage(targetSize: proxy.size) }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .onAppear { loadImage(targetSize: proxy.size) }
            }
            .clipped()
        }
    }

    /// Percorso per una pagina che tocca l'altra metà dello spread: altezza fissa, larghezza
    /// derivata dalle proporzioni dell'immagine (nessun `GeometryReader` a imporre una metà
    /// fissa, che è la causa dello spazio nero tra le pagine). Non copre "Adatta larghezza",
    /// che resta sullo scroll verticale per-pagina: le due nozioni non si combinano bene
    /// (l'una deriva l'altezza dalla larghezza, l'altra il contrario).
    @ViewBuilder
    private func pairedContent(height: CGFloat) -> some View {
        // Stima 2:3 finché non si conoscono le proporzioni reali: evita che il placeholder
        // salti di dimensione quando l'immagine arriva.
        let estimatedWidth = height * 2 / 3
        Group {
            if let image = image {
                #if os(iOS)
                // `sizeThatFits` su ZoomableImageView calcola la larghezza dall'altezza
                // proposta, come farebbe `Image().scaledToFit()` — vedi il commento lì.
                //
                // NOTA: su iOS questo ramo oggi non viene mai raggiunto — `PageSpreadView`
                // passa sempre `pairedHeight: nil` e affida lo spread a `SpreadPairView`.
                // Resta qui solo perché `PageView` è condivisa tra le due piattaforme.
                // Il vecchio problema dello spinner bloccato su una delle due pagine
                // riguardava proprio questo percorso e resta quindi aperto solo su macOS,
                // dove `pairedContent` è ancora in uso (vedi il ramo `#else`).
                ZoomableImageView(image: image, isZoomed: isZoomed, isActive: isActive, widthFollowsHeight: true)
                    .frame(height: height)
                    .overlay(tintOverlay)
                #else
                image.asSwiftUIImage
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .blur(radius: motionBlurRadius)
                    .overlay(tintOverlay)
                    .gesture(magnifyGesture)
                    .gesture(dragGesture, including: scale > 1 ? .all : .subviews)
                    .onTapGesture(count: 2) { toggleZoom() }
                #endif
            } else {
                pageSlot(targetSize: CGSize(width: estimatedWidth, height: height)) {
                    loadImage(targetSize: CGSize(width: estimatedWidth, height: height))
                }
                .frame(width: estimatedWidth, height: height)
            }
        }
        .onAppear { loadImage(targetSize: CGSize(width: estimatedWidth, height: height)) }
    }

    /// Spinner finché si carica, bottone "Riprova" se la lettura è fallita — invece di uno
    /// spinner bloccato per sempre senza traccia del problema (comportamento originale,
    /// verificato dal vivo). Stessa idea di `SpreadPairView.pageSlot`, qui per il percorso a
    /// pagina singola.
    @ViewBuilder
    private func pageSlot(targetSize: CGSize, retry: @escaping () -> Void) -> some View {
        if loadFailed {
            Button("Riprova") {
                loadFailed = false
                if let imageCache {
                    Task {
                        await imageCache.invalidate(index)
                        retry()
                    }
                } else {
                    retry()
                }
            }
            .buttonStyle(.bordered)
        } else {
            ProgressView().accentColor(.white)
        }
    }

    @ViewBuilder
    private var tintOverlay: some View {
        if let tint = theme.pageTint, theme.pageTintOpacity > 0 {
            tint.opacity(theme.pageTintOpacity).blendMode(.multiply)
        }
    }

    private func loadImage(targetSize: CGSize) {
        guard image == nil else { return }
        let autoCrop = isAutoCropEnabled
        let upscale = isUpscalingEnabled
        let autoTintContrast = isAutoTintContrastEnabled

        if let imageCache {
            // Percorso macOS: la cache è quasi sempre già calda grazie al prefetch avviato da
            // `ReaderContentView` quando `currentPage` cambia — questa chiamata torna quasi
            // subito invece di ridecodificare da disco.
            let options = PageImageCache.ProcessingOptions(
                autoCrop: autoCrop,
                autoTintContrast: autoTintContrast,
                upscaleTargetSize: upscale ? targetSize : nil
            )
            Task {
                let loaded = await imageCache.image(at: index, options: options)
                await MainActor.run {
                    if let loaded {
                        self.image = loaded
                    } else {
                        self.loadFailed = true
                    }
                }
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var loaded: PlatformImage
            do {
                loaded = try provider.image(atPage: index)
            } catch {
                // Non un semplice `try?`: un fallimento qui lasciava la pagina bloccata sullo
                // spinner per sempre, senza traccia — verificato dal vivo con la doppia pagina
                // (due letture concorrenti sullo stesso archivio CBZ/CBR, non thread-safe,
                // producevano dati corrotti; risolto a monte in CBZ/CBRPageProvider, ma un log
                // resta comunque utile per qualunque altro fallimento di lettura). Con un
                // bottone "Riprova" invece di restare bloccati per sempre — vedi `pageSlot`.
                DiagnosticLog.log("Lettura pagina \(index) fallita: \((error as NSError).localizedDescription)")
                DispatchQueue.main.async { self.loadFailed = true }
                return
            }
            if autoCrop {
                loaded = ImageProcessing.autoCropWhiteBorders(loaded)
            }
            if autoTintContrast {
                loaded = ImageProcessing.autoTintAndContrast(loaded)
            }
            if upscale {
                loaded = ImageProcessing.upscaleIfNeeded(loaded, targetSize: targetSize)
            }
            DispatchQueue.main.async { self.image = loaded }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1), 5)
                syncZoomedState()
            }
            .onEnded { _ in
                lastScale = scale
                if scale == 1 { offset = .zero; lastOffset = .zero }
                syncZoomedState()
            }
    }

    private func syncZoomedState() {
        isZoomed.wrappedValue = scale > 1.01
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                let newOffset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                if isMotionBlurEnabled {
                    let dx = newOffset.width - offset.width
                    let dy = newOffset.height - offset.height
                    let speed = (dx * dx + dy * dy).squareRoot()
                    motionBlurRadius = min(speed * 0.3, 6)
                }
                offset = newOffset
            }
            .onEnded { _ in
                lastOffset = offset
                withAnimation(.easeOut(duration: 0.15)) { motionBlurRadius = 0 }
            }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if scale > 1 {
                scale = 1
                lastScale = 1
                offset = .zero
                lastOffset = .zero
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
        syncZoomedState()
    }
}
