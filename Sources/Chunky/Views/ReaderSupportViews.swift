import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(iOS)
/// Zone di tap per cambiare pagina: due terzi laterali (avanti/indietro) e una fascia centrale
/// per mostrare/nascondere i controlli, oppure — in modalità "una mano" — l'intero lato
/// sinistro/destro (senza fascia centrale, per restare comodi col pollice a schermo intero).
///
/// Non tre `Color.clear` sovrapposte al contenuto con `.contentShape` + `simultaneousGesture`
/// (versione precedente): per l'hit-testing di UIKit, chi sta sopra in un ZStack vince sempre il
/// tocco iniziale, a prescindere da `simultaneousGesture` — che arbitra fra gesture SwiftUI sulla
/// stessa view, non fa passare i tocchi a un `UIViewRepresentable` fratello sottostante (il pager,
/// lo scroll view dello zoom). Verificato dal vivo con log su `touchesBegan`: zero tocchi
/// arrivavano al contenuto vero, nemmeno un tap semplice.
///
/// Qui invece — come fa `ReaderViewController.handleTap` in Aidoku
/// (github.com/Aidoku/Aidoku/blob/main/iOS/UI/Reader/ReaderViewController.swift) — un solo
/// `UITapGestureRecognizer`, e la zona toccata (sinistra/centro/destra/angoli) si calcola dalle
/// coordinate del tocco invece di avere una view per zona. Agganciato alla `window` anziché a
/// questa view (`hitTest` sempre `nil`, mai in cima all'hit-test): la `window` è antenata di
/// qualunque vista colpita dall'hit-test, quindi riceve comunque il tocco — stessa tecnica già
/// usata per la luminosità a due dita e per pinch/pan/doppio-tap in `ZoomableImageView`.
///
/// Le etichette di accessibilità restano SwiftUI (`allowsHitTesting(false)`, così non
/// interferiscono con l'hit-test): VoiceOver naviga l'albero delle view indipendentemente
/// dall'hit-test dei tocchi normali.
struct PageTapZones: View {
    let oneHanded: Bool
    /// In modalità "una mano", scambia quale lato (sinistro/destro) avanza e quale
    /// retrocede: comodo per adattarsi a mano destra/sinistra o a come si tiene il telefono.
    let oneHandedReversed: Bool
    let hotCorners: Bool
    /// Senza zone (tap page-turn disattivato): qualunque tocco mostra/nasconde i controlli,
    /// come nell'app originale.
    let zonesEnabled: Bool
    /// Nei manga il lato sinistro è quello che *avanza*: serve solo alle etichette di
    /// accessibilità, perché l'inversione vera del verso avviene già in `step`.
    let rightToLeft: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleControls: () -> Void
    /// Angoli attivi con "Hot corners": in alto a sinistra esce dalla lettura, in alto a
    /// destra apre le impostazioni, in basso a destra alterna la doppia pagina.
    let onExit: () -> Void
    let onOpenSettings: () -> Void
    let onToggleDoublePage: () -> Void

    var body: some View {
        TapZoneRelay(
            oneHanded: oneHanded,
            oneHandedReversed: oneHandedReversed,
            rightToLeft: rightToLeft,
            hotCorners: hotCorners,
            zonesEnabled: zonesEnabled,
            onPrevious: onPrevious,
            onNext: onNext,
            onToggleControls: onToggleControls,
            onExit: onExit,
            onOpenSettings: onOpenSettings,
            onToggleDoublePage: onToggleDoublePage
        )
        .overlay(accessibilityOverlay)
    }

