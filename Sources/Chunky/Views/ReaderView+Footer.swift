import SwiftUI

/// Footer chrome (page counter, slider, layout-mode button) and the iCloud download
/// overlay. Split out of ReaderView.swift to keep `ReaderContentView`'s body under
/// SwiftLint's `type_body_length`.
extension ReaderContentView {
    var footer: some View {
        Group {
            if let provider = provider, provider.pageCount > 1 {
                // Real end of the current spread, i.e. the start of the next one: `pageStep`
                // is 2 for double page throughout, but with "cover alone" the first spread
                // contains just one, and the label used to announce "1–2" while only the
                // cover was on screen. Same thing for the last page of a comic with an odd
                // page count.
                let upperBound = spreadStarts(pageCount: provider.pageCount)
                    .first(where: { $0 > currentPage }) ?? provider.pageCount
                let label = upperBound - currentPage > 1
                    ? "\(currentPage + 1)–\(upperBound) / \(provider.pageCount)"
                    : "\(currentPage + 1) / \(provider.pageCount)"
                #if os(tvOS)
                // Just the page count, as its own floating pill: the slider next to it used
                // to just be a progress decoration — there's no drag gesture on tvOS (no
                // touch/trackpad to scrub with), so it was never actually usable, only ever
                // reflecting the same number this label already says.
                tvOSFloatingPill {
                    Text(label)
                        .font(.title3.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundColor(chromeForeground)
                .environment(\.colorScheme, isBackgroundDark ? .dark : .light)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                #else
                // Column width computed on the worst case ("100–101 / 164"), not on the
                // current label: fixed avoids the slider jumping on every page, but it must
                // grow with the digit count and with double page, otherwise the label wraps.
                let digits = String(provider.pageCount).count
                let labelChars = effectiveDoublePage ? digits * 3 + 4 : digits * 2 + 3
                // Scaled with Dynamic Type: at accessibility sizes the fixed 7pt/char estimate
                // clipped the label (it's `.fixedSize`, so it overflowed onto the slider).
                let labelWidth = max(pageCounterMinWidth, CGFloat(labelChars) * pageCounterCharWidth + 8)
                HStack(spacing: 4) {
                    // Fixed-width column: the page number's width varies (e.g. "1 / 20" vs
                    // "10–11 / 20") and without pre-allocating the space, the slider next to
                    // it would shift every time the page changes.
                    //
                    // The whole column is one tap target, not just the chevron: swaps which
                    // half (top/bottom) advances/goes back in one-handed mode. A `Button`
                    // wrapping both, not a separate one on just the small icon — the label
                    // alone was an easy-to-miss target compared to the rest of the bar.
                    #if os(macOS)
                    // On the Mac the counter opens "Go to page" instead: one-handed mode
                    // (whose side the chevron used to flip) is a thumb affordance with no
                    // meaning for a pointer, and the reader ignores it here.
                    Button(action: {
                        jumpPageNumber = currentPage + 1
                        isPageJumpPresented = true
                    }) {
                        Text(label)
                            .font(.callout.monospacedDigit())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .frame(width: labelWidth, height: 32)
                    .accessibilityHint(Text("Vai a pagina"))
                    #else
                    Button(action: { isOneHandedZonesReversed.toggle() }) {
                        VStack(spacing: 2) {
                            Text(label)
                                .font(.callout.monospacedDigit())
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .rotationEffect(.degrees(isOneHandedZonesReversed ? 180 : 0))
                        }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .frame(width: labelWidth, height: 44)
                    .accessibilityLabel(Text("Pagina \(currentPage + 1) di \(provider.pageCount)"))
                    #endif
                    pageSlider(provider: provider)
                    if isDoublePageAllowed {
                        // Cycles single → double → automatic page.
                        Button(action: cyclePageLayoutMode) {
                            Image(systemName: pageLayoutModeIconName)
                                .font(.footnote.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(chromeForeground.opacity(0.7), lineWidth: 1)
                                        .frame(width: 26, height: 20)
                                )
                        }
                        .accessibilityLabel(Text("Layout pagine"))
                        .accessibilityValue(Text(pageLayoutModeAccessibilityValue))
                    }
                }
                .foregroundColor(chromeForeground)
                .padding(.horizontal, 10)
                #if os(iOS)
                // Same landscape insets as the header (see `PlatformSafeArea.leftInset`).
                .padding(.leading, PlatformSafeArea.leftInset)
                .padding(.trailing, PlatformSafeArea.rightInset)
                // Extra padding, equal to the home indicator's height, keeps the content clear
                // of it while the background reaches the true bottom edge; split top/bottom on iPad,
                // where piling it all on the bottom left the content visibly off-center
                // (iPhone's smaller inset didn't show that, so it keeps the old padding).
                .padding(.top, 4 + (UIDevice.current.userInterfaceIdiom == .pad ? PlatformSafeArea.bottomInset / 2 : 0))
                .padding(.bottom, 4 + (UIDevice.current.userInterfaceIdiom == .pad ? PlatformSafeArea.bottomInset / 2 : PlatformSafeArea.bottomInset))
                .frame(maxWidth: .infinity)
                .background(chromeBackground)
                #elseif os(macOS)
                // Floating HUD over the page (see `controlsChrome`), not an edge-to-edge bar.
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .frame(maxWidth: 620)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(chromeBackground.opacity(0.94))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(chromeForeground.opacity(0.12), lineWidth: 1)
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                #else
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(chromeBackground)
                #endif
                #if os(iOS)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ChromeFooterHeightKey.self, value: proxy.size.height)
                })
                .onPreferenceChange(ChromeFooterHeightKey.self) { footerHeight = $0 }
                #endif
                .environment(\.colorScheme, isBackgroundDark ? .dark : .light)
                .buttonStyle(PlainButtonStyle())
                .transition(.move(edge: .bottom).combined(with: .opacity))
                #endif
            }
        }
    }

    /// VoiceOver value for the tvOS layout-cycle button (the icon alone says nothing).
    var pageLayoutModeAccessibilityValue: LocalizedStringKey {
        if isDoublePageAutoMode { return "Automatico" }
        return isDoublePageEnabled ? "Doppia pagina" : "Pagina singola"
    }

    var pageLayoutModeIconName: String {
        if isDoublePageAutoMode { return "a.square" }
        return isDoublePageEnabled ? "square.split.2x1" : "square"
    }

    func cyclePageLayoutMode() {
        if isDoublePageAutoMode {
            isDoublePageAutoMode = false
            isDoublePageEnabled = false
        } else if !isDoublePageEnabled {
            isDoublePageEnabled = true
        } else {
            isDoublePageAutoMode = true
        }
    }

    private func pageSlider(provider: ComicPageProvider) -> some View {
        let maxValue = Double(max(provider.pageCount - 1, 0))
        let isRTL = comic.readingDirection == .rightToLeft
        // We don't use the system Slider: overlaid on TabView(.page), its internal pan
        // gesture loses the arbitration against the page's scroll gesture (the page turns
        // instead of dragging the thumb — verified live, the thumb stays still while the
        // pager shows the swipe indicators). A high-priority DragGesture always wins over
        // the underlying swipe gesture.
        return GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = maxValue > 0 ? CGFloat(currentPage) / CGFloat(maxValue) : 0
            let thumbX = isRTL ? width * (1 - progress) : width * progress

            ZStack(alignment: .leading) {
                Capsule().fill(chromeForeground.opacity(0.25))
                Capsule().fill(chromeForeground).frame(width: width * progress)
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity, alignment: .center)

            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .shadow(radius: 1)
                .position(x: thumbX, y: proxy.size.height / 2)
                .allowsHitTesting(false)

            // `DragGesture` doesn't exist on tvOS (no direct-touch scrubbing with the Siri
            // Remote): the slider there is a plain progress indicator, and page navigation
            // happens via `.onMoveCommand` in `tvOSPager` instead.
            #if !os(tvOS)
            Color.clear
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard maxValue > 0 else { return }
                            let fraction = min(max(value.location.x / width, 0), 1)
                            let target = Int((Double(isRTL ? 1 - fraction : fraction) * maxValue).rounded())
                            let starts = spreadStarts(pageCount: provider.pageCount)
                            // Dragging the thumb crosses many pages in a row: animating
                            // them one by one would be slow and jerky.
                            turnStyle = .immediate
                            currentPage = starts.min(by: { abs($0 - target) < abs($1 - target) }) ?? 0
                        }
                )
            #endif
        }
        .frame(height: 24)
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
        // A custom drawing, not a `Slider`: without this VoiceOver saw nothing to adjust.
        // Swipe up/down moves one spread in reading order.
        .accessibilityElement()
        .accessibilityLabel(Text("Pagina"))
        .accessibilityValue(Text("Pagina \(currentPage + 1) di \(provider.pageCount)"))
        .accessibilityAdjustableAction { direction in
            let starts = spreadStarts(pageCount: provider.pageCount)
            let target: Int?
            switch direction {
            case .increment: target = starts.first(where: { $0 > currentPage })
            case .decrement: target = starts.last(where: { $0 < currentPage })
            @unknown default: target = nil
            }
            guard let target else { return }
            turnStyle = .immediate
            currentPage = target
        }
    }

    /// Shown while the comic is being downloaded from iCloud: real percentage and the
    /// ability to cancel without having to go through the Downloads screen.
    @ViewBuilder
    func downloadOverlay(progress: Double) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.largeTitle)
                .foregroundColor(chromeForeground)
            Text(comic.title ?? AppLocalization.localizedString("Fumetto", comment: "Fallback comic title"))
                .foregroundColor(chromeForeground)
                .multilineTextAlignment(.center)
            ProgressView(value: progress)
                .frame(maxWidth: 240)
            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundColor(chromeForeground.opacity(0.7))
            Button(action: { downloadItem?.cancel() }) {
                Text("Annulla")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.25))
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 32)
    }
}
