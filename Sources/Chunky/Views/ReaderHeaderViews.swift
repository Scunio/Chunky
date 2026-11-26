import SwiftUI

/// Header chrome (leading "Libreria" action, title, trailing icons) — split out of
/// ReaderView.swift to keep its type_body_length under SwiftLint's limit (same reason
/// ReaderSupportViews.swift/ReaderPageContentViews.swift already exist as companions).
extension ReaderContentView {
    #if os(tvOS)
    /// tvOS: a `.sheet` here makes the whole reader disappear/reappear and the sheet vanishes right away, so the info
    /// panel is an overlay like the other reader cards. Its first focusable item ("Chiudi") takes focus by default.
    var tvInfoOverlay: some View {
        ComicInfoSheet(
            comic: comic,
            loadedPageCount: provider?.pageCount,
            onJumpToPage: {
                jumpPageNumber = currentPage + 1
                isPageJumpPresented = true
                readerFocus = .dialogCancel
            },
            onToggleFavorite: toggleFavorite,
            onToggleReadingDirection: toggleReadingDirection,
            onClose: closeInfoOverlay
        )
        .background(readerCardBackground)
        .cornerRadius(24)
        .onExitCommand(perform: closeInfoOverlay)
    }

    func closeInfoOverlay() {
        isInfoPresented = false
        readerFocus = isPageJumpPresented ? .dialogCancel : .info
    }
    #endif

    var readerCardBackground: Color {
        #if os(tvOS)
        Color(white: 0.1)
        #else
        Color.black.opacity(0.85)
        #endif
    }

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
            // Mac: no in-content header. The reader is its own window, so the title bar
            // already names the comic and the header's actions live in the window toolbar
            // (`macReaderToolbar`) — a second bar under the title bar was double chrome. What's
            // left is the page counter/slider as a floating HUD over the bottom of the page,
            // like QuickTime's controls: it never takes layout space, so showing or hiding it
            // (click in the middle, or the pointer going idle) doesn't resize the page.
            Spacer()
            footer
                .onHover { isPointerOverMacFooter = $0 }
                // Removed from under the pointer (⌘F, panel selection): no hover-exit arrives,
                // and a stuck flag would disable the auto-hide for this window.
                .onDisappear { isPointerOverMacFooter = false }
            #endif
        }
    }

    #if os(macOS)
    /// The reader header's actions as native window-toolbar items (each a `Label`, so the
    /// overflow menu of a narrow window and "Customize Toolbar" have text for them). The title
    /// is the window's own (`navigationTitle`), so the old click-on-title for comic info
    /// becomes the Info item (⌘I).
    @ToolbarContentBuilder
    var macReaderToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { isPanelSelectionPresented = true }) {
                Label("Condividi vignetta", systemImage: "ellipsis.bubble")
            }
            .help("Condividi vignetta")
            .disabled(provider == nil)
            Button(action: presentFind) {
                Label("Cerca nel testo", systemImage: "text.magnifyingglass")
            }
            .help("Cerca nel testo")
            .disabled(provider == nil)
            Button(action: { isInfoPresented = true }) {
                Label("Info fumetto", systemImage: "info.circle")
            }
            .help("Info fumetto")
            .keyboardShortcut("i", modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { isNewComicsPresented = true }) {
                Label("Nuovi fumetti", systemImage: "envelope")
            }
            .help("Novità")
            .popover(isPresented: $isNewComicsPresented, arrowEdge: .bottom) {
                NewComicsView(comics: recentComics) {
                    isNewComicsPresented = false
                    if $0 != comic { onSwitchComic($0) }
                } onClear: {
                    newTrayClearedAtTimestamp = Date().timeIntervalSince1970
                    isNewComicsPresented = false
                }
            }
            if let lastRead = lastReadComic {
                Button(action: { isNowReadingPresented = true }) {
                    Label("Ora in lettura", systemImage: "book")
                }
                .help("Ora in lettura")
                .popover(isPresented: $isNowReadingPresented, arrowEdge: .bottom) {
                    NowReadingView(comic: lastRead) {
                        isNowReadingPresented = false
                        if lastRead != comic { onSwitchComic(lastRead) }
                    }
                }
            }
            Button(action: { isAccountsPresented = true }) {
                Label("Account", systemImage: "cloud")
            }
            .help("Account")
            Button(action: openTools) {
                Label("Strumenti", systemImage: "wrench.and.screwdriver")
            }
            .help("Strumenti")
        }
    }
    #endif

    /// Leading icon group, isolated so its width can be measured (see `header`).
    private var headerLeadingActions: some View {
        HStack(spacing: tvOSHeaderIconSpacing) {
            // Not on the Mac: the reader is its own window, closed with ⌘W / the title bar's
            // close button — a "‹ Libreria" back button there just duplicated the window chrome.
            #if !os(macOS)
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
            // The explicit landing target for `readerFocus = .libreria` — Up from the page
            // lands here deterministically instead of relying on the system's default-focus
            // guess, and this binding keeps `readerFocus` from going `nil` while it's focused.
            .focused($readerFocus, equals: .libreria)
            .onMoveCommand(perform: handleHeaderMoveCommand)
            #endif
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
            // Always present now: besides the (conditional) layout-cycle icon it carries the
            // info/actions button, the only remote-reachable entry to `ComicInfoSheet`.
            headerTrailingActions
        }
        // No `.foregroundColor(chromeForeground)` on the whole row: forced on the `Button`s it
        // also overrode `.automatic`'s own focused-state text color, leaving white text on
        // the light focused pill ("‹ Libreria" unreadable once focused). The buttons take
        // their resting color from the forced `colorScheme` below; the title pill sets its own.
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
                // The long press is invisible to VoiceOver: expose it as the default action.
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("Info fumetto"))
                .accessibilityAction { isInfoPresented = true }
                #if os(macOS)
                // A long press is a touch gesture nobody tries with a mouse: a plain click
                // opens the info too.
                .onTapGesture { isInfoPresented = true }
                #endif
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
        #if os(iOS)
        // Landscape iPhone: clear of the notch / Dynamic Island and the rounded corners
        // (the host reports no safe area — see `PlatformSafeArea.leftInset`).
        .padding(.leading, PlatformSafeArea.leftInset)
        .padding(.trailing, PlatformSafeArea.rightInset)
        #endif
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
            // Info/actions: the remote-reachable replacement for the iOS/macOS long-press on
            // the title (the title isn't focusable on tvOS) — opens `ComicInfoSheet`, which
            // hosts "Vai a pagina", favorites and reading direction. No `.focusable` here: on a
            // `Button` it wraps it in an action-less focus item that swallows Select.
            Button(action: { isInfoPresented = true }) {
                Image(systemName: "info.circle").readerTVIconChip()
            }
            .focused($readerFocus, equals: .info)
            .onMoveCommand(perform: handleHeaderMoveCommand)
            .accessibilityLabel(Text("Info fumetto"))
            if isDoublePageAllowed {
                Button(action: cyclePageLayoutMode) {
                    Image(systemName: pageLayoutModeIconName).readerTVIconChip()
                }
                .focused($readerFocus, equals: .layout)
                .onMoveCommand(perform: handleHeaderMoveCommand)
                .accessibilityLabel(Text("Layout pagine"))
                .accessibilityValue(Text(pageLayoutModeAccessibilityValue))
            }
            #endif
            // Tools opens Settings/Parental Lock/Colors, none of which exist on tvOS in v1.
            #if !os(tvOS)
            Button(action: openTools) {
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
                Button(action: openTools) {
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
