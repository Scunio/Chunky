import SwiftUI

/// Header chrome (leading "Libreria" action, title, trailing icons) — split out of
/// ReaderView.swift to keep its type_body_length under SwiftLint's limit (same reason
/// ReaderSupportViews.swift/ReaderPageContentViews.swift already exist as companions).
extension ReaderContentView {
    private var findButton: some View {
        Button(action: presentFind) {
            Image(systemName: "text.magnifyingglass")
                .frame(width: 44, height: 44)
        }
    }

    /// Control bars, with the measurement of their height on iOS: needed by the tap zones
    /// so they don't react to touches that fall on the bars (see `PageTapZones.topInset`).
    /// A separate property rather than inline in the `body` because the reader's body is
    /// already at the limit of what the compiler can infer in a reasonable time.
    var controlsChrome: some View {
        VStack {
            #if os(iOS)
            // The footer isn't here: it's a direct `readerContent` sibling instead, in its
            // own `VStack`+`Spacer` (see there) — needs its own `.offset` to clear the
            // safe area, which a `Spacer` inside *this* `VStack` can't give it.
            header
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ChromeHeightKey.self, value: proxy.size.height)
                })
                .onPreferenceChange(ChromeHeightKey.self) { headerHeight = $0 }
            Spacer()
            #elseif os(tvOS)
            // Floating pills, not edge-to-edge bars: the old full-width strips (HIG's 80pt
            // margin on both sides) left a lot of dead background around 2-3 small controls.
            // Real screen-edge margin lives here, outside each pill's own background, so
            // there's visible breathing room instead of the bar touching the edge.
            header
                .padding(.top, 48)
            Spacer()
            footer
                .padding(.bottom, 40)
            #else
            header
            Spacer()
            footer
            #endif
        }
    }

    /// Leading icon group, isolated so its width can be measured (see `header`).
    private var headerLeadingActions: some View {
        HStack(spacing: tvOSHeaderIconSpacing) {
            Button(action: exitReader) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Libreria")
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(minHeight: 44)
                #if os(tvOS)
                // No custom background — see `readerTVIconChip()`.
                .padding(.horizontal, 20)
                #endif
            }
            #if os(tvOS)
            .focusable(readerFocus != .pager)
            // The explicit landing target for `readerFocus = .libreria` — Up from the page
            // lands here deterministically instead of relying on the system's default-focus
            // guess, and this binding keeps `readerFocus` from going `nil` while it's focused.
            .focused($readerFocus, equals: .libreria)
            .onMoveCommand(perform: handleHeaderMoveCommand)
            #endif
            // Crop: opens the panel selection (an area is always selected, there's no
            // separate "share the whole page" button). Not on tvOS: the selection is
            // adjusted by dragging, and there's no drag gesture there (no touch/trackpad).
            #if !os(tvOS)
            Button(action: { isPanelSelectionPresented = true }) {
                Image(systemName: "ellipsis.bubble").frame(width: 44, height: 44)
            }
            #endif
            // Search the pages' text (OCR, or the text layer if the file is a native PDF).
            // On iPhone in compact width the icon doesn't appear here: a third icon on the
            // left would leave the title very little room, so it lives in the "..." menu
            // like the other actions that don't fit there (same choice as
            // `headerTrailingActions`).
            #if os(iOS)
            if horizontalSizeClass != .compact {
                findButton
            }
            #elseif os(macOS)
            findButton
            #endif
            // Not on tvOS: trimmed from the header along with Novità/Ora-in-lettura/Account
            // (see `expandedTrailingActions`) — typing a search query there is blocked by the
            // tvOS on-screen keyboard's lack of a scriptable/reliable D-pad path, so the icon
            // opened a screen the user couldn't do much with. "< Libreria" and the page-layout
            // cycle are the only two kept: a real back action and the only genuine reading
            // control among the six the header used to carry.
        }
    }

    /// Wraps non-button content (the title, the page count) in its own capsule pill, so it
    /// floats separately the same way a button does. NOT for `Button`s themselves:
    /// `.buttonStyle(.automatic)` already draws its own resting-state pill on a focusable
    /// icon button — adding this on top of one produces two visibly nested shapes (confirmed
    /// live, see the "appear in two circles" note this replaced, and the identical lesson
    /// already on record in tvOS-design-patterns.md). Buttons just get sized with `.frame(...)`
    /// and left to the system's own background.
    #if os(tvOS)
    /// Stronger than the shared iOS/macOS `chromeBackground`: that's tuned for a bar spanning
    /// the whole screen width, but a small floating pill sitting directly on the page (no
    /// surrounding chrome to separate it visually) needs more contrast to still read as
    /// "chrome" instead of blending into a dark comic canvas — confirmed live, the
    /// systemGray6-derived `chromeBackground` on a black page read as barely distinct from
    /// the page itself. A thin stroke on top gives the pill a defined edge even where the fill
    /// alone comes close to the page tone.
    private var tvOSPillBackground: Color {
        isBackgroundDark ? Color.black.opacity(0.75) : Color.white.opacity(0.9)
    }

    func tvOSFloatingPill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Capsule().fill(tvOSPillBackground))
            .overlay(Capsule().strokeBorder(chromeForeground.opacity(0.22), lineWidth: 1))
    }
    #endif

    private var header: some View {
        #if os(tvOS)
        HStack {
            headerLeadingActions
            Spacer()
            // Smaller/more subdued than the Libreria/layout buttons either side: while
            // reading, the title is the least useful piece of chrome on screen (the user
            // already knows what they opened) — sized down so it reads as a secondary label
            // instead of competing for attention with the two real controls flanking it.
            tvOSFloatingPill {
                Text(comic.title ?? "")
                    .font(.subheadline)
                    .foregroundColor(chromeForeground.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer()
            // `headerTrailingActions` (→ `expandedTrailingActions`) renders empty when the
            // layout-cycle icon isn't shown (`isDoublePageAllowed == false`) — nothing to
            // reserve space for in that case. The two `Spacer()`s still split evenly around
            // the title either way.
            if isDoublePageAllowed {
                headerTrailingActions
            }
        }
        .foregroundColor(chromeForeground)
        .environment(\.colorScheme, isBackgroundDark ? .dark : .light)
        .buttonStyle(.automatic)
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity)
        .transition(.move(edge: .top).combined(with: .opacity))
        #else
        HStack(spacing: 4) {
            headerLeadingActions
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: HeaderLeadingWidthKey.self, value: proxy.size.width)
                })
                // Reserves the wider group's width on both flanks (see
                // `HeaderLeadingWidthKey`), so the title below lands on the bar's true
                // center instead of the midpoint between two differently-sized groups.
                .frame(minWidth: max(headerLeadingWidth, headerTrailingWidth), alignment: .leading)
            Spacer(minLength: 4)
            // Comic info (go-to-page/favorites/reading direction): long press on the
            // title, so as not to add another icon to the header. Dropdown Menus with
            // interactive content are unreliable on this target (see ToolsPanelView).
            Text(comic.title ?? "")
                .font(.subheadline.bold())
                .lineLimit(1)
                .onLongPressGesture { isInfoPresented = true }
            Spacer(minLength: 4)
            headerTrailingActions
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: HeaderTrailingWidthKey.self, value: proxy.size.width)
                })
                .frame(minWidth: max(headerLeadingWidth, headerTrailingWidth), alignment: .trailing)
        }
        .onPreferenceChange(HeaderLeadingWidthKey.self) { headerLeadingWidth = $0 }
        .onPreferenceChange(HeaderTrailingWidthKey.self) { headerTrailingWidth = $0 }
        .foregroundColor(chromeForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        // The host reports no safe area (see `StatusBarControllingHost`), so the inset that
        // keeps the buttons and title clear of the status bar has to be added here. Inside the
        // padding, so the background still reaches the true top edge instead of leaving a gap
        // of bare page above it. Mac has no status bar and no such host.
        #if os(iOS)
        .padding(.top, PlatformSafeArea.statusBarHeight)
        #endif
        .frame(maxWidth: .infinity)
        .background(chromeBackground)
        // The system material follows the current scheme: here we force the one consistent
        // with "Page background" (black/white/auto), as chromeForeground already does for
        // text/icons.
        .environment(\.colorScheme, isBackgroundDark ? .dark : .light)
        .buttonStyle(PlainButtonStyle())
        .transition(.move(edge: .top).combined(with: .opacity))
        #endif
    }

    /// The header's 4 trailing icons when there's room to show them individually (iPad,
    /// Mac, iPhone in landscape) — shared by both branches of `headerTrailingActions`.
    ///
    /// An `HStack`, not a `Group`: `header` wraps this in `.frame(minWidth:alignment:)` to
    /// reserve the wider of the two icon groups' width and keep the title centered (see
    /// `HeaderLeadingWidthKey`) — a `Group`'s children are spliced directly into the parent
    /// `HStack` instead of staying together as one view, so that `.frame` modifier ended up
    /// applied to each icon *individually*, inflating each one to that width on its own and
    /// spreading them apart with large gaps instead of keeping them clustered together.
    private var expandedTrailingActions: some View {
        HStack(spacing: tvOSHeaderIconSpacing) {
            // Not on tvOS: Novità/Ora-in-lettura/Account all duplicate a destination already
            // reachable from the tab bar (see `headerLeadingActions`'s note on trimming search
            // for the same reason) — the header is left with just the page-layout cycle below.
            #if !os(tvOS)
            newComicsButton
            nowReadingButton
            Button(action: { isAccountsPresented = true }) {
                Image(systemName: "cloud")
                    .frame(width: 44, height: 44)
            }
            #endif
            // Moved up from the footer on tvOS (see `footer`): the footer there has no
            // interactive controls left, only an informational page label and progress bar.
            #if os(tvOS)
            if isDoublePageAllowed {
                Button(action: cyclePageLayoutMode) {
                    Image(systemName: pageLayoutModeIconName).readerTVIconChip()
                }
                .focusable(readerFocus != .pager)
                .focused($readerFocus, equals: .layout)
                .onMoveCommand(perform: handleHeaderMoveCommand)
            }
            #endif
            // Tools opens Settings/Parental Lock/Colors, none of which exist on tvOS in v1.
            #if !os(tvOS)
            Button(action: { isToolsPresented = true }) {
                Image(systemName: "wrench.and.screwdriver").frame(width: 44, height: 44)
            }
            #endif
        }
    }

    /// tvOS-only: icons need more room between them at Infuse-style chip size than the
    /// 2pt iOS/macOS uses for its small unstyled 44pt icons.
    private var tvOSHeaderIconSpacing: CGFloat {
        #if os(tvOS)
        16
        #else
        2
        #endif
    }

    /// On iPhone (compact width) the header's 4 trailing icons don't fit comfortably: we
    /// gather them into a single "..." menu. The reader doesn't live in a NavigationStack
    /// (see header/chromeBackground above), so there's no real system toolbar here that
    /// collapses on its own: the trigger is manual, based on horizontalSizeClass. On
    /// iPad/Mac the individual icons remain, unchanged.
    @ViewBuilder
    private var headerTrailingActions: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            Menu {
                Button(action: presentFind) {
                    Label("Cerca nel testo", systemImage: "text.magnifyingglass")
                }
                Button(action: { isNewComicsPresented = true }) {
                    Label("Nuovi fumetti", systemImage: "envelope")
                }
                if lastReadComic != nil {
                    Button(action: { isNowReadingPresented = true }) {
                        Label("Ora in lettura", systemImage: "book")
                    }
                }
                Button(action: { isAccountsPresented = true }) {
                    Label("Account", systemImage: "cloud")
                }
                Button(action: { isToolsPresented = true }) {
                    Label("Strumenti", systemImage: "wrench.and.screwdriver")
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
            }
            .platformPopover(isPresented: $isNewComicsPresented) {
                NewComicsView(comics: recentComics) {
                    isNewComicsPresented = false
                    if $0 != comic { onSwitchComic($0) }
                } onClear: {
                    newTrayClearedAtTimestamp = Date().timeIntervalSince1970
                    isNewComicsPresented = false
                }
            }
            .platformPopover(isPresented: $isNowReadingPresented) {
                if let lastRead = lastReadComic {
                    NowReadingView(comic: lastRead) {
                        isNowReadingPresented = false
                        if lastRead != comic { onSwitchComic(lastRead) }
                    }
                }
            }
        } else {
            expandedTrailingActions
        }
        #else
        expandedTrailingActions
        #endif
    }

    /// Comics imported in the last 7 days, as in the library (same "Clear" key shared via
    /// @AppStorage). Empty if the reader is opened without a library context.
    private var recentComics: [ComicEntity] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let clearedAt = Date(timeIntervalSince1970: newTrayClearedAtTimestamp)
        let effectiveCutoff = max(cutoff, clearedAt)
        return libraryComics
            .filter { ($0.dateAdded ?? .distantPast) > effectiveCutoff }
            .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
    }

    private var newComicsButton: some View {
        Button(action: { isNewComicsPresented = true }) {
            Image(systemName: "envelope")
                .frame(width: 44, height: 44)
        }
        .platformPopover(isPresented: $isNewComicsPresented) {
            NewComicsView(comics: recentComics) {
                isNewComicsPresented = false
                if $0 != comic { onSwitchComic($0) }
            } onClear: {
                newTrayClearedAtTimestamp = Date().timeIntervalSince1970
                isNewComicsPresented = false
            }
        }
    }

    /// The most recently opened comic in the library, as in the button of the same name there.
    private var lastReadComic: ComicEntity? {
        libraryComics
            .filter { $0.dateLastOpened != nil }
            .max { ($0.dateLastOpened ?? .distantPast) < ($1.dateLastOpened ?? .distantPast) }
    }

    @ViewBuilder
    private var nowReadingButton: some View {
        if let lastRead = lastReadComic {
            Button(action: { isNowReadingPresented = true }) {
                Image(systemName: "book")
                    .frame(width: 44, height: 44)
            }
            .platformPopover(isPresented: $isNowReadingPresented) {
                NowReadingView(comic: lastRead) {
                    isNowReadingPresented = false
                    if lastRead != comic { onSwitchComic(lastRead) }
                }
            }
        }
    }
}
