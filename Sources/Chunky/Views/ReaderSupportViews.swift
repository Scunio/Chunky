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
    /// Altezza delle barre dei controlli quando sono visibili, in alto e in basso: dentro
    /// quelle fasce il tocco appartiene ai controlli, non alle zone di pagina. Senza questo un
    /// tocco sulla parte vuota della barra (a destra o a sinistra del titolo) cadeva nella zona
    /// laterale sottostante e faceva avanzare o retrocedere il fumetto.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
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
            topInset: topInset,
            bottomInset: bottomInset,
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

    /// Le impostazioni che decidono la mappa delle zone, raccolte insieme: viaggiano sempre
    /// tutte assieme dal lettore fino a `action(at:in:options:)`, e passarle una per una
    /// significava solo sette parametri posizionali facili da scambiare fra loro.
    struct Options {
        var oneHanded: Bool
        var oneHandedReversed: Bool
        var rightToLeft: Bool
        var hotCorners: Bool
        var zonesEnabled: Bool
        /// Fasce occupate dalle barre dei controlli quando sono visibili — vedi
        /// `PageTapZones.topInset`.
        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0
    }

    static func action(at point: CGPoint, in size: CGSize, options: Options) -> Action? {
        let oneHanded = options.oneHanded
        let oneHandedReversed = options.oneHandedReversed
        let rightToLeft = options.rightToLeft
        let hotCorners = options.hotCorners
        let zonesEnabled = options.zonesEnabled
        guard size.width > 0, size.height > 0 else { return nil }
        // Fasce dei controlli: il tocco è dei controlli (o non è di nessuno, se cade sul vuoto
        // della barra), mai delle zone di pagina. Prima degli angoli attivi, che altrimenti
        // resterebbero sotto la barra superiore.
        if point.y < options.topInset || point.y > size.height - options.bottomInset { return nil }
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
    let topInset: CGFloat
    let bottomInset: CGFloat
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
        context.coordinator.topInset = topInset
        context.coordinator.bottomInset = bottomInset
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
        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0
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
                options: PageTapZoneGeometry.Options(
                    oneHanded: oneHanded,
                    oneHandedReversed: oneHandedReversed,
                    rightToLeft: rightToLeft,
                    hotCorners: hotCorners,
                    zonesEnabled: zonesEnabled,
                    topInset: topInset,
                    bottomInset: bottomInset
                )
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
