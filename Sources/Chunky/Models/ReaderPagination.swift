import Foundation

/// Reader pagination arithmetic: which pages form each spread, how to realign
/// when the step changes (1 or 2 pages), and how `currentPage` moves with LTR/RTL.
///
/// Deliberately pure and free of SwiftUI: this is the most delicate part of the reader to
/// touch (direction inversion for manga in particular) and the least testable as long as it
/// lives inside `ReaderView`.
struct ReaderPagination: Sendable, Equatable {
    let pageCount: Int
    let pageStep: Int
    let isRightToLeft: Bool
    /// If true, the first page (the cover) is always its own spread — even when
    /// `pageStep == 2` — and two-page pairing resumes from the second page. Without this,
    /// the cover would end up paired with page 2 like any other spread.
    var coverIsAlone: Bool = false

    enum StepOutcome: Equatable {
        case page(Int)
        /// The step would go past the last page. `triggersNextComic` is true when we're
        /// moving forward in the reading direction — in manga this can
        /// correspond to a negative `direction`, hence the distinction from `direction`.
        case endReached(triggersNextComic: Bool)
        /// The step would go before the first page: no action.
        case beginningReached
    }

    /// Start indices of each spread. With `pageStep == 1` it's every page. With `pageStep == 2`
    /// they're pairs, except the first if `coverIsAlone` — in that case the cover is alone and
    /// pairing resumes from the following page (non-uniform-width spreads,
    /// which is why `step(from:direction:)` walks by spread index rather than by
    /// fixed-step arithmetic).
    var spreadStarts: [Int] {
        guard pageCount > 0, pageStep > 0 else { return [0] }
        guard pageStep > 1, coverIsAlone else {
            return Array(stride(from: 0, to: pageCount, by: pageStep))
        }
        guard pageCount > 1 else { return [0] }
        return [0] + Array(stride(from: 1, to: pageCount, by: pageStep))
    }

    /// Realigns a page to a valid spread start. Needed when the step changes (e.g. from
    /// an odd page to step 2): the current index might no longer be a spread start,
    /// and without realignment the page's tag would find no match.
    func realigned(_ current: Int) -> Int {
        spreadStarts.last(where: { $0 <= current }) ?? 0
    }

    /// Index of the spread containing `page`, for the slider and jump-to-page.
    func spreadIndex(containing page: Int) -> Int {
        let starts = spreadStarts
        return starts.lastIndex(where: { $0 <= page }) ?? 0
    }

    /// True when the spread starting at `leadingIndex` shows a second, paired page — false for
    /// a lone cover (`coverIsAlone`) or the trailing odd page of an uneven page count.
    func showsSecondPage(from leadingIndex: Int) -> Bool {
        guard pageStep > 1, leadingIndex + 1 < pageCount else { return false }
        let starts = spreadStarts
        guard let spreadIndex = starts.firstIndex(of: leadingIndex) else { return pageStep > 1 }
        let nextStart = spreadIndex + 1 < starts.count ? starts[spreadIndex + 1] : pageCount
        return nextStart - leadingIndex >= 2
    }

    /// A reading step. `direction` is the input direction (right=forward,
    /// left=backward): with RTL reading it's inverted internally, so the caller
    /// never has to reason about the reading direction.
    ///
    /// Walks by spread index (not by arithmetic on `pageStep`) because with
    /// `coverIsAlone` spreads don't all have the same width: a jump of `pageStep`
    /// positions would no longer reliably locate the next/previous spread.
    func step(from current: Int, direction: Int) -> StepOutcome {
        let starts = spreadStarts
        guard let currentSpreadIndex = starts.lastIndex(where: { $0 <= current }) else {
            return .beginningReached
        }
        let effectiveDirection = isRightToLeft ? -direction : direction
        let targetSpreadIndex = currentSpreadIndex + effectiveDirection
        if targetSpreadIndex >= starts.count {
            return .endReached(triggersNextComic: effectiveDirection > 0)
        }
        guard targetSpreadIndex >= 0 else { return .beginningReached }
        return .page(starts[targetSpreadIndex])
    }
}
