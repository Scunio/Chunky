import SwiftUI
#if os(iOS)
import UIKit

// Pager del lettore, foglio di condivisione e gesto luminosità a due dita: estratti da
// `ReaderSupportViews.swift`.

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
        // funzionante il cambio pagina programmatico. Ma solo quando cambia davvero: assegnarlo
        // riconfigura i gesture recognizer del pager, e rifarlo a ogni update (questo metodo gira
        // a ogni cambio di stato del padre, zoom compreso) interrompe il trascinamento in corso.
        // Il coordinator è sempre lo stesso oggetto, quindi confrontare solo la presenza basta.
        let wantsInteractiveDataSource = interactiveSwipe
        if (pager.dataSource != nil) != wantsInteractiveDataSource {
            pager.dataSource = wantsInteractiveDataSource ? coordinator : nil
        }

        if coordinator.resetToken != resetToken {
            coordinator.resetToken = resetToken
            coordinator.discardCachedControllers()
            coordinator.currentIndex = selection
            coordinator.lastRefreshedSelection = selection
            pager.setViewControllers([coordinator.controller(for: selection)], direction: .forward, animated: false)
            return
        }

        // I controller in cache vengono riusati esattamente come sono stati creati: senza questo,
        // `content` resta valutato al momento della creazione e tutto ciò che dipende dallo stato
        // del padre si congela — in particolare `isActive`, che abilita pinch/pan/doppio-tap solo
        // sulla pagina corrente. Un controller nato come vicino del dataSource nascerebbe
        // inattivo e ci resterebbe anche una volta diventato la pagina visibile.
        //
        // Solo al cambio pagina, non a ogni update: riassegnare `rootView` rirenderizza le pagine,
        // comprese quelle che UIKit sta animando. Il confronto usa un indice a parte e non
        // `currentIndex`, perché dopo uno swipe interattivo `currentIndex` è già allineato (lo
        // aggiorna `didFinishAnimating`) e un controllo su quello non scatterebbe mai.
        if coordinator.lastRefreshedSelection != selection {
            coordinator.lastRefreshedSelection = selection
            coordinator.refreshCachedContent()
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
        /// Ultimo indice per cui `refreshCachedContent` è già stato eseguito.
        var lastRefreshedSelection: Int
        var resetToken: PagerResetToken
        private var controllers: [Int: UIHostingController<Content>] = [:]

        init(_ parent: PageTurnPager) {
            self.parent = parent
            self.currentIndex = parent.selection
            self.lastRefreshedSelection = parent.selection
            self.resetToken = parent.resetToken
        }

        func discardCachedControllers() {
            controllers.removeAll()
        }

        /// Riallinea il contenuto dei controller già creati allo stato attuale del padre:
        /// `UIHostingController` non rivaluta da solo il proprio `rootView`, va riassegnato.
        func refreshCachedContent() {
            for (index, hosting) in controllers {
                hosting.rootView = parent.content(index)
            }
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
    /// Inizio del gesto: chi ascolta ne approfitta per fotografare la luminosità di partenza
    /// una volta sola, invece di rileggerla a ogni spostamento (vedi `ReaderView`).
    let onBegan: () -> Void
    /// Delta verticale normalizzato (-1...1) da sommare alla luminosità corrente.
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> WindowPanRelayView {
        let view = WindowPanRelayView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: WindowPanRelayView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onBegan = onBegan
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onChange: onChange)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: () -> Void
        var onChange: (CGFloat) -> Void
        init(onBegan: @escaping () -> Void, onChange: @escaping (CGFloat) -> Void) {
            self.onBegan = onBegan
            self.onChange = onChange
        }

        /// Distanza fra le due dita all'inizio del gesto: serve a distinguere un trascinamento
        /// parallelo (luminosità) da un pinch (zoom), che sulla pagina arrivano allo stesso
        /// modo — due dita che si muovono — e che senza questa distinzione si contendono lo
        /// stesso gesto. `nil` finché il gesto non è iniziato con due dita.
        private var initialTouchSpread: CGFloat?
        /// Vero quando la distanza fra le dita è cambiata abbastanza da chiamarlo pinch: da lì
        /// in poi il gesto è dello zoom e la luminosità si tira fuori fino al prossimo tocco.
        private var gestureIsPinch = false
        /// Oltre questo scostamento relativo fra le dita il gesto è un pinch, non un
        /// trascinamento parallelo: serve a non far scivolare la luminosità mentre si ingrandisce
        /// (due dita che si allontanano hanno comunque una componente verticale). Il pinch dal
        /// canto suo non ha una soglia speculare: zooma da subito, come ci si aspetta.
        /// Con le dita vere la distanza oscilla sempre un po', quindi una soglia troppo bassa
        /// classificherebbe come pinch qualunque trascinamento.
        private static let pinchSpreadTolerance: CGFloat = 0.08

        private func touchSpread(of recognizer: UIGestureRecognizer, in view: UIView) -> CGFloat? {
            guard recognizer.numberOfTouches >= 2 else { return nil }
            let first = recognizer.location(ofTouch: 0, in: view)
            let second = recognizer.location(ofTouch: 1, in: view)
            return hypot(second.x - first.x, second.y - first.y)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view, view.bounds.height > 0 else { return }
            switch recognizer.state {
            case .began:
                // Una riga sola per gesto (non per ogni spostamento): serve a poter dire,
                // leggendo la diagnostica dal dispositivo, se il gesto arriva davvero al
                // lettore — è la sola cosa che distingue "il recognizer non scatta" da "la
                // luminosità non si muove".
                DiagnosticLog.log("Luminosità due dita: gesto iniziato (\(recognizer.numberOfTouches) tocchi)")
                onBegan()
                initialTouchSpread = touchSpread(of: recognizer, in: view)
                gestureIsPinch = false
            case .ended, .cancelled, .failed:
                initialTouchSpread = nil
                gestureIsPinch = false
                return
            default:
                break
            }
            guard !gestureIsPinch else {
                recognizer.setTranslation(.zero, in: view)
                return
            }
            // La distanza si confronta solo fra DUE dita: con un terzo dito appoggiato, gli
            // indici 0 e 1 possono riferirsi a una coppia diversa e la distanza salterebbe di
            // colpo, facendo passare per pinch un normale trascinamento — cioè proprio il caso
            // che `maximumNumberOfTouches = 3` serve a tollerare. Con un numero di dita diverso
            // da due si sospende la classificazione e si riparte da capo appena tornano due.
            if recognizer.numberOfTouches == 2 {
                let spread = touchSpread(of: recognizer, in: view)
                if let initialTouchSpread, initialTouchSpread > 0, let spread,
                   abs(spread / initialTouchSpread - 1) > Self.pinchSpreadTolerance {
                    // Le dita si sono avvicinate o allontanate: è uno zoom, non una regolazione
                    // della luminosità. Ci si ferma per tutto il resto del gesto, così le due
                    // cose non si sovrappongono.
                    gestureIsPinch = true
                    recognizer.setTranslation(.zero, in: view)
                    return
                }
                if initialTouchSpread == nil { initialTouchSpread = spread }
            } else {
                initialTouchSpread = nil
            }
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
        // Tre e non due: se durante il trascinamento appoggi anche solo di striscio un terzo
        // dito (o il palmo), con il tetto a due il recognizer fallisce e il gesto muore a metà.
        recognizer.maximumNumberOfTouches = 3
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
