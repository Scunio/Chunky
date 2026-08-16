import SwiftUI
#if os(iOS)
import UIKit

/// Pager del lettore costruito su una `UICollectionView` paginata, alternativa a
/// `PageTurnPager` (che usa `UIPageViewController`).
///
/// Perché non `UIPageViewController`: quel componente non espone la posizione del
/// trascinamento, non chiama il delegate sui cambi programmatici e, per spegnere il paging a
/// gesto, obbliga a staccare il `dataSource` — cioè a riconfigurare i suoi recognizer proprio
/// mentre il dito è sullo schermo. Da lì nascono le due implementazioni parallele del lettore
/// (`TabView` quando swipe e tap sono entrambi "Scorrimento", pager programmatico altrimenti).
///
/// Una collection view paginata risolve gli stessi requisiti con un pezzo di UIKit molto più
/// rodato: lo scorrimento a dito è quello di `UIScrollView`, si spegne con `isScrollEnabled`
/// senza toccare la sorgente dati, il cambio programmatico è un `setContentOffset` di cui
/// scegliamo l'animazione, e le celle riciclate rivalutano il contenuto SwiftUI da sole —
/// quindi niente `rootView` congelata.
///
/// L'interfaccia è volutamente identica a quella di `PageTurnPager`, così sostituirlo in
/// `ReaderView` è un cambio di nome e nient'altro.
struct PageCollectionPager<Content: View>: UIViewRepresentable {
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

    func makeUIView(context: Context) -> PagingCollectionView {
        let coordinator = context.coordinator
        let view = PagingCollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        view.backgroundColor = .clear
        view.isPagingEnabled = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        // La pagina ignora la safe area (i controlli ci vanno sopra): senza questo la collection
        // view aggiungerebbe un inset e la larghezza di paginazione non coinciderebbe più con
        // quella della cella.
        view.contentInsetAdjustmentBehavior = .never
        // Le pagine vicine le costruisce il prefetch del lettore, non la collection view: una
        // cella creata in anticipo monta anche i relay di gesto della propria pagina, che è
        // esattamente l'interferenza sistemata in `cd82a30`.
        view.isPrefetchingEnabled = false
        view.delegate = coordinator
        view.onBoundsSizeChange = { [weak coordinator] in coordinator?.realignToCurrentPage() }
        coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PagingCollectionView, context: Context) {
        context.coordinator.update(with: self, view: view)
    }

