import SwiftUI
#if os(iOS)
import UIKit

/// Reader pager built on a paginated `UICollectionView`, an alternative to
/// `PageTurnPager` (which uses `UIPageViewController`).
///
/// Why not `UIPageViewController`: that component doesn't expose the drag position, doesn't
/// call the delegate on programmatic changes and, to turn off gesture-driven paging, forces
/// you to detach the `dataSource` — i.e. to reconfigure its recognizers while the finger is
/// still on the screen. That's where the reader's two parallel implementations come from
/// (`TabView` when swipe and tap are both "Scroll", programmatic pager otherwise).
///
/// A paginated collection view solves the same requirements with a much more battle-tested
/// piece of UIKit: finger scrolling is plain `UIScrollView`, it's turned off with
/// `isScrollEnabled` without touching the data source, the programmatic change is a
/// `setContentOffset` whose animation we choose, and recycled cells re-evaluate their SwiftUI
/// content on their own — so no frozen `rootView`.
///
/// The interface is deliberately identical to `PageTurnPager`'s, so swapping it in in
/// `ReaderView` is just a name change and nothing else.
struct PageCollectionPager<Content: View>: UIViewRepresentable {
    /// Spread start indices, in increasing order: these are the navigation's "steps".
    let starts: [Int]
    @Binding var selection: Int
    let rightToLeft: Bool
    /// Style of the last programmatic page change (tap, keyboard, jump, scrubber).
    let turnStyle: TapPageTurnStyle
    /// With false, finger scrolling is off: either because the swipe style isn't
    /// "Scroll", or because the page is zoomed in and dragging is used for panning.
    let interactiveSwipe: Bool
    let resetToken: PagerResetToken
    /// Duration of the `.fade` style's cross-dissolve, user-adjustable — see
    /// `Coordinator.crossFade`.
    var fadeDuration: TimeInterval = 0.25
    /// The reader's own stable viewport size (`ReaderContentView.viewportSize`), used instead
    /// of the collection view's live `bounds` for cell sizing — `bounds` still tracks the
    /// status bar's safe area on every controls toggle even with `ignoresSafeArea`, which
    /// cascaded into `ZoomingScrollView` re-fitting the image and visibly resizing the page.
    /// `.zero` falls back to sizing cells from `bounds` (e.g. before the first layout pass).
    let itemSize: CGSize
    let content: (Int) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PagingCollectionView {
        let coordinator = context.coordinator
        let view = PagingCollectionView(frame: .zero, collectionViewLayout: Self.makeLayout(itemSize: itemSize))
        view.backgroundColor = .clear
        view.isPagingEnabled = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        // The page ignores the safe area (the controls go on top of it): without this the
        // collection view would add an inset and the paging width would no longer match the
        // cell's.
        view.contentInsetAdjustmentBehavior = .never
        // Nearby pages are built by the reader's prefetch, not the collection view: a cell
        // created ahead of time also mounts its page's gesture relays, which is exactly the
        // interference fixed in `cd82a30`.
        view.isPrefetchingEnabled = false
        view.delegate = coordinator
        view.onBoundsSizeChange = { [weak coordinator] in coordinator?.realignToCurrentPage() }
        coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PagingCollectionView, context: Context) {
        context.coordinator.update(with: self, view: view)
    }

