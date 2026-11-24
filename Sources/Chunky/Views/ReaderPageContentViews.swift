import SwiftUI
#if os(iOS)
import UIKit
#endif

private struct PageProcessingSettings: Equatable {
    let autoCrop: Bool
    let autoTintContrast: Bool
    let upscale: Bool
}

// Content of a page or spread: which image to show, how to load it and how to size it.
// Extracted from `ReaderSupportViews.swift`; the zoom layer lives in
// `ReaderZoomViews.swift`, the pager in `ReaderPagerViews.swift`.

/// Shows a single page, or two side by side in double-page mode. In an environment with
/// layoutDirection .rightToLeft, the HStack is automatically mirrored by SwiftUI: the page
/// with the lower index therefore ends up on the right, as per manga convention.
struct PageSpreadView: View {
    let provider: ComicPageProvider
    let leadingIndex: Int
    /// With "cover alone" enabled, not every spread has the same width (the cover is 1
    /// page, the rest are 2), so the full pagination is needed to know whether *this*
    /// particular spread shows one page or two.
    let pagination: ReaderPagination
    let isZoomed: Binding<Bool>
    /// macOS only: when present, `PageView`s consult it instead of re-decoding from disk on
    /// every reappearance. `nil` on iOS, where the problem doesn't exist (the
    /// `UIHostingController` cache in `PageTurnPager` already avoids the reappearance).
    var imageCache: PageImageCache?
    #if os(iOS)
    /// True only for the spread that's actually shown: the pager also keeps 1-2 nearby
    /// spreads alive for swiping, and each one mounts its own
    /// `ZoomableImageView`/`SpreadZoomableImageView` with gesture recognizers attached to the
    /// `window` (see the comment there). Without this flag, pinch/double-tap on ANY spread
    /// also reaches the ones off-screen — verified live with debug logs: a pinch on one page
    /// triggered `.began` on three different `Coordinator`s at the same time, and a
    /// preloaded spread could end up with a "ghost" zoom that then appeared cropped as soon
    /// as it became the visible one.
    var isActive: Bool = true
    /// Same zone map `PageTapZones` uses for tap-to-turn-page, handed down so the zoom
    /// coordinators can exclude the page-turn zones from double-tap-to-zoom — see the
    /// comment on `ZoomableImageView.Coordinator.handleDoubleTap`.
    var tapZoneOptions = PageTapZoneGeometry.Options(
        oneHanded: false, oneHandedReversed: false, rightToLeft: false,
        hotCorners: false, zonesEnabled: false, topInset: 0, bottomInset: 0
    )
    @Environment(\.layoutDirection) private var layoutDirection
    #elseif os(macOS)
    /// False for the neighbouring spreads `ReaderContentView.macPersistentPager` keeps mounted
    /// off-screen: their pages drop any zoom when they leave the screen and ignore ⌘+/⌘−/⌘0.
    var isActive: Bool = true
    #endif
    #if os(macOS) || os(iOS)
    /// The upscaling target for each page, computed once by `ReaderContentView` and shared
    /// with its prefetch, so the two always build the same `ProcessingOptions` (part of the
    /// cache key) — previously the prefetch guessed half the viewport while a paired page
    /// asked for `height * 2/3`, and every double-page request missed the cache.
    var upscaleTargetSize: (Int) -> CGSize? = { _ in nil }
    #endif

    /// True only if this specific spread contains two pages: with `coverIsAlone`, the
    /// spread that starts at the cover (index 0) stays 1 wide even at step 2.
    private var showsSecondPage: Bool { pagination.showsSecondPage(from: leadingIndex) }