    /// Una cella grande quanto il viewport, nessuna spaziatura: con `isPagingEnabled` il passo
    /// dello scorrimento è la larghezza della collection view, quindi cella e passo devono
    /// coincidere esattamente o le pagine si disallineano man mano che si sfoglia.
    private static func makeLayout() -> UICollectionViewCompositionalLayout {
        let full = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1))
        let item = NSCollectionLayoutItem(layoutSize: full)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: full, repeatingSubitem: item, count: 1)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .zero
        // `let` e non `var`: la configurazione è una classe, quindi impostarne una proprietà
        // non è una mutazione della variabile.
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal
        return UICollectionViewCompositionalLayout(section: section, configuration: configuration)
    }

    final class Coordinator: NSObject, UICollectionViewDelegate {
        fileprivate var parent: PageCollectionPager
        /// Indice di inizio spread attualmente mostrato, secondo il coordinator. Il confronto per
        /// decidere se girare la pagina è sempre con questo, mai con un valore catturato nella
        /// view: `updateUIView` gira a ogni cambio di stato del padre (lo zoom, per dirne uno,
        /// cambia a ogni pizzicata) e un confronto sbagliato girerebbe la pagina da solo.
        private var currentIndex: Int
        /// Ultimo indice per cui il contenuto delle celle è già stato rivalutato.
        private var lastRefreshedSelection: Int
        private var resetToken: PagerResetToken
        private weak var collectionView: PagingCollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, Int>?
        /// Gli inizi spread nell'ordine in cui stanno sullo schermo, da sinistra a destra.
        /// Nei manga è l'ordine rovesciato: l'indice più alto sta a sinistra. Girare l'array è
        /// più solido che invertire il verso di scorrimento, perché lascia alla collection view
        /// la sua semantica normale — offset che cresce verso destra — e concentra l'inversione
        /// in un punto solo.
        private var visualOrder: [Int] = []
        /// Vero mentre è in corso uno scorrimento programmatico animato (il cambio pagina da tap,
        /// tastiera o salto). Serve a non lasciare che un trascinamento parta a metà strada.
        private var isRunningProgrammaticScroll = false

        init(_ parent: PageCollectionPager) {
            self.parent = parent
            self.currentIndex = parent.selection
            self.lastRefreshedSelection = parent.selection
            self.resetToken = parent.resetToken
        }

        // MARK: - Costruzione

        func attach(to view: PagingCollectionView) {
            collectionView = view

            let registration = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, start in
                guard let self else { return }
                // `parent` è sempre quello dell'ultimo update, quindi il contenuto è rivalutato
                // con lo stato corrente ogni volta che la cella viene creata o riconfigurata.
                cell.contentConfiguration = UIHostingConfiguration { self.parent.content(start) }
                    .margins(.all, 0)
                cell.backgroundConfiguration = .clear()
            }

            dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: view) { collectionView, indexPath, start in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: start)
            }

            applySnapshot()
            // Alla creazione i bounds sono ancora a zero, quindi qui non si può posizionare
            // niente: ci pensa `realignToCurrentPage` al primo layout vero.
        }

        private func makeVisualOrder() -> [Int] {
            parent.rightToLeft ? parent.starts.reversed() : parent.starts
        }

        private func applySnapshot() {
            guard let dataSource else { return }
            visualOrder = makeVisualOrder()
            var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
            snapshot.appendSections([0])
            snapshot.appendItems(visualOrder)
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        /// Rivaluta il contenuto SwiftUI delle celle esistenti senza ricostruirle. Serve a
        /// propagare quello che dipende dalla pagina corrente — `isActive`, che abilita
        /// pinch/pan/doppio-tap solo sulla pagina visibile — alle celle già in giro.
        /// Solo le celle a schermo: riconfigurare tutti gli identificatori farebbe attraversare a
        /// un fumetto di trecento pagine trecento elementi a ogni cambio pagina. Quelle non ancora
        /// create non servono — nascono già con lo stato corrente quando la collection view le
        /// chiede.
        private func refreshVisibleContent() {
            guard let dataSource, let collectionView else { return }
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            guard !visible.isEmpty else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(visible)
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        // MARK: - Aggiornamento dal padre

        func update(with parent: PageCollectionPager, view: PagingCollectionView) {
            self.parent = parent

            // Spegnere il paging a gesto è una proprietà, non un rimontaggio: è la differenza
            // con `UIPageViewController`, dove la stessa cosa richiedeva di staccare il
            // `dataSource` e quindi di riconfigurare i recognizer a ogni update.
            if view.isScrollEnabled != parent.interactiveSwipe {
                view.isScrollEnabled = parent.interactiveSwipe
            }

            if resetToken != parent.resetToken {
                resetToken = parent.resetToken
                currentIndex = parent.selection
                lastRefreshedSelection = parent.selection
                applySnapshot()
                scroll(toStart: parent.selection, animated: false)
                return
            }

            // Rete di sicurezza: se gli inizi spread cambiano senza che cambi il token, la
            // collection view mostrerebbe pagine che non esistono più.
            if visualOrder != makeVisualOrder() {
                applySnapshot()
                scroll(toStart: currentIndex, animated: false)
            }

            // Solo al cambio pagina, non a ogni update: riconfigurare le celle rirenderizza il
            // contenuto, comprese le pagine che UIKit sta animando.
            if lastRefreshedSelection != parent.selection {
                lastRefreshedSelection = parent.selection
                refreshVisibleContent()
            }

            guard parent.selection != currentIndex else { return }
            currentIndex = parent.selection
            switch parent.turnStyle {
            case .slide:
                scroll(toStart: parent.selection, animated: true)
            case .fade:
                crossFade(on: view, toStart: parent.selection)
            case .immediate, .disabled:
                scroll(toStart: parent.selection, animated: false)
            }
        }

        /// Dissolvenza fatta a mano, con uno snapshot sovrapposto.
        ///
        /// La via ovvia — `UIView.transition(.transitionCrossDissolve)` attorno al salto — qui non
        /// funziona: quel metodo fotografa lo stato finale appena il blocco ritorna, ma la
        /// collection view crea e posiziona la cella di destinazione solo al layout successivo,
        /// quindi si dissolve la pagina vecchia contro lo sfondo vuoto. Misurato: cinque
        /// fotogrammi di sfondo pieno fra una pagina e l'altra, nessuna miscelazione.
        /// (`UIPageViewController` se la cavava perché `setViewControllers` aggiunge la view del
        /// figlio in modo sincrono.)
        ///
        /// Congelando prima lo stato corrente in uno snapshot si ha la garanzia che entrambi i
        /// lati della dissolvenza esistano davvero: sotto si salta subito alla pagina nuova,
        /// sopra si fa sparire lo snapshot.
        private func crossFade(on view: PagingCollectionView, toStart start: Int) {
            guard let snapshot = view.snapshotView(afterScreenUpdates: false) else {
                scroll(toStart: start, animated: false)
                return
            }
            snapshot.isUserInteractionEnabled = false
            // Lo snapshot è figlio di una scroll view, quindi scorrerebbe insieme al contenuto:
            // ancorandolo all'offset resta fermo sul viewport, che è quello che deve sembrare.
            snapshot.frame = CGRect(origin: view.contentOffset, size: view.bounds.size)
            view.addSubview(snapshot)

            scroll(toStart: start, animated: false)
            view.layoutIfNeeded()
            snapshot.frame = CGRect(origin: view.contentOffset, size: view.bounds.size)

            UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction]) {
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }

        // MARK: - Posizionamento

        /// L'offset si calcola, non si delega a `scrollToItem`: con il paging attivo il passo è
        /// esattamente la larghezza del viewport, quindi il conto è esatto e non dipende da come
        /// il layout decide di allineare la cella.
        private func scroll(toStart start: Int, animated: Bool) {
            guard let collectionView,
                  let item = visualOrder.firstIndex(of: start) else { return }
            let width = collectionView.bounds.width
            guard width > 0 else { return }
            isRunningProgrammaticScroll = animated
            collectionView.setContentOffset(CGPoint(x: CGFloat(item) * width, y: 0), animated: animated)
        }

        /// Dopo una rotazione (o qualunque cambio di dimensione) lo stesso offset in punti non
        /// corrisponde più alla stessa pagina: senza questo si resterebbe a metà fra due.
        /// È anche ciò che posiziona la pagina iniziale, al primo layout utile.
        func realignToCurrentPage() {
            scroll(toStart: currentIndex, animated: false)
        }

        // MARK: - Scorrimento a dito

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            settleOnVisiblePage()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { settleOnVisiblePage() }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isRunningProgrammaticScroll = false
            settleOnVisiblePage()
        }

        /// Se il dito arriva mentre un cambio pagina animato è ancora in volo, l'animazione viene
        /// chiusa subito portandola a destinazione, così il trascinamento parte da una pagina
        /// ferma. Senza questo il pan si somma allo scorrimento in corso e si arriva due pagine
        /// più in là: misurato, uno swipe indietro da pagina 6 finiva su pagina 4.
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard isRunningProgrammaticScroll else { return }
            isRunningProgrammaticScroll = false
            scroll(toStart: currentIndex, animated: false)
        }

        /// Allinea lo stato alla pagina su cui lo scorrimento si è fermato. Prima il coordinator,
        /// poi il binding: l'update che ne segue non vede differenze e non rianima un cambio
        /// pagina che il dito ha già fatto.
        private func settleOnVisiblePage() {
            guard let collectionView, !visualOrder.isEmpty else { return }
            let width = collectionView.bounds.width
            guard width > 0 else { return }
            let item = Int((collectionView.contentOffset.x / width).rounded())
            let start = visualOrder[min(max(item, 0), visualOrder.count - 1)]
            guard start != currentIndex else { return }
            currentIndex = start
            lastRefreshedSelection = start
            parent.selection = start
            refreshVisibleContent()
        }
    }
}

/// `UICollectionView` che avvisa quando cambia la propria dimensione. Serve a rimettere in
/// bolla l'offset dopo una rotazione, e a posizionare la pagina iniziale: alla creazione i
/// bounds sono a zero, quindi il primo posizionamento utile può avvenire solo qui.
final class PagingCollectionView: UICollectionView {
    var onBoundsSizeChange: (() -> Void)?
    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        let sizeChanged = bounds.size != lastBoundsSize
        super.layoutSubviews()
        guard sizeChanged else { return }
        // Aggiornato prima della callback: quella dentro cambia l'offset, che rientra qui, e
        // senza il valore già aggiornato la ricorsione non si fermerebbe.
        lastBoundsSize = bounds.size
        onBoundsSizeChange?()
    }
}

#endif