    /// Solo etichette/azioni per VoiceOver, invisibili ai tocchi normali: le vere zone (con le
    /// stesse dimensioni, vedi `PageTapZoneGeometry`) le calcola `TapZoneRelay`.
    @ViewBuilder
    private var accessibilityOverlay: some View {
        if zonesEnabled {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    if hotCorners {
                        accessibilityZone(label: "Esci dalla lettura", action: onExit)
                            .frame(width: PageTapZoneGeometry.cornerSize, height: PageTapZoneGeometry.cornerSize)
                        accessibilityZone(label: "Impostazioni", action: onOpenSettings)
                            .frame(width: PageTapZoneGeometry.cornerSize, height: PageTapZoneGeometry.cornerSize)
                            .position(x: proxy.size.width - PageTapZoneGeometry.cornerSize / 2, y: PageTapZoneGeometry.cornerSize / 2)
                        accessibilityZone(label: "Doppia pagina", action: onToggleDoublePage)
                            .frame(width: PageTapZoneGeometry.cornerSize, height: PageTapZoneGeometry.cornerSize)
                            .position(
                                x: proxy.size.width - PageTapZoneGeometry.cornerSize / 2,
                                y: proxy.size.height - PageTapZoneGeometry.cornerSize / 2
                            )
                    }
                    // Le larghezze qui devono rispecchiare quelle usate da `TapZoneRelay` per il
                    // vero hit-testing (vedi `PageTapZoneGeometry.action`): in one-handed i due
                    // lati fanno la stessa azione (nessuna asimmetria); altrimenti la zona larga
                    // segue quale lato è "avanti" nell'ordine di lettura — a destra normalmente,
                    // a sinistra con lettura RTL.
                    let leftWidth = oneHanded
                        ? PageTapZoneGeometry.oneHandedSideWidth(for: proxy.size.width)
                        : (rightToLeft ? PageTapZoneGeometry.forwardSideWidth(for: proxy.size.width) : PageTapZoneGeometry.backSideWidth(for: proxy.size.width))
                    let rightWidth = oneHanded
                        ? PageTapZoneGeometry.oneHandedSideWidth(for: proxy.size.width)
                        : (rightToLeft ? PageTapZoneGeometry.backSideWidth(for: proxy.size.width) : PageTapZoneGeometry.forwardSideWidth(for: proxy.size.width))
                    let verticalInset: CGFloat = hotCorners ? PageTapZoneGeometry.cornerSize : 0
                    let bandHeight = proxy.size.height - verticalInset * 2
                    accessibilityZone(label: previousOrSharedLabel, action: oneHanded ? sharedAction : onPrevious)
                        .frame(width: leftWidth, height: bandHeight)
                        .position(x: leftWidth / 2, y: verticalInset + bandHeight / 2)
                    accessibilityZone(label: nextOrSharedLabel, action: oneHanded ? sharedAction : onNext)
                        .frame(width: rightWidth, height: bandHeight)
                        .position(x: proxy.size.width - rightWidth / 2, y: verticalInset + bandHeight / 2)
                    accessibilityZone(label: "Mostra o nascondi i controlli", action: onToggleControls)
                        .frame(width: max(proxy.size.width - leftWidth - rightWidth, 0), height: bandHeight)
                        .position(x: leftWidth + max(proxy.size.width - leftWidth - rightWidth, 0) / 2, y: verticalInset + bandHeight / 2)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var sharedAction: () -> Void { oneHandedReversed ? onPrevious : onNext }
    /// `onPrevious`/`onNext` sono la zona sinistra e quella destra: nei manga la sinistra è
    /// quella che manda avanti, quindi le etichette vanno scambiate.
    private var previousLabel: String { rightToLeft ? "Pagina successiva" : "Pagina precedente" }
    private var nextLabel: String { rightToLeft ? "Pagina precedente" : "Pagina successiva" }
    private var sharedLabel: String { oneHandedReversed ? previousLabel : nextLabel }
    private var previousOrSharedLabel: String { oneHanded ? sharedLabel : previousLabel }
    private var nextOrSharedLabel: String { oneHanded ? sharedLabel : nextLabel }

    private func accessibilityZone(label: String, action: @escaping () -> Void) -> some View {
        Color.clear
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityAction(.default, action)
    }
}

/// Geometria delle zone, condivisa fra `TapZoneRelay` (che decide l'azione da un tocco reale) e
/// l'overlay di accessibilità di `PageTapZones` (che deve posizionare gli stessi rettangoli):
/// un'unica fonte di verità, altrimenti VoiceOver e il tocco reale rischiano di disallinearsi.
private enum PageTapZoneGeometry {
    static let cornerSize: CGFloat = 88

    /// Zona "indietro": più stretta, come nei reader Kindle-style — si torna indietro molto
    /// meno spesso di quanto si avanzi, quindi una zona larga qui aumenta solo i tocchi
    /// accidentali che tornano alla pagina precedente invece di aprire i controlli.
    static func backSideWidth(for totalWidth: CGFloat) -> CGFloat {
        min(totalWidth * 0.11, 55)
    }

    /// Zona "avanti": più larga della zona indietro, per lo stesso motivo al contrario. Lo
    /// stesso tetto (90pt) di prima dell'asimmetria, non più largo: verificato dal vivo che un
    /// tetto più alto (120pt) arriva a coprire il bottone "···" della toolbar in alto, che senza
    /// `hotCorners` attivo non ha un'esclusione verticale — un tocco lì avanzava anche la pagina.
    static func forwardSideWidth(for totalWidth: CGFloat) -> CGFloat {
        min(totalWidth * 0.18, 90)
    }

    /// Modalità "una mano": entrambi i lati fanno la stessa azione (vedi `sharedAction` in
    /// `PageTapZones`), quindi l'asimmetria avanti/indietro non ha senso qui — un lato non è
    /// "più avanti" dell'altro, sono la stessa identica azione duplicata per comodità del
    /// pollice. Larghezza fissa, come prima dell'introduzione delle zone asimmetriche.
    static func oneHandedSideWidth(for totalWidth: CGFloat) -> CGFloat {
        min(totalWidth * 0.18, 90)
    }

    enum Action {
        case previous, next, toggleControls, exit, openSettings, toggleDoublePage
    }

    static func action(
        at point: CGPoint,
        in size: CGSize,
        oneHanded: Bool,
        oneHandedReversed: Bool,
        rightToLeft: Bool,
        hotCorners: Bool,
        zonesEnabled: Bool
    ) -> Action? {
        guard size.width > 0, size.height > 0 else { return nil }
        guard zonesEnabled else { return .toggleControls }

        if hotCorners {
            if point.x <= cornerSize, point.y <= cornerSize { return .exit }
            if point.x >= size.width - cornerSize, point.y <= cornerSize { return .openSettings }
            if point.x >= size.width - cornerSize, point.y >= size.height - cornerSize { return .toggleDoublePage }
        }

        let verticalInset: CGFloat = hotCorners ? cornerSize : 0
        guard point.y >= verticalInset, point.y <= size.height - verticalInset else { return nil }

        if oneHanded {
            // I due lati chiamano la stessa closure (vedi `sharedAction`): non c'è un lato
            // "avanti" e uno "indietro" da rendere asimmetrici, sono la stessa azione.
            let sideWidth = oneHandedSideWidth(for: size.width)
            let sharedAction: Action = oneHandedReversed ? .previous : .next
            if point.x <= sideWidth { return sharedAction }
            if point.x >= size.width - sideWidth { return sharedAction }
            return .toggleControls
        }

        // `onPrevious`/`onNext` sono legate a sinistra/destra a prescindere da `rightToLeft`
        // (chi le implementa, `ReaderPagination.step`, inverte già la direzione per i manga) —
        // qui cambia solo QUALE lato è "avanti" nell'ordine di lettura, e quindi quale prende
        // la zona larga: a destra normalmente, a sinistra quando la lettura è RTL.
        let leftWidth = rightToLeft ? forwardSideWidth(for: size.width) : backSideWidth(for: size.width)
        let rightWidth = rightToLeft ? backSideWidth(for: size.width) : forwardSideWidth(for: size.width)

        if point.x <= leftWidth {
            return .previous
        }
        if point.x >= size.width - rightWidth {
            return .next
        }
        return .toggleControls
    }
}

private struct TapZoneRelay: UIViewRepresentable {
    let oneHanded: Bool
    let oneHandedReversed: Bool
    let rightToLeft: Bool
    let hotCorners: Bool
    let zonesEnabled: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleControls: () -> Void
    let onExit: () -> Void
    let onOpenSettings: () -> Void
    let onToggleDoublePage: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RelayView {
        let view = RelayView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: RelayView, context: Context) {
        context.coordinator.oneHanded = oneHanded
        context.coordinator.oneHandedReversed = oneHandedReversed
        context.coordinator.rightToLeft = rightToLeft
        context.coordinator.hotCorners = hotCorners
        context.coordinator.zonesEnabled = zonesEnabled
        context.coordinator.onPrevious = onPrevious
        context.coordinator.onNext = onNext
        context.coordinator.onToggleControls = onToggleControls
        context.coordinator.onExit = onExit
        context.coordinator.onOpenSettings = onOpenSettings
        context.coordinator.onToggleDoublePage = onToggleDoublePage
    }

    /// Non intercetta mai l'hit-testing (vedi il commento su `PageTapZones` sopra): il suo
    /// recognizer, agganciato alla window in `didMoveToWindow`, riceve comunque ogni tocco
    /// perché la window è antenata di qualunque vista colpita dall'hit-test.
    final class RelayView: UIView {
        weak var coordinator: Coordinator?
        private weak var recognizer: UITapGestureRecognizer?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
            }
            guard let window, let coordinator else { return }
            coordinator.relayView = self
            let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
            tap.delegate = coordinator
            tap.cancelsTouchesInView = false
            window.addGestureRecognizer(tap)
            recognizer = tap
        }

        deinit {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var relayView: UIView?
        var oneHanded = false
        var oneHandedReversed = false
        var rightToLeft = false
        var hotCorners = false
        var zonesEnabled = true
        var onPrevious: () -> Void = {}
        var onNext: () -> Void = {}
        var onToggleControls: () -> Void = {}
        var onExit: () -> Void = {}
        var onOpenSettings: () -> Void = {}
        var onToggleDoublePage: () -> Void = {}

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let relayView, relayView.window != nil else { return }
            let point = recognizer.location(in: relayView)
            guard relayView.bounds.contains(point) else { return }
            let action = PageTapZoneGeometry.action(
                at: point,
                in: relayView.bounds.size,
                oneHanded: oneHanded,
                oneHandedReversed: oneHandedReversed,
                rightToLeft: rightToLeft,
                hotCorners: hotCorners,
                zonesEnabled: zonesEnabled
            )
            switch action {
            case .previous: onPrevious()
            case .next: onNext()
            case .toggleControls: onToggleControls()
            case .exit: onExit()
            case .openSettings: onOpenSettings()
            case .toggleDoublePage: onToggleDoublePage()
            case nil: break
            }
        }
    }
}
#else
/// Zone di tap/click per cambiare pagina: due terzi laterali (avanti/indietro) e una fascia
/// centrale per mostrare/nascondere i controlli, oppure — in modalità "una mano" — l'intero
/// lato sinistro/destro.
///
/// Qui restano tre `Color.clear` con `.contentShape` + `simultaneousGesture`: il problema di
/// hit-testing per cui la versione iOS è stata riscritta (vedi sopra) nasce dalla competizione
/// con `TabView(.page)`/`UIPageViewController` e con lo `UIScrollView` di zoom di
/// `ZoomableImageView` — nessuno dei due esiste su macOS, dove il pager non è a scorrimento
/// touch e lo zoom di `PageView` resta sul `MagnificationGesture` SwiftUI nella stessa
/// gerarchia. Non c'è quindi lo stesso motivo per abbandonare l'approccio semplice.
struct PageTapZones: View {
    let oneHanded: Bool
    /// In modalità "una mano", scambia quale lato (sinistro/destro) avanza e quale
    /// retrocede: comodo per adattarsi a mano destra/sinistra o a come si tiene il telefono.
    let oneHandedReversed: Bool
    let hotCorners: Bool
    /// Nei manga il lato sinistro è quello che *avanza*: serve solo alle etichette di
    /// accessibilità, perché l'inversione vera del verso avviene già in `step`.
    let rightToLeft: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleControls: () -> Void
    /// Angoli attivi con "Hot corners": in alto a sinistra esce dalla lettura, in alto a
    /// destra apre le impostazioni, in basso a destra alterna la doppia pagina.
    let onExit: () -> Void
    let onOpenSettings: () -> Void
    let onToggleDoublePage: () -> Void