    /// A cell as big as the viewport, no spacing: with `isPagingEnabled` the scroll step
    /// is the collection view's width, so cell and step must match exactly or pages get
    /// misaligned as you page through. Sized from `itemSize` when available (see its doc
    /// comment); falls back to matching the collection view's own live bounds otherwise.
    fileprivate static func makeLayout(itemSize: CGSize) -> UICollectionViewCompositionalLayout {
        let full = itemSize == .zero
            ? NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1))
            : NSCollectionLayoutSize(widthDimension: .absolute(itemSize.width), heightDimension: .absolute(itemSize.height))
        let item = NSCollectionLayoutItem(layoutSize: full)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: full, repeatingSubitem: item, count: 1)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .zero
        // `let` and not `var`: the configuration is a class, so setting one of its properties
        // isn't a mutation of the variable.
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal
        return UICollectionViewCompositionalLayout(section: section, configuration: configuration)
    }

    final class Coordinator: NSObject, UICollectionViewDelegate {
        fileprivate var parent: PageCollectionPager
        /// Currently shown spread start index, according to the coordinator. The comparison to
        /// decide whether to turn the page is always against this, never against a value
        /// captured in the view: `updateUIView` runs on every state change in the parent (zoom,
        /// for one, changes on every pinch) and a wrong comparison would turn the page on its
        /// own.
        private var currentIndex: Int
        /// Last index for which the cells' content has already been re-evaluated.
        private var lastRefreshedSelection: Int
        private var resetToken: PagerResetToken
        private var itemSize: CGSize
        private weak var collectionView: PagingCollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, Int>?
        /// The spread starts in the order they appear on screen, left to right.
        /// In manga this order is reversed: the highest index is on the left. Reversing the
        /// array is more robust than inverting the scroll direction, because it leaves the
        /// collection view its normal semantics — offset growing to the right — and confines
        /// the inversion to a single spot.
        private var visualOrder: [Int] = []
        /// True while an animated programmatic scroll is in progress (the page change from tap,
        /// keyboard or jump). Used to avoid letting a drag start halfway through.
        private var isRunningProgrammaticScroll = false

        init(_ parent: PageCollectionPager) {
            self.parent = parent
            self.currentIndex = parent.selection
            self.lastRefreshedSelection = parent.selection
            self.resetToken = parent.resetToken
            self.itemSize = parent.itemSize
        }

        // MARK: - Construction

        func attach(to view: PagingCollectionView) {
            collectionView = view

            let registration = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, start in
                guard let self else { return }
                // `parent` is always the one from the latest update, so the content is
                // re-evaluated with the current state every time the cell is created or reconfigured.
                cell.contentConfiguration = UIHostingConfiguration { self.parent.content(start) }
                    .margins(.all, 0)
                cell.backgroundConfiguration = .clear()
            }

            dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: view) { collectionView, indexPath, start in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: start)
            }

            applySnapshot()
            // At creation time the bounds are still zero, so nothing can be positioned here:
            // `realignToCurrentPage` takes care of it at the first real layout pass.
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

        /// Re-evaluates the SwiftUI content of existing cells without rebuilding them. Used to
        /// propagate what depends on the current page — `isActive`, which enables
        /// pinch/pan/double-tap only on the visible page — to cells already around.
        /// Only cells currently on screen: reconfiguring every identifier would make a
        /// three-hundred-page comic walk through three hundred items on every page change. The
        /// ones not created yet don't need it — they're born already with the current state
        /// when the collection view asks for them.
        private func refreshVisibleContent() {
            guard let dataSource, let collectionView else { return }
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            guard !visible.isEmpty else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(visible)
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        // MARK: - Update from the parent

        func update(with parent: PageCollectionPager, view: PagingCollectionView) {
            self.parent = parent

            // Turning off gesture-driven paging is a property, not a remount: that's the
            // difference from `UIPageViewController`, where the same thing required detaching
            // the `dataSource` and therefore reconfiguring the recognizers on every update.
            if view.isScrollEnabled != parent.interactiveSwipe {
                view.isScrollEnabled = parent.interactiveSwipe
            }

            // Rebuilt only on a genuine size change (rotation, multitasking), not on every
            // controls toggle: `itemSize` already ignores the status bar's safe-area churn.
            if parent.itemSize != .zero, parent.itemSize != itemSize {
                itemSize = parent.itemSize
                view.setCollectionViewLayout(PageCollectionPager.makeLayout(itemSize: itemSize), animated: false)
                realignToCurrentPage()
            }

            if resetToken != parent.resetToken {
                resetToken = parent.resetToken
                currentIndex = parent.selection
                lastRefreshedSelection = parent.selection
                applySnapshot()
                scroll(toStart: parent.selection, animated: false)
                return
            }

            // Safety net: if the spread starts change without the token changing, the
            // collection view would show pages that no longer exist.
            if visualOrder != makeVisualOrder() {
                applySnapshot()
                scroll(toStart: currentIndex, animated: false)
            }

            // Only on page change, not on every update: reconfiguring the cells re-renders the
            // content, including pages UIKit is currently animating.
            if lastRefreshedSelection != parent.selection {
                lastRefreshedSelection = parent.selection
                refreshVisibleContent()
            }

            guard parent.selection != currentIndex else { return }
            let previousIndex = currentIndex
            currentIndex = parent.selection
            switch parent.turnStyle {
            case .slide:
                scroll(toStart: parent.selection, animated: true)
            case .fade:
                crossFade(on: view, toStart: parent.selection)
            case .immediate:
                lightSlide(on: view, from: previousIndex, toStart: parent.selection)
            case .disabled:
                scroll(toStart: parent.selection, animated: false)
            }
        }

        /// Hand-rolled cross-dissolve, with an overlaid snapshot.
        ///
        /// The obvious route — `UIView.transition(.transitionCrossDissolve)` around the jump — doesn't
        /// work here: that method captures the final state as soon as the block returns, but the
        /// collection view only creates and positions the destination cell at the next layout
        /// pass, so the old page dissolves against the empty background. Measured: five frames
        /// of solid background between one page and the next, no blending at all.
        /// (`UIPageViewController` got away with it because `setViewControllers` adds the
        /// child's view synchronously.)
        ///
        /// By first freezing the current state into a snapshot, we're guaranteed both sides of
        /// the dissolve actually exist: underneath we jump straight to the new page, on top we
        /// fade the snapshot away.
        private func crossFade(on view: PagingCollectionView, toStart start: Int) {
            guard let snapshot = view.snapshotView(afterScreenUpdates: false) else {
                scroll(toStart: start, animated: false)
                return
            }
            snapshot.isUserInteractionEnabled = false
            // The snapshot is a child of a scroll view, so it would scroll along with the
            // content: anchoring it to the offset keeps it fixed on the viewport, which is what
            // it needs to look like.
            snapshot.frame = CGRect(origin: view.contentOffset, size: view.bounds.size)
            view.addSubview(snapshot)

            scroll(toStart: start, animated: false)
            view.layoutIfNeeded()
            snapshot.frame = CGRect(origin: view.contentOffset, size: view.bounds.size)

            UIView.animate(withDuration: parent.fadeDuration, delay: 0, options: [.allowUserInteraction]) {
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }

        /// "Immediate" style: the jump itself stays instant (that's the point of the
        /// style — no waiting for a slide/fade to finish before the next tap), but a bare
        /// instant cut reads as a glitch, not a page turn (verified live). This adds a
        /// small, quick embellishment on top without slowing anything down: the OLD page,
        /// frozen as a snapshot, slides a short distance and fades out over the new one —
        /// unlike `.slide`, which travels the full screen width and only starts once the
        /// gesture says which spread is next, this is a fixed, brief flourish shown after
        /// the jump has already happened underneath.
        private func lightSlide(on view: PagingCollectionView, from previousIndex: Int, toStart start: Int) {
            guard let snapshot = view.snapshotView(afterScreenUpdates: false) else {
                scroll(toStart: start, animated: false)
                return
            }
            snapshot.isUserInteractionEnabled = false
            snapshot.frame = CGRect(origin: view.contentOffset, size: view.bounds.size)
            view.addSubview(snapshot)

            // Visual order already accounts for manga's mirrored layout (see
            // `makeVisualOrder`), so a plain index comparison gives the right screen
            // direction without a separate rightToLeft check here.
            let previousItem = visualOrder.firstIndex(of: previousIndex) ?? 0
            let newItem = visualOrder.firstIndex(of: start) ?? previousItem
            let movingForwardOnScreen = newItem > previousItem

            scroll(toStart: start, animated: false)
            view.layoutIfNeeded()
            snapshot.frame = CGRect(origin: view.contentOffset, size: view.bounds.size)

            let distance: CGFloat = 28
            UIView.animate(
                withDuration: 0.16, delay: 0,
                options: [.allowUserInteraction, .curveEaseOut]
            ) {
                snapshot.alpha = 0
                snapshot.transform = CGAffineTransform(translationX: movingForwardOnScreen ? -distance : distance, y: 0)
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }

        // MARK: - Positioning

        /// The offset is computed, not delegated to `scrollToItem`: with paging enabled the
        /// step is exactly the viewport's width, so the calculation is exact and doesn't depend
        /// on how the layout decides to align the cell.
        private func scroll(toStart start: Int, animated: Bool) {
            guard let collectionView,
                  let item = visualOrder.firstIndex(of: start) else { return }
            let width = collectionView.bounds.width
            guard width > 0 else { return }
            isRunningProgrammaticScroll = animated
            collectionView.setContentOffset(CGPoint(x: CGFloat(item) * width, y: 0), animated: animated)
        }

        /// After a rotation (or any size change) the same offset in points no longer
        /// corresponds to the same page: without this you'd end up stuck halfway between two.
        /// This is also what positions the initial page, at the first useful layout pass.
        func realignToCurrentPage() {
            scroll(toStart: currentIndex, animated: false)
        }

        // MARK: - Finger scrolling

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

        /// If the finger lands while an animated page change is still in flight, the animation
        /// is closed immediately by jumping to its destination, so the drag starts from a
        /// settled page. Without this the pan adds on top of the ongoing scroll and you end up
        /// two pages further along: measured, a swipe backward from page 6 ended up on page 4.
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard isRunningProgrammaticScroll else { return }
            isRunningProgrammaticScroll = false
            scroll(toStart: currentIndex, animated: false)
        }

        /// Aligns the state to the page the scroll has settled on. First the coordinator,
        /// then the binding: the update that follows sees no difference and doesn't re-animate
        /// a page change the finger has already made.
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

/// `UICollectionView` that notifies when its own size changes. Used to re-level the offset
/// after a rotation, and to position the initial page: at creation time the bounds are zero,
/// so the first useful positioning can only happen here.
final class PagingCollectionView: UICollectionView {
    var onBoundsSizeChange: (() -> Void)?
    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        let sizeChanged = bounds.size != lastBoundsSize
        super.layoutSubviews()
        guard sizeChanged else { return }
        // Updated before the callback: the one inside changes the offset, which re-enters here,
        // and without the value already updated the recursion wouldn't stop.
        lastBoundsSize = bounds.size
        onBoundsSizeChange?()
    }
}

#endif
