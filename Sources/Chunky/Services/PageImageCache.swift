import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Cache of already-processed page images (crop, upscaling, tint), with prefetch around
/// an index.
///
/// It exists to solve a specific problem with the macOS pager: without a cache, every page
/// change recreates the view and re-decodes from disk (a spinner on every page), because
/// `provider.image(atPage:)` has no memory of its own — every call re-extracts and re-decodes.
/// With the cache, prefetch around the current page almost always finishes before
/// the user turns the page, so the next request finds the result already ready.
///
/// `PlatformImage` (`UIImage`/`NSImage`) isn't `Sendable`; crossing the actor
/// boundary is nonetheless safe because there's no shared mutation (each image is created
/// once and never modified again), but the compiler can't know that on its own.
actor PageImageCache {
    struct ProcessingOptions: Equatable {
        var autoCrop: Bool
        var autoTintContrast: Bool
        var upscaleTargetSize: CGSize?

        static func == (lhs: ProcessingOptions, rhs: ProcessingOptions) -> Bool {
            lhs.autoCrop == rhs.autoCrop
                && lhs.autoTintContrast == rhs.autoTintContrast
                && lhs.upscaleTargetSize == rhs.upscaleTargetSize
        }
    }

    private struct Entry {
        let image: PlatformImage
        let options: ProcessingOptions
        /// Bytes occupied by the decoded bitmap, measured only once here: on macOS
        /// `cgImageRepresentation` re-renders on every access, so it shouldn't be called
        /// repeatedly.
        let cost: Int
    }

    private let provider: ComicPageProvider
    private var entries: [Int: Entry] = [:]
    private var accessOrder: [Int] = []
    /// A cap in bytes, not in page count: a decoded page occupies
    /// width × height × 4, so 8 pages are ~100 MB on iPhone and more than double that on an
    /// iPad Pro. Counting them says nothing about the memory actually committed.
    private let costLimit: Int
    /// Below this threshold nothing is evicted regardless: with huge pages the byte cap
    /// would shrink the cache to a single entry, causing constant re-reading.
    private let minimumEntries: Int
    /// Safety limit on the number of entries, so the dictionary doesn't grow unbounded
    /// when pages are tiny.
    private let maximumEntries: Int
    private var totalCost = 0
    private var memoryWarningObserver: (any NSObjectProtocol)?

    /// Registered on the first request and not in `init`: `init` isn't isolated on the actor, so
    /// it can't touch its properties (in Swift 6 this is an error). Here we're already inside the actor.
    private func startObservingMemoryWarningsIfNeeded() {
        #if canImport(UIKit)
        guard memoryWarningObserver == nil else { return }
        // The byte cap is an estimate: if the system asks for memory, everything is dropped except the
        // page in use, instead of waiting for iOS to kill the app.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.dropAllButMostRecent() }
        }
        #endif
    }

    init(
        provider: ComicPageProvider,
        costLimit: Int = PageImageCache.defaultCostLimit(),
        minimumEntries: Int = 3,
        maximumEntries: Int = 64
    ) {
        self.provider = provider
        self.costLimit = costLimit
        self.minimumEntries = minimumEntries
        self.maximumEntries = maximumEntries
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// A cautious fraction of the device's RAM. It's not the *available* memory: iOS
    /// kills apps well before it runs out, so the fraction is low and capped on top,
    /// so as not to end up committing hundreds of MB on an iPad just because it has plenty.
    static func defaultCostLimit() -> Int {
        let physical = ProcessInfo.processInfo.physicalMemory
        let share = Int(min(physical / 24, UInt64(Int.max)))
        return min(max(share, 64 * 1024 * 1024), 192 * 1024 * 1024)
    }

    /// The options are part of the key, not just the index: `prefetchAroundCurrentPage` and
    /// `PageView.loadImage` compute `upscaleTargetSize` from two different sizes (the whole
    /// viewport versus the single page's frame, which in double-page mode is about half).
    /// Without this comparison, a cache hit could return an image processed for a
    /// different size than the one requested — wrong, not just stale.
    func image(at index: Int, options: ProcessingOptions) -> PlatformImage? {
        startObservingMemoryWarningsIfNeeded()
        if let cached = entries[index], cached.options == options {
            touch(index)
            return cached.image
        }
        guard let processed = process(index: index, options: options) else { return nil }
        store(index: index, image: processed, options: options)
        return processed
    }

    /// Processes ahead of time the pages within `radius` of `index`, skipping those already in cache
    /// with the same options.
    func prefetch(around index: Int, radius: Int, pageCount: Int, options: ProcessingOptions) async {
        startObservingMemoryWarningsIfNeeded()
        guard pageCount > 0 else { return }
        let lower = max(0, index - radius)
        let upper = min(pageCount - 1, index + radius)
        guard lower <= upper else { return }
        for candidate in lower...upper {
            // `.task(id: currentPage)` in ReaderView cancels the previous batch on every
            // page change, but an actor doesn't interrupt an already-running call on its own:
            // without this check, flipping through pages quickly would queue up multiple 5-page
            // batches each for positions already passed, which would still end up being
            // processed before the `image(at:)` request for the page actually reached.
            guard !Task.isCancelled else { return }
            if let existing = entries[candidate], existing.options == options { continue }
            guard let processed = process(index: candidate, options: options) else { continue }
            store(index: candidate, image: processed, options: options)
            // An actor serializes calls: without yielding here, a 5-page
            // prefetch would keep the `image(at:)` request for the page the user
            // just landed on queued for the entire duration of the batch, instead of the few
            // milliseconds of a single page already ready.
            await Task.yield()
        }
    }

    /// To be called when the processing settings change (crop, tint, upscaling):
    /// the entries in cache were processed with the previous options.
    func purge() {
        entries.removeAll()
        accessOrder.removeAll()
        totalCost = 0
    }

    /// Response to a memory warning: only the most recently used page is kept, which is
    /// the one on screen, and the prefetch is left to rebuild the rest.
    func dropAllButMostRecent(_ keep: Int = 1) {
        guard accessOrder.count > keep else { return }
        for index in accessOrder.dropLast(keep) {
            if let removed = entries.removeValue(forKey: index) { totalCost -= removed.cost }
        }
        accessOrder = Array(accessOrder.suffix(keep))
    }

    /// To be called before retrying a page whose read has failed: it removes nothing if
    /// there's nothing in cache (a failure never reaches `store`), but a second attempt
    /// after a partial failure — e.g. the archive was temporarily unreachable from
    /// iCloud — must not find some stale entry and return it without retrying.
    func invalidate(_ index: Int) {
        if let removed = entries.removeValue(forKey: index) { totalCost -= removed.cost }
        accessOrder.removeAll { $0 == index }
    }

    private func process(index: Int, options: ProcessingOptions) -> PlatformImage? {
        guard var loaded = try? provider.image(atPage: index) else { return nil }
        if options.autoCrop {
            loaded = ImageProcessing.autoCropWhiteBorders(loaded)
        }
        if options.autoTintContrast {
            loaded = ImageProcessing.autoTintAndContrast(loaded)
        }
        if let targetSize = options.upscaleTargetSize {
            loaded = ImageProcessing.upscaleIfNeeded(loaded, targetSize: targetSize)
        }
        return loaded
    }

    private func store(index: Int, image: PlatformImage, options: ProcessingOptions) {
        if let previous = entries[index] { totalCost -= previous.cost }
        let cost = Self.cost(of: image)
        entries[index] = Entry(image: image, options: options, cost: cost)
        totalCost += cost
        touch(index)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while totalCost > costLimit || entries.count > maximumEntries {
            guard entries.count > minimumEntries, let oldest = accessOrder.first else { return }
            if let removed = entries.removeValue(forKey: oldest) { totalCost -= removed.cost }
            accessOrder.removeFirst()
        }
    }

    /// `bytesPerRow * height` and not `width * height * 4`: it's the actual allocation, row
    /// alignment included. If the bitmap isn't reachable a large page is assumed, so
    /// a wrong estimate errs on the side of caution instead of inflating the cache.
    private static func cost(of image: PlatformImage) -> Int {
        guard let bitmap = image.cgImageRepresentation else { return 16 * 1024 * 1024 }
        return max(bitmap.bytesPerRow * bitmap.height, 1)
    }

    private func touch(_ index: Int) {
        accessOrder.removeAll { $0 == index }
        accessOrder.append(index)
    }
}