    var body: some View {
        GeometryReader { proxy in
            if hotCorners {
                // Righe non sovrapposte (anziché uno ZStack): due zone di tap che si sovrappongono
                // userebbero entrambe simultaneousGesture e scatterebbero insieme sullo stesso tocco.
                VStack(spacing: 0) {
                    HStack {
                        zone(label: "Esci dalla lettura", action: onExit)
                            .frame(width: 88, height: 88)
                        Spacer()
                        zone(label: "Impostazioni", action: onOpenSettings)
                            .frame(width: 88, height: 88)
                    }
                    mainZones(proxy: proxy)
                    HStack {
                        Spacer()
                        zone(label: "Doppia pagina", action: onToggleDoublePage)
                            .frame(width: 88, height: 88)
                    }
                }
            } else {
                mainZones(proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private func mainZones(proxy: GeometryProxy) -> some View {
        if oneHanded {
            // Sinistra e destra fanno la stessa azione (il pollice non deve mirare al bordo
            // esatto): quale, lo sceglie oneHandedReversed. Fascia centrale per i controlli,
            // come in modalità normale.
            let sharedAction = oneHandedReversed ? onPrevious : onNext
            let sharedLabel = oneHandedReversed ? previousLabel : nextLabel
            HStack(spacing: 0) {
                zone(label: sharedLabel, action: sharedAction)
                    .frame(width: min(proxy.size.width * 0.18, 90))
                zone(label: "Mostra o nascondi i controlli", action: onToggleControls)
                zone(label: sharedLabel, action: sharedAction)
                    .frame(width: min(proxy.size.width * 0.18, 90))
            }
        } else {
            HStack(spacing: 0) {
                zone(label: previousLabel, action: onPrevious)
                    .frame(width: min(proxy.size.width * 0.18, 90))
                zone(label: "Mostra o nascondi i controlli", action: onToggleControls)
                zone(label: nextLabel, action: onNext)
                    .frame(width: min(proxy.size.width * 0.18, 90))
            }
        }
    }

    /// `onPrevious`/`onNext` sono la zona sinistra e quella destra: nei manga la sinistra è
    /// quella che manda avanti, quindi le etichette vanno scambiate.
    private var previousLabel: String { rightToLeft ? "Pagina successiva" : "Pagina precedente" }
    private var nextLabel: String { rightToLeft ? "Pagina precedente" : "Pagina successiva" }

    /// Etichetta e trait espliciti: la zona è una `Color.clear`, quindi senza questi VoiceOver
    /// non avrebbe alcun modo di girare pagina (e i test automatici nessun bersaglio).
    private func zone(label: String, action: @escaping () -> Void) -> some View {
        // simultaneousGesture, non .onTapGesture: quest'ultimo reclama il tocco in esclusiva,
        // impedendo allo swipe sottostante di funzionare del tutto.
        Color.clear
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(action))
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
    }
}
#endif

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
                // NOTA: in doppia pagina una delle due `PageView` a volte resta bloccata sullo
                // spinner di caricamento e non mostra mai l'immagine — verificato dal vivo che
                // il bug esiste identico anche con il vecchio path SwiftUI qui sotto (`#else`),
                // quindi non è legato a `ZoomableImageView`: è un problema preesistente nel
                // caricamento/identità delle viste di `pairedContent` in doppia pagina, non
                // ancora diagnosticato.
                ZoomableImageView(image: image, isZoomed: isZoomed, isActive: isActive)
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

#if os(iOS)
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

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    let isZoomed: Binding<Bool>
    var isActive: Bool = true

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

    /// Permette a `ZoomableImageView` di dimensionarsi come farebbe `Image().scaledToFit()`
    /// quando riceve solo un'altezza (modalità doppia pagina, dove la larghezza deriva dalle
    /// proporzioni dell'immagine): senza questo, un `UIViewRepresentable` non sa calcolare da
    /// sé una larghezza da un'altezza proposta, e finirebbe o senza dimensioni o largo quanto
    /// lo spazio disponibile invece che quanto l'immagine.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIScrollView, context: Context) -> CGSize? {
        guard let image, image.size.height > 0 else { return nil }
        let aspect = image.size.width / image.size.height
        // Priorità all'altezza quando c'è: chi ci chiama con un'altezza esplicita (vedi
        // `pairedContent`) lo fa apposta perché la larghezza deve derivare da quella, non da
        // qualunque larghezza l'HStack proponga di suo (che può non essere nil anche quando
        // la vera intenzione è "dimensionati tu dall'altezza").
        if let height = proposal.height {
            return CGSize(width: height * aspect, height: height)
        }
        if let width = proposal.width {
            return CGSize(width: width, height: width / aspect)
        }
        return nil
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
            if let imageView { center(imageView, in: scrollView) }
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
private struct SpreadZoomableImageView: UIViewRepresentable {
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
        context.coordinator.images = images
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
            if let container { center(container, in: scrollView) }
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

/// Cambia quando cambia qualcosa che obbliga a ricostruire tutte le pagine da zero (il numero
/// di pagine per spread, il verso di lettura, il fumetto stesso): i controller in cache
/// mostrerebbero altrimenti spread composti con le regole vecchie.
struct PagerResetToken: Hashable {
    let doublePage: Bool
    let rightToLeft: Bool
    let pageCount: Int
}

/// Pager del lettore. Espone `UIPageViewController` perché è l'unico componente che offre sia
/// lo scorrimento interattivo che segue il dito sia un cambio pagina programmatico di cui si
/// possa scegliere l'animazione — le due cose che servono per rendere davvero indipendenti le
/// impostazioni "Tap page-turn" e "Swipe page-turn".
struct PageTurnPager<Content: View>: UIViewControllerRepresentable {
    /// Indici di inizio spread, in ordine crescente: sono i "passi" della navigazione.
    let starts: [Int]
    @Binding var selection: Int
    let rightToLeft: Bool
    /// Stile dell'ultimo cambio pagina programmatico (tap, tastiera, salto, scrubber).
    let turnStyle: TapPageTurnStyle
    /// Con false lo scorrimento a dito è spento: o perché lo stile dello swipe non è
    /// "Scorrimento", o perché la pagina è ingrandita e il trascinamento serve al pan.
    let interactiveSwipe: Bool
    let resetToken: PagerResetToken
    let content: (Int) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pager.view.backgroundColor = .clear
        pager.delegate = context.coordinator
        pager.dataSource = interactiveSwipe ? context.coordinator : nil
        pager.setViewControllers([context.coordinator.controller(for: selection)], direction: .forward, animated: false)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Togliere il dataSource è il modo pulito di disattivare il paging a gesto lasciando
        // funzionante il cambio pagina programmatico.
        pager.dataSource = interactiveSwipe ? coordinator : nil

        if coordinator.resetToken != resetToken {
            coordinator.resetToken = resetToken
            coordinator.discardCachedControllers()
            coordinator.currentIndex = selection
            pager.setViewControllers([coordinator.controller(for: selection)], direction: .forward, animated: false)
            return
        }

        // Il confronto è con l'indice tenuto dal coordinator, mai con un valore catturato:
        // questo metodo viene richiamato a ogni cambio di stato del padre (lo zoom, per dirne
        // uno, cambia a ogni pizzicata) e un confronto sbagliato girerebbe la pagina da solo.
        guard selection != coordinator.currentIndex else { return }
        let indexIncreasing = selection > coordinator.currentIndex
        coordinator.currentIndex = selection
        let next = coordinator.controller(for: selection)
        let direction = Self.navigationDirection(indexIncreasing: indexIncreasing, rightToLeft: rightToLeft)
        switch turnStyle {
        case .slide:
            pager.setViewControllers([next], direction: direction, animated: true)
        case .fade:
            UIView.transition(with: pager.view, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                pager.setViewControllers([next], direction: direction, animated: false)
            }
        case .immediate, .disabled:
            pager.setViewControllers([next], direction: direction, animated: false)
        }
    }

    /// `.forward` fa entrare la pagina nuova da destra. La pagina con indice più alto sta a
    /// destra in LTR e a sinistra nei manga, quindi nei manga i due versi vanno scambiati.
    /// Stessa regola per il vicino da restituire al dataSource, così i due non possono divergere.
    static func navigationDirection(indexIncreasing: Bool, rightToLeft: Bool) -> UIPageViewController.NavigationDirection {
        (indexIncreasing != rightToLeft) ? .forward : .reverse
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageTurnPager
        var currentIndex: Int
        var resetToken: PagerResetToken
        private var controllers: [Int: UIHostingController<Content>] = [:]

        init(_ parent: PageTurnPager) {
            self.parent = parent
            self.currentIndex = parent.selection
            self.resetToken = parent.resetToken
        }

        func discardCachedControllers() {
            controllers.removeAll()
        }

        func controller(for index: Int) -> UIHostingController<Content> {
            if let existing = controllers[index] { return existing }
            let hosting = UIHostingController(rootView: parent.content(index))
            hosting.view.backgroundColor = .clear
            controllers[index] = hosting
            pruneCache(around: index)
            return hosting
        }

        /// Teniamo in cache solo gli spread vicini: su un fumetto lungo, conservarli tutti
        /// significherebbe tenere in memoria ogni immagine già decodificata. Quello uscente
        /// resta comunque vivo finché serve, perché il pager lo trattiene come figlio.
        private func pruneCache(around index: Int) {
            guard let position = parent.starts.firstIndex(of: index) else { return }
            let keep = Set((position - 2...position + 2)
                .filter { parent.starts.indices.contains($0) }
                .map { parent.starts[$0] })
            controllers = controllers.filter { keep.contains($0.key) }
        }

        private func index(of viewController: UIViewController) -> Int? {
            controllers.first(where: { $0.value === viewController })?.key
        }

        private func neighbour(of viewController: UIViewController, offset: Int) -> UIViewController? {
            guard let index = index(of: viewController),
                  let position = parent.starts.firstIndex(of: index) else { return nil }
            let target = position + offset
            guard parent.starts.indices.contains(target) else { return nil }
            return controller(for: parent.starts[target])
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            // "Prima" è ciò che sta a sinistra: nei manga è la pagina con indice più alto.
            neighbour(of: viewController, offset: parent.rightToLeft ? 1 : -1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            neighbour(of: viewController, offset: parent.rightToLeft ? -1 : 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let visible = pageViewController.viewControllers?.first,
                  let index = index(of: visible) else { return }
            // Prima il coordinator, poi il binding: l'aggiornamento che ne segue non vede
            // differenze e non rianima un cambio pagina che il dito ha già fatto.
            currentIndex = index
            parent.selection = index
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Intercetta un pan a due dita per regolare la luminosità dello schermo, senza rubare tocchi
/// alle viste sottostanti (swipe pagina, tap zone, pinch-to-zoom).
struct TwoFingerBrightnessView: UIViewRepresentable {
    /// Delta verticale normalizzato (-1...1) da sommare alla luminosità corrente.
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> WindowPanRelayView {
        let view = WindowPanRelayView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: WindowPanRelayView, context: Context) {
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (CGFloat) -> Void
        init(onChange: @escaping (CGFloat) -> Void) { self.onChange = onChange }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view, view.bounds.height > 0 else { return }
            let translation = recognizer.translation(in: view)
            onChange(-translation.y / view.bounds.height)
            recognizer.setTranslation(.zero, in: view)
        }

        /// Lascia passare anche i gesture di SwiftUI sotto (tap zone, swipe pagina, pinch):
        /// questo riconoscitore deve coesistere con quelli, non sostituirli.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
}

/// Non intercetta mai l'hit-testing: un `hitTest` che a volte restituisce sé stesso e a volte
/// nil in base al numero di dita già premute non funziona, perché un tocco
/// viene assegnato in modo definitivo alla vista risultante dall'hit-test al suo `touchesBegan`
/// — se il primo dito è già stato instradato al pager sottostante, "rubare" il secondo dito qui
/// lo isola dal primo e nessun recognizer arriva mai a vedere entrambi i tocchi insieme (né
/// questo pan, né il pinch-to-zoom della pagina sotto).
///
/// Il pan a due dita viene quindi agganciato alla finestra invece che a questa vista: la
/// finestra è antenata di qualunque vista venga colpita dall'hit-test (pager, tap zone,
/// immagine), quindi il suo recognizer riceve comunque entrambi i tocchi.
final class WindowPanRelayView: UIView {
    weak var coordinator: TwoFingerBrightnessView.Coordinator?
    private weak var recognizer: UIPanGestureRecognizer?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let recognizer = recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
            self.recognizer = nil
        }
        guard let window = window, let coordinator = coordinator else { return }
        let recognizer = UIPanGestureRecognizer(
            target: coordinator,
            action: #selector(TwoFingerBrightnessView.Coordinator.handlePan(_:))
        )
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 2
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = coordinator
        window.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
    }

    deinit {
        if let recognizer = recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
    }
}

#endif

#if os(macOS)
/// Su Mac non esiste lo swipe a dito: l'equivalente è lo scorrimento orizzontale a due dita sul
/// trackpad (o la rotella orizzontale del mouse), che SwiftUI non espone — DragGesture su Mac
/// segue il trascinamento col tasto premuto, non le due dita. Lo leggiamo quindi dagli eventi
/// scrollWheel, con una soglia e un solo scatto per gesto per non saltare più pagine insieme.
struct ScrollSwipeMonitor: NSViewRepresentable {
    /// +1 = pagina successiva, -1 = precedente (nel senso di lettura, come lo swipe su iOS).
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitoringView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitoringView)?.onSwipe = onSwipe
    }

    final class MonitoringView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var didFireForCurrentGesture = false

        // Chiamato anche quando la vista *esce* da una finestra: senza le due guardie si
        // accumulerebbe un monitor a ogni riapertura del lettore, e un solo swipe girerebbe
        // altrettante pagine.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                removeMonitor()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            // Il monitor è di app, non di vista: senza questo filtro reagiremmo anche agli
            // scorrimenti sopra le impostazioni o un'altra finestra.
            guard let window = window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            // L'inerzia dopo il rilascio delle dita è la coda dello stesso gesto: contarla
            // farebbe girare una seconda pagina da sola.
            guard event.momentumPhase == [] else { return }

            // Una rotella del mouse tradizionale (non un trackpad) non manda mai `.began`/
            // `.ended`: `event.phase` resta sempre vuoto, quindi il reset legato alle fasi
            // sotto non scatta mai per lei. Va gestita a parte, PRIMA del filtro di dominanza
            // orizzontale sotto — che comunque la include, essendo solo un ulteriore controllo.
            if event.phase.isEmpty {
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
                accumulated += event.scrollingDeltaX
                guard abs(accumulated) > 40 else { return }
                let direction = accumulated < 0 ? 1 : -1
                accumulated = 0
                onSwipe?(direction)
                return
            }

            // Il reset ai bordi del gesto resta incondizionato rispetto alla dominanza
            // orizzontale: un frame di inizio/fine gesto verticale deve comunque azzerare lo
            // stato, altrimenti un gesto successivo può risultare già "consumato" e non girare
            // pagina.
            if event.phase.contains(.began) {
                accumulated = 0
                didFireForCurrentGesture = false
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                accumulated = 0
                didFireForCurrentGesture = false
                return
            }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
            accumulated += event.scrollingDeltaX
            guard !didFireForCurrentGesture, abs(accumulated) > 40 else { return }
            didFireForCurrentGesture = true
            onSwipe?(accumulated < 0 ? 1 : -1)
        }

        private func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

#endif