    var body: some View {
        // The GeometryReader here (no longer inside each PageView) is what lets the two
        // pages of a spread touch each other: by passing a fixed height and letting the
        // width follow the image's proportions, the HStack sizes them based on their own
        // content instead of always splitting the space in half — which is what caused the
        // black band between pages (each centered within its own half, with independent
        // margins instead of joined ones).
        GeometryReader { proxy in
            #if os(iOS)
            // On iOS, with two pages, a single zoom container for the whole pair (as Aidoku
            // does with `ReaderDoublePageViewController`) instead of two independent
            // `PageView`s: this allows zooming into a detail that straddles the two pages,
            // which is impossible with two separate scroll views — and it's also why, with
            // two independent ones, you'd need to guess which of the two the pinch should
            // "win".
            if showsSecondPage {
                SpreadPairView(
                    provider: provider,
                    leadingIndex: leadingIndex,
                    rightToLeft: layoutDirection == .rightToLeft,
                    height: proxy.size.height,
                    isZoomed: isZoomed,
                    imageCache: imageCache,
                    isActive: isActive,
                    tapZoneOptions: tapZoneOptions,
                    upscaleTargetSize: upscaleTargetSize
                )
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            } else {
                PageView(
                    provider: provider, index: leadingIndex, isDoublePage: pagination.pageStep > 1,
                    isZoomed: isZoomed, imageCache: imageCache, pairedHeight: nil, isActive: isActive,
                    tapZoneOptions: tapZoneOptions, upscaleTargetSizeOverride: upscaleTargetSize(leadingIndex)
                )
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            }
            #else
            HStack(spacing: 0) {
                pageView(index: leadingIndex, pairedHeight: showsSecondPage ? proxy.size.height : nil)
                if showsSecondPage {
                    pageView(index: leadingIndex + 1, pairedHeight: proxy.size.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            #endif
        }
    }

    #if !os(iOS)
    private func pageView(index: Int, pairedHeight: CGFloat?) -> PageView {
        var view = PageView(
            provider: provider, index: index, isDoublePage: pagination.pageStep > 1,
            isZoomed: isZoomed, imageCache: imageCache, pairedHeight: pairedHeight
        )
        #if os(macOS)
        view.upscaleTargetSizeOverride = upscaleTargetSize(index)
        view.isActive = isActive
        #endif
        return view
    }
    #endif
}

#if os(iOS)
/// The two pages of a spread, loaded together and shown in a single zoomable `UIScrollView`
/// (see `SpreadZoomableImageView`) instead of two independent ones: this allows pinching a
/// detail that straddles the boundary between the pages, and there's no need to decide
/// which of the two "wins" the gesture.
private struct SpreadPairView: View {
    let provider: ComicPageProvider
    let leadingIndex: Int
    let rightToLeft: Bool
    let height: CGFloat
    let isZoomed: Binding<Bool>
    var imageCache: PageImageCache?
    var isActive: Bool = true
    var tapZoneOptions = PageTapZoneGeometry.Options(
        oneHanded: false, oneHandedReversed: false, rightToLeft: false,
        hotCorners: false, zonesEnabled: false, topInset: 0, bottomInset: 0
    )
    /// See `PageSpreadView.upscaleTargetSize`: the same per-page target the prefetch uses.
    var upscaleTargetSize: (Int) -> CGSize? = { _ in nil }

    @ObservedObject private var theme = AppTheme.shared
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    @State private var leadingImage: PlatformImage?
    @State private var trailingImage: PlatformImage?
    @State private var leadingFailed = false
    @State private var trailingFailed = false
    @State private var loadGeneration = 0

    private var processingSettings: PageProcessingSettings {
        PageProcessingSettings(
            autoCrop: isAutoCropEnabled,
            autoTintContrast: isAutoTintContrastEnabled,
            upscale: isUpscalingEnabled
        )
    }

    var body: some View {
        Group {
            if let leadingImage, let trailingImage {
                // The visual order (which page is on the left) follows the reading direction:
                // in manga (RTL) the lower index is on the right.
                let ordered = rightToLeft ? [trailingImage, leadingImage] : [leadingImage, trailingImage]
                SpreadZoomableImageView(images: ordered, isZoomed: isZoomed, isActive: isActive, tapZoneOptions: tapZoneOptions)
                    .frame(height: height)
                    .overlay(tintOverlay)
            } else {
                // 2:3 estimate for each until the real proportions are known.
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
            loadPages()
        }
        .onChange(of: processingSettings) { _, _ in reloadPages() }
    }

    private func reloadPages() {
        loadGeneration += 1
        leadingImage = nil
        trailingImage = nil
        leadingFailed = false
        trailingFailed = false
        loadPages()
    }

    private func loadPages() {
        loadPage(index: leadingIndex) { leadingImage = $0 } onFailure: { leadingFailed = true }
        loadPage(index: leadingIndex + 1) { trailingImage = $0 } onFailure: { trailingFailed = true }
    }

    /// Spinner while loading, "Retry" button if the read failed — instead of a spinner
    /// stuck forever with no visible trace of the problem (original behavior, verified
    /// live: a single read failure, even a transient one, was enough to block the page
    /// indefinitely). See Aidoku's `ReaderDoublePageViewController`, which has the same
    /// button for the same reason.
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
        let generation = loadGeneration
        let autoCrop = isAutoCropEnabled
        let upscale = isUpscalingEnabled
        let autoTintContrast = isAutoTintContrastEnabled
        // Target width estimated 2:3, only for any upscaling — it doesn't affect the
        // layout, which derives from the real proportions anyway once the image is loaded.
        // The reader's shared function first, so the prefetch's cache key matches exactly.
        let targetSize = upscaleTargetSize(index) ?? CGSize(width: height * 2 / 3, height: height)

        if let imageCache {
            let options = PageImageCache.ProcessingOptions(
                autoCrop: autoCrop,
                autoTintContrast: autoTintContrast,
                upscaleTargetSize: upscale ? targetSize : nil
            )
            Task {
                if let loaded = await imageCache.image(at: index, options: options) {
                    await MainActor.run {
                        guard generation == loadGeneration else { return }
                        onSuccess(loaded)
                    }
                } else {
                    await MainActor.run {
                        guard generation == loadGeneration else { return }
                        onFailure()
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
                DiagnosticLog.log("Lettura pagina \(index) fallita: \((error as NSError).localizedDescription)")
                DispatchQueue.main.async {
                    guard generation == self.loadGeneration else { return }
                    onFailure()
                }
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
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                onSuccess(final)
            }
        }
    }
}
#endif

#if os(macOS)
/// Applica il blur solo quando il raggio è > 0: il modificatore `.blur`, anche a raggio
/// zero, forza un passaggio CoreImage sull'intera pagina a ogni frame su macOS — ed è
/// sempre attaccato durante lo scroll/pan della pagina zoomata.
private extension View {
    @ViewBuilder
    func conditionalMotionBlur(radius: CGFloat) -> some View {
        if radius > 0 {
            self.blur(radius: radius)
        } else {
            self
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
    /// Non-nil only for a page that's really part of a two-page spread, side by side with
    /// another "touching" page (see `PageSpreadView`): in that case the width follows the
    /// image's proportions instead of filling a fixed half of the frame.
    var pairedHeight: CGFloat?
    /// iOS only: true only for the page that's actually shown, not for the nearby ones kept
    /// alive by the pager for swiping — see the comment on `PageSpreadView.isActive`.
    /// Ignored on macOS, where this preloading doesn't exist and zoom stays on ordinary
    /// SwiftUI gestures.
    var isActive: Bool = true
    #if os(iOS)
    var tapZoneOptions = PageTapZoneGeometry.Options(
        oneHanded: false, oneHandedReversed: false, rightToLeft: false,
        hotCorners: false, zonesEnabled: false, topInset: 0, bottomInset: 0
    )
    #endif
    #if os(macOS) || os(iOS)
    /// See `PageSpreadView.upscaleTargetSize`. `nil` falls back to the laid-out size.
    var upscaleTargetSizeOverride: CGSize?
    #endif
    #if os(macOS)
    @Environment(\.readerZoomCommand) private var zoomCommand
    #endif
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    @AppStorage("singlePageZoomMode") private var singlePageZoomMode = PageZoomMode.auto
    @AppStorage("doublePageZoomMode") private var doublePageZoomMode = PageZoomMode.auto
    @AppStorage("motionBlurEnabled") private var isMotionBlurEnabled = true
    @State private var image: PlatformImage?
    @State private var loadFailed = false
    @State private var imageLoadGeneration = 0
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// Slightly blurs the image in proportion to the drag speed while panning on a zoomed
    /// page — not a permanent aesthetic filter, it disappears at the end of the gesture.
    @State private var motionBlurRadius: CGFloat = 0

    /// "Automatic"/"Fit page" show the whole page (historical behavior, unchanged).
    /// "Fit width" is the only case that changes the layout: it scales to the available
    /// width and, if the result exceeds the screen's height, makes the page scrollable
    /// vertically.
    private var effectiveZoomMode: PageZoomMode {
        let mode = isDoublePage ? doublePageZoomMode : singlePageZoomMode
        #if os(tvOS)
        // "Fit width"'s vertical `ScrollView` can never receive remote focus on tvOS, so a page
        // taller than the screen was cut off with no way to scroll it. tvOS gets the remote
        // zoom/pan instead (Play/Pause in `ReaderContentView.tvOSPager`); the setting is not
        // offered in the tvOS reader settings, and a value synced from another device falls
        // back to the whole page here.
        return mode == .fitWidth ? .fitPage : mode
        #else
        return mode
        #endif
    }

    private var processingSettings: PageProcessingSettings {
        PageProcessingSettings(
            autoCrop: isAutoCropEnabled,
            autoTintContrast: isAutoTintContrastEnabled,
            upscale: isUpscalingEnabled
        )
    }

    var body: some View {
        #if os(macOS)
        pageBody
            .onChange(of: zoomCommand) { _, command in
                // Neighbouring pages kept mounted off-screen see the same command (so becoming
                // the visible page isn't a "change" that replays the last one) but ignore it.
                if let command, isActive { applyZoomCommand(command.kind) }
            }
            // A page that leaves the screen comes back at fit size, as it did when every turn
            // rebuilt it from scratch (see `macPersistentPager`).
            .onChange(of: isActive) { _, active in
                guard !active, scale != 1 || offset != .zero else { return }
                scale = 1
                lastScale = 1
                offset = .zero
                lastOffset = .zero
                motionBlurRadius = 0
            }
        #else
        pageBody
        #endif
    }

    @ViewBuilder
    private var pageBody: some View {
        if let pairedHeight, effectiveZoomMode != .fitWidth {
            pairedContent(height: pairedHeight)
        } else {
            GeometryReader { proxy in
                Group {
                    if let image = displayedImage(targetSize: proxy.size) {
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
                            // SwiftUI's `MagnificationGesture`/`DragGesture`, layered on top of the
                            // scrolling pager (`TabView(.page)`, backed by `UIPageViewController`),
                            // lose the two-finger touch arbitration against its internal scroll
                            // view — pinch and pan stay dead (verified live on device). A real
                            // `UIScrollView` with native zoom (as the Photos app does: pinch/pan are
                            // the system behavior of a zoomable scroll view, not gestures bolted on
                            // top) takes part in UIKit's own gesture coordination protocol instead of
                            // having to reinvent it by hand.
                            ZoomableImageView(image: image, isZoomed: isZoomed, isActive: isActive, tapZoneOptions: tapZoneOptions)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .overlay(tintOverlay)
                            #elseif os(tvOS)
                            // No pinch/drag zoom on tvOS (no `MagnificationGesture`/`DragGesture`,
                            // no touch anyway): just the page, scaled to fit.
                            image.asSwiftUIImage
                                .resizable()
                                .scaledToFit()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .overlay(tintOverlay)
                            #else
                            image.asSwiftUIImage
                                .resizable()
                                .scaledToFit()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .scaleEffect(scale)
                                .offset(offset)
                                .conditionalMotionBlur(radius: motionBlurRadius)
                                .overlay(tintOverlay)
                                .gesture(magnifyGesture)
                                // Active only when zoomed in: at scale 1 it must not intercept the
                                // drag, otherwise it steals the touch from the page swipe underneath
                                // even though it then does nothing (guard scale > 1).
                                .gesture(dragGesture, including: scale > 1 ? .all : .subviews)
                                .onTapGesture(count: 2) { toggleZoom() }
                                .background(zoomedScrollPanMonitor(size: proxy.size))
                            #endif
                        }
                    } else {
                        pageSlot(targetSize: proxy.size) { loadImage(targetSize: proxy.size) }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .onAppear { loadImage(targetSize: proxy.size) }
                .onChange(of: processingSettings) { _, _ in reloadImage(targetSize: proxy.size) }
            }
            .clipped()
        }
    }

    /// Path for a page that touches the other half of the spread: fixed height, width
    /// derived from the image's proportions (no `GeometryReader` imposing a fixed half,
    /// which is the cause of the black gap between pages). Doesn't cover "Fit width", which
    /// stays on the per-page vertical scroll: the two notions don't combine well (one
    /// derives height from width, the other the opposite).
    @ViewBuilder
    private func pairedContent(height: CGFloat) -> some View {
        // 2:3 estimate until the real proportions are known: avoids the placeholder jumping
        // in size when the image arrives.
        let estimatedWidth = height * 2 / 3
        Group {
            if let image = displayedImage(targetSize: CGSize(width: estimatedWidth, height: height)) {
                #if os(iOS)
                // `sizeThatFits` on ZoomableImageView computes the width from the proposed
                // height, the way `Image().scaledToFit()` would — see the comment there.
                //
                // NOTE: on iOS this branch is never actually reached today — `PageSpreadView`
                // always passes `pairedHeight: nil` and hands the spread off to
                // `SpreadPairView`. It stays here only because `PageView` is shared between
                // the two platforms. The old problem of the spinner stuck on one of the two
                // pages was specifically about this path, and therefore remains open only on
                // macOS, where `pairedContent` is still in use (see the `#else` branch).
                ZoomableImageView(image: image, isZoomed: isZoomed, isActive: isActive, widthFollowsHeight: true)
                    .frame(height: height)
                    .overlay(tintOverlay)
                #elseif os(tvOS)
                image.asSwiftUIImage
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
                    .overlay(tintOverlay)
                #else
                image.asSwiftUIImage
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .conditionalMotionBlur(radius: motionBlurRadius)
                    .overlay(tintOverlay)
                    .gesture(magnifyGesture)
                    .gesture(dragGesture, including: scale > 1 ? .all : .subviews)
                    .onTapGesture(count: 2) { toggleZoom() }
                    .background(zoomedScrollPanMonitor(size: CGSize(width: height * image.size.width / max(image.size.height, 1), height: height)))
                #endif
            } else {
                pageSlot(targetSize: CGSize(width: estimatedWidth, height: height)) {
                    loadImage(targetSize: CGSize(width: estimatedWidth, height: height))
                }
                .frame(width: estimatedWidth, height: height)
            }
        }
        .onAppear { loadImage(targetSize: CGSize(width: estimatedWidth, height: height)) }
        .onChange(of: processingSettings) {
            _, _ in reloadImage(targetSize: CGSize(width: estimatedWidth, height: height))
        }
    }

    private func reloadImage(targetSize: CGSize) {
        imageLoadGeneration += 1
        image = nil
        loadFailed = false
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
        loadImage(targetSize: targetSize)
    }

    /// Spinner while loading, "Retry" button if the read failed — instead of a spinner
    /// stuck forever with no trace of the problem (original behavior, verified live). Same
    /// idea as `SpreadPairView.pageSlot`, here for the single-page path.
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

    /// The image to draw: the loaded one or, on macOS, one the prefetch already finished,
    /// read synchronously so a prefetched page appears on the view's very first frame
    /// (before `onAppear`/`loadImage` even run) instead of flashing a spinner.
    private func displayedImage(targetSize: CGSize) -> PlatformImage? {
        if let image { return image }
        #if os(macOS)
        return imageCache?.readyImages.image(at: index, options: processingOptions(targetSize: targetSize))
        #else
        return nil
        #endif
    }

    private func processingOptions(targetSize: CGSize) -> PageImageCache.ProcessingOptions {
        #if os(macOS) || os(iOS)
        let upscaleTarget = upscaleTargetSizeOverride ?? targetSize
        #else
        let upscaleTarget = targetSize
        #endif
        return PageImageCache.ProcessingOptions(
            autoCrop: isAutoCropEnabled,
            autoTintContrast: isAutoTintContrastEnabled,
            upscaleTargetSize: isUpscalingEnabled ? upscaleTarget : nil
        )
    }

    private func loadImage(targetSize: CGSize) {
        guard image == nil else { return }
        let generation = imageLoadGeneration
        let autoCrop = isAutoCropEnabled
        let upscale = isUpscalingEnabled
        let autoTintContrast = isAutoTintContrastEnabled

        if let imageCache {
            // macOS path: the cache is almost always already warm thanks to the prefetch
            // started by `ReaderContentView` when `currentPage` changes — this call returns
            // almost immediately instead of re-decoding from disk.
            let options = processingOptions(targetSize: targetSize)
            #if os(macOS)
            if let ready = imageCache.readyImages.image(at: index, options: options) {
                image = ready
                return
            }
            #endif
            Task {
                let loaded = await imageCache.image(at: index, options: options)
                await MainActor.run {
                    guard generation == imageLoadGeneration else { return }
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
                // Not a plain `try?`: a failure here used to leave the page stuck on the
                // spinner forever, with no trace — verified live with double-page mode (two
                // concurrent reads on the same CBZ/CBR archive, not thread-safe, produced
                // corrupted data; fixed upstream in CBZ/CBRPageProvider, but a log is still
                // useful for any other read failure). With a "Retry" button instead of
                // staying stuck forever — see `pageSlot`.
                DiagnosticLog.log("Lettura pagina \(index) fallita: \((error as NSError).localizedDescription)")
                DispatchQueue.main.async {
                    guard generation == self.imageLoadGeneration else { return }
                    self.loadFailed = true
                }
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
            DispatchQueue.main.async {
                guard generation == self.imageLoadGeneration else { return }
                self.image = loaded
            }
        }
    }

    #if os(macOS)
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
    #endif

    private func syncZoomedState() {
        isZoomed.wrappedValue = scale > 1.01
    }

    #if os(macOS)
    /// Two-finger trackpad scrolling (or the mouse wheel) pans a zoomed page, the way it
    /// scrolls any oversized content on the Mac — click-dragging alone was the only way
    /// before. Mounted only while zoomed: at fit size the same scroll events turn the page
    /// (`ScrollSwipeMonitor`, which ignores them while zoomed). The deltas are applied as-is
    /// (they already follow the user's "natural scrolling" preference) and the offset is
    /// clamped so the page edge never leaves the frame.
    @ViewBuilder
    private func zoomedScrollPanMonitor(size: CGSize) -> some View {
        if scale > 1 {
            ScrollPanMonitor { dx, dy in
                let maxX = max(size.width * (scale - 1) / 2, 0)
                let maxY = max(size.height * (scale - 1) / 2, 0)
                offset = CGSize(
                    width: min(max(offset.width + dx, -maxX), maxX),
                    height: min(max(offset.height + dy, -maxY), maxY)
                )
                lastOffset = offset
            }
        }
    }
    #endif

    #if os(macOS)
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
    #endif

    #if os(macOS)
    /// ⌘+ / ⌘− / ⌘0 from the View menu: same 1…5 range as the pinch.
    private func applyZoomCommand(_ kind: ReaderZoomCommand.Kind) {
        // Only where the pinch zoom itself applies: not in "Fit width" (a plain scroll view,
        // no `scaleEffect` — zooming there would flag `isZoomed` and suspend page turns with
        // nothing visibly zoomed), not before the image exists, and not on the two halves of
        // a spread (each would zoom around its own center and overlap the other).
        guard image != nil, effectiveZoomMode != .fitWidth, pairedHeight == nil else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            switch kind {
            case .zoomIn: scale = min(scale * 1.25, 5)
            case .zoomOut: scale = max(scale / 1.25, 1)
            case .reset: scale = 1
            }
            if scale <= 1.01 {
                scale = 1
                offset = .zero
                lastOffset = .zero
            } else {
                // Keep the current pan inside the new, possibly smaller, overflow.
                offset = CGSize(width: offset.width * scale / max(lastScale, 1), height: offset.height * scale / max(lastScale, 1))
                lastOffset = offset
            }
            lastScale = scale
        }
        syncZoomedState()
    }
    #endif

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
