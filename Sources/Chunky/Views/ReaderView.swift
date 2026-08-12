import SwiftUI
import CoreData
#if os(macOS)
import AppKit
#endif

/// Wrapper che possiede "quale fumetto è attivo": passare a quello successivo ricrea
/// ReaderContentView con un'identità (.id) diversa, cosa che un @ObservedObject non può
/// fare da solo (non è legale riassegnarlo da dentro una action closure).
struct ReaderView: View {
    let comic: ComicEntity
    var libraryComics: [ComicEntity] = []
    @State private var activeComic: ComicEntity

    init(comic: ComicEntity, libraryComics: [ComicEntity] = []) {
        self.comic = comic
        self.libraryComics = libraryComics
        _activeComic = State(initialValue: comic)
    }

    var body: some View {
        ReaderContentView(comic: activeComic, libraryComics: libraryComics) { next in
            activeComic = next
        }
        .id(activeComic.objectID)
    }
}

private struct ReaderContentView: View {
    @ObservedObject var comic: ComicEntity
    /// Elenco (nello stesso ordine mostrato in libreria) usato per proporre "il prossimo fumetto"
    /// una volta finita la lettura. Vuoto se il reader è aperto senza contesto di libreria.
    var libraryComics: [ComicEntity] = []
    let onSwitchComic: (ComicEntity) -> Void
    @Environment(\.managedObjectContext) private var context
    @Environment(\.presentationMode) private var presentationMode
    /// Scelta esplicita singola/doppia pagina, valida solo quando non si è in modalità automatica.
    @AppStorage("doublePageMode") private var isDoublePageEnabled = false
    /// In automatico, la doppia pagina segue semplicemente lo spazio disponibile (isDoublePageAllowed).
    @AppStorage("doublePageAutoMode") private var isDoublePageAutoMode = true
    @AppStorage("tapPageTurnStyle") private var tapPageTurnStyle = TapPageTurnStyle.slide
    @AppStorage("swipePageTurnStyle") private var swipePageTurnStyle = TapPageTurnStyle.slide
    @AppStorage("oneHandedMode") private var isOneHandedModeEnabled = false
    @AppStorage("oneHandedZonesReversed") private var isOneHandedZonesReversed = false
    @AppStorage("hotCornersEnabled") private var isHotCornersEnabled = false
    @AppStorage("tapToPanEnabled") private var isTapToPanEnabled = false
    @AppStorage("twoFingerBrightnessEnabled") private var isTwoFingerBrightnessEnabled = true
    @AppStorage("readerIdleResetSeconds") private var readerIdleReset = ReaderIdleResetOption.never
    @State private var idleResetWorkItem: DispatchWorkItem?
    /// Sollevato da PageView (via binding) così il pager sa se la pagina corrente è ingrandita:
    /// con lo zoom attivo lo swipe-per-cambiare-pagina va sospeso, altrimenti confligge col
    /// trascinamento usato per spostarsi dentro la pagina ingrandita.
    @State private var isZoomed = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Dimensioni del viewport, per capire se c'è davvero spazio orizzontale per la doppia
    /// pagina: su iPad la size class resta "regular" anche in verticale, quindi da sola non
    /// basta a evitare lo spreco di spazio (due pagine strette con bande nere sopra/sotto).
    @State private var viewportSize: CGSize = .zero
    @State private var provider: ComicPageProvider?
    /// Indice della pagina "principale" (la prima, più a sinistra in LTR) dello spread corrente.
    @State private var currentPage: Int = 0
    @State private var loadError: String?
    @State private var isControlsVisible = true
    @State private var isSharePresented = false
    @State private var shareImage: PlatformImage?
    @State private var pendingNextComic: ComicEntity?
    @State private var isPanelSelectionPresented = false
    @State private var isPageJumpPresented = false
    @State private var jumpPageNumber = 1
    @State private var isInfoPresented = false
    @State private var isToolsPresented = false
    @State private var isAccountsPresented = false
    @State private var isNewComicsPresented = false
    @State private var isNowReadingPresented = false
    @AppStorage("newTrayClearedAt") private var newTrayClearedAtTimestamp: Double = 0
    @AppStorage("pageBackground") private var pageBackgroundRawValue = PageBackground.black.rawValue
    @Environment(\.colorScheme) private var colorScheme

    /// Due pagine verticali affiancate su uno schermo stretto lasciano un vuoto enorme sopra e
    /// sotto (l'immagine combinata è troppo larga rispetto all'altezza disponibile): la doppia
    /// pagina ha senso solo con più spazio orizzontale che verticale. La size class da sola non
    /// basta su iPad, dove resta "regular" anche in verticale.
    private var isDoublePageAllowed: Bool {
        #if os(iOS)
        guard horizontalSizeClass == .regular else { return false }
        guard viewportSize.width > 0, viewportSize.height > 0 else { return true }
        return viewportSize.width > viewportSize.height
        #else
        true
        #endif
    }

    /// Doppia pagina effettiva: in automatico segue lo spazio disponibile, altrimenti la scelta manuale.
    private var effectiveDoublePage: Bool {
        isDoublePageAutoMode ? isDoublePageAllowed : (isDoublePageEnabled && isDoublePageAllowed)
    }

    private var pageStep: Int { effectiveDoublePage ? 2 : 1 }

    /// Indici di inizio di ogni spread (1 o 2 pagine), usati come "tag"/passi di navigazione.
    private func spreadStarts(pageCount: Int) -> [Int] {
        Array(stride(from: 0, to: pageCount, by: pageStep))
    }

    // Cambiando il passo di pagina, l'indice corrente potrebbe non essere più un
    // inizio-spread valido (es. da pagina pari a passo 2): lo riallineiamo, altrimenti
    // il tag del TabView non trova corrispondenza e mostra la pagina sbagliata.
    private func realignCurrentPageToSpreadStart() {
        guard let provider = provider else { return }
        let starts = spreadStarts(pageCount: provider.pageCount)
        currentPage = starts.last(where: { $0 <= currentPage }) ?? 0
    }

    private var readerBackground: Color {
        switch PageBackground(rawValue: pageBackgroundRawValue) ?? .black {
        case .black: return .black
        case .white: return .white
        case .automatic: return colorScheme == .dark ? .black : .white
        }
    }

    private var isBackgroundDark: Bool {
        switch PageBackground(rawValue: pageBackgroundRawValue) ?? .black {
        case .black: return true
        case .white: return false
        case .automatic: return colorScheme == .dark
        }
    }

    /// L'header/footer/menu del reader erano pensati per uno sfondo sempre nero (testo/icone
    /// bianche su pillole scure): con "Sfondo pagina" ora selezionabile anche bianco, questi
    /// colori devono adattarsi o diventano illeggibili (bianco su bianco).
    private var chromeForeground: Color { isBackgroundDark ? .white : .black }

    /// Materiale traslucido di sistema, come il `.toolbar` nativo di Libreria: il deployment
    /// target dell'app (iOS 14) è precedente a `Material`, quindi su iOS 14 resta il vecchio
    /// riempimento a tinta piena.
    @ViewBuilder
    private var chromeBackground: some View {
        if #available(iOS 15.0, macOS 12.0, *) {
            Rectangle().fill(.bar)
        } else {
            Rectangle().fill(isBackgroundDark ? Color(white: 88.0 / 255.0) : Color(white: 0.93))
        }
    }

    var body: some View {
        ZStack {
            readerBackground.ignoresSafeArea()

            // Ignora la safe area anche qui: altrimenti la dimensione misurata cambia insieme
            // alla status bar quando i controlli vengono mostrati/nascosti, facendo scattare
            // inutilmente effectiveDoublePage e spostando/ridimensionando la pagina.
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportSize = proxy.size }
                    .onChange(of: proxy.size) { viewportSize = $0 }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if let provider = provider {
                #if os(iOS)
                // Ignora la safe area: altrimenti, quando la status bar appare/scompare al
                // mostrare/nascondere i controlli, la safe area cambia e la pagina viene
                // ridimensionata/spostata invece di restare ferma sotto ai controlli.
                iOSPager(provider: provider).ignoresSafeArea()
                #else
                macOSPager(provider: provider)
                #endif
            } else if let loadError = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.yellow)
                    Text(loadError)
                        .foregroundColor(chromeForeground)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else {
                ProgressView().accentColor(chromeForeground)
            }

            #if os(iOS)
            if isTwoFingerBrightnessEnabled {
                TwoFingerBrightnessView { delta in
                    UIScreen.main.brightness = min(max(UIScreen.main.brightness + delta, 0), 1)
                }
            }
            #endif

            if isControlsVisible && !isPanelSelectionPresented {
                VStack {
                    header
                    Spacer()
                    footer
                }
                .allowsHitTesting(true)

                // Suggeriscono dove sono le zone di tap per cambiare pagina (altrimenti
                // completamente invisibili): non intercettano tocchi, sono solo un indizio visivo.
                if tapPageTurnStyle != .disabled && !isOneHandedModeEnabled {
                    HStack {
                        Image(systemName: "arrowtriangle.left")
                        Spacer()
                        Image(systemName: "arrowtriangle.right")
                    }
                    .font(.title2)
                    .foregroundColor(chromeForeground.opacity(0.35))
                    .padding(.horizontal, 14)
                    .allowsHitTesting(false)
                }
            }

            if let next = pendingNextComic {
                nextComicConfirmation(next)
            }

            if isPageJumpPresented, let provider = provider {
                pageJumpCard(provider: provider)
            }

            // Sovrapposta direttamente alla pagina già visibile (non un'altra schermata/sheet),
            // come nell'app originale: si vede ancora la pagina sotto, non un fumetto ricaricato
            // a sé stante.
            if isPanelSelectionPresented, let provider = provider {
                PanelSelectionView(pageIndex: currentPage, provider: provider) { cropped in
                    isPanelSelectionPresented = false
                    presentShareImage(cropped)
                } onCancel: {
                    isPanelSelectionPresented = false
                }
            }
        }
        #if os(iOS)
        // Su iPad uno swipe orizzontale che parte vicino al bordo inferiore rischia di essere
        // rubato dal gesto di sistema (Dock/App Switcher). defersSystemGestures dà priorità
        // alla nostra DragGesture di cambio pagina finché il tocco è in corso su quel bordo.
        .modifier(DefersBottomSystemGesturesIfAvailable())
        // Sempre nascosta, non legata a isControlsVisible: altrimenti la sua comparsa/scomparsa
        // anima la safe area proprio mentre la pagina (sotto .ignoresSafeArea()) dovrebbe restare
        // ferma, causando lo spostamento verticale visibile al mostrare/nascondere i controlli.
        .statusBar(hidden: true)
        #endif
        .onAppear {
            loadComic()
            resetIdleTimerIfNeeded()
        }
        .onDisappear { idleResetWorkItem?.cancel() }
        .onChange(of: currentPage) { newValue in
            guard let provider = provider else { return }
            comic.lastReadPage = Int32(min(max(newValue, 0), provider.pageCount - 1))
            comic.dateLastOpened = Date()
            try? context.save()
        }
        .onChange(of: isDoublePageEnabled) { _ in realignCurrentPageToSpreadStart() }
        .onChange(of: isDoublePageAutoMode) { _ in realignCurrentPageToSpreadStart() }
        .onChange(of: viewportSize) { _ in realignCurrentPageToSpreadStart() }
        #if os(iOS)
        .sheet(isPresented: $isSharePresented) {
            if let shareImage = shareImage {
                ActivityShareSheet(activityItems: [shareImage])
            }
        }
        #endif
        .sheet(isPresented: $isInfoPresented) {
            ComicInfoSheet(
                comic: comic,
                loadedPageCount: provider?.pageCount,
                onJumpToPage: {
                    jumpPageNumber = currentPage + 1
                    isPageJumpPresented = true
                },
                onToggleFavorite: toggleFavorite,
                onToggleReadingDirection: toggleReadingDirection
            )
        }
        .sheet(isPresented: $isToolsPresented) {
            ToolsPanelView()
        }
        .sheet(isPresented: $isAccountsPresented) {
            NavigationView { AccountsView().toolbarDoneButton { isAccountsPresented = false } }
        }
    }

    private func presentShareImage(_ image: PlatformImage) {
        shareImage = image
        #if os(iOS)
        isSharePresented = true
        #elseif os(macOS)
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            NSSharingServicePicker(items: [image]).show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
        #endif
    }

    private func toggleFavorite() {
        comic.isFavorite.toggle()
        try? context.save()
    }

    /// Card per saltare direttamente a una pagina specifica, aperta dal menu "..." dell'header.
    private func pageJumpCard(provider: ComicPageProvider) -> some View {
        VStack(spacing: 16) {
            Text("Vai a pagina")
                .font(.headline)
                .foregroundColor(.white)

            Stepper(value: $jumpPageNumber, in: 1...max(provider.pageCount, 1)) {
                Text("Pagina \(jumpPageNumber) di \(provider.pageCount)")
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 12) {
                Button(action: { isPageJumpPresented = false }) {
                    Text("Annulla")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                Button(action: confirmPageJump) {
                    Text("Vai")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(Color.black.opacity(0.85))
        .cornerRadius(16)
    }

    private func confirmPageJump() {
        guard let provider = provider else { return }
        let starts = spreadStarts(pageCount: provider.pageCount)
        let target = starts.last(where: { $0 <= jumpPageNumber - 1 }) ?? 0
        withAnimation(.easeInOut(duration: 0.2)) {
            currentPage = target
        }
        isPageJumpPresented = false
    }

    #if os(iOS)
    /// Con "Swipe page-turn" = Scorrimento usiamo il pager nativo `TabView(.page)` (segue il
    /// dito, sensazione migliore); per le altre opzioni (Disattivato/Immediato/Dissolvenza) lo
    /// swipe nativo non è configurabile, quindi passiamo a un pager gestito a mano con
    /// DragGesture, sospeso quando la pagina è ingrandita per non confliggere col pan interno.
    @ViewBuilder
    private func iOSPager(provider: ComicPageProvider) -> some View {
        if swipePageTurnStyle == .slide {
            nativeSwipePager(provider: provider)
        } else {
            manualSwipePager(provider: provider)
        }
    }

    private func nativeSwipePager(provider: ComicPageProvider) -> some View {
        ZStack {
            TabView(selection: $currentPage) {
                ForEach(spreadStarts(pageCount: provider.pageCount), id: \.self) { start in
                    PageSpreadView(provider: provider, leadingIndex: start, isDoublePage: effectiveDoublePage, isZoomed: $isZoomed)
                        .tag(start)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .environment(\.layoutDirection, comic.readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)

            tapZonesOrControlsToggle(provider: provider)
        }
    }

    private func manualSwipePager(provider: ComicPageProvider) -> some View {
        ZStack {
            PageSpreadView(provider: provider, leadingIndex: currentPage, isDoublePage: effectiveDoublePage, isZoomed: $isZoomed)
                .id(currentPage)
                .transition(swipePageTurnStyle == .fade ? .opacity : .identity)
                .environment(\.layoutDirection, comic.readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)

            tapZonesOrControlsToggle(provider: provider)

            if swipePageTurnStyle != .disabled && !isZoomed {
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24)
                            .onEnded { value in
                                guard abs(value.translation.width) > abs(value.translation.height),
                                      abs(value.translation.width) > 60 else { return }
                                step(value.translation.width < 0 ? 1 : -1, provider: provider, style: swipePageTurnStyle)
                            }
                    )
            }
        }
    }

    @ViewBuilder
    private func tapZonesOrControlsToggle(provider: ComicPageProvider) -> some View {
        if tapPageTurnStyle != .disabled {
            PageTapZones(oneHanded: isOneHandedModeEnabled, oneHandedReversed: isOneHandedZonesReversed, hotCorners: isHotCornersEnabled) {
                // Con "Tap-to-pan" anche la zona "indietro" avanza: comodo se non riesci a
                // raggiungere comodamente entrambi i lati dello schermo (vedi tooltip originale).
                step(isTapToPanEnabled ? 1 : -1, provider: provider, style: tapPageTurnStyle)
            } onNext: {
                step(1, provider: provider, style: tapPageTurnStyle)
            } onToggleControls: {
                toggleControls()
            } onExit: {
                presentationMode.wrappedValue.dismiss()
            } onOpenSettings: {
                isToolsPresented = true
            } onToggleDoublePage: {
                if isDoublePageAllowed { isDoublePageEnabled.toggle() }
            }
        } else {
            Color.clear
                .contentShape(Rectangle())
                // simultaneousGesture, non .onTapGesture: quest'ultimo reclama il tocco in
                // esclusiva e impedisce allo swipe nativo del TabView sottostante di funzionare.
                .simultaneousGesture(TapGesture().onEnded { toggleControls() })
        }
    }
    #else
    private func macOSPager(provider: ComicPageProvider) -> some View {
        ZStack {
            PageSpreadView(provider: provider, leadingIndex: currentPage, isDoublePage: effectiveDoublePage, isZoomed: $isZoomed)
                .id(currentPage)
                .transition(tapPageTurnStyle == .fade ? .opacity : .identity)
                .environment(\.layoutDirection, comic.readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)

            if tapPageTurnStyle != .disabled {
                PageTapZones(oneHanded: isOneHandedModeEnabled, oneHandedReversed: isOneHandedZonesReversed, hotCorners: isHotCornersEnabled) {
                    step(-1, provider: provider, style: tapPageTurnStyle)
                } onNext: {
                    step(1, provider: provider, style: tapPageTurnStyle)
                } onToggleControls: {
                    toggleControls()
                } onExit: {
                    presentationMode.wrappedValue.dismiss()
                } onOpenSettings: {
                    isToolsPresented = true
                } onToggleDoublePage: {
                    if isDoublePageAllowed { isDoublePageEnabled.toggle() }
                }
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
            }
        }
        .background(KeyEventMonitor { keyCode in
            switch keyCode {
            case .leftArrow: step(-1, provider: provider, style: tapPageTurnStyle)
            case .rightArrow, .space: step(1, provider: provider, style: tapPageTurnStyle)
            }
        })
    }
    #endif

    /// Avanza/retrocede di uno spread, rispettando la direzione di lettura corrente (manga = invertita).
    /// `style` è quello del gesto che ha innescato il cambio (tap o swipe/tastiera hanno
    /// impostazioni indipendenti) e decide solo l'animazione: "Scorrimento" nativo via TabView
    /// su iOS non passa da qui (vedi iOSPager), quindi qui "slide" è semplicemente l'animazione
    /// di fallback usata anche per i cambi pagina non innescati da swipe (tap, tastiera, jump).
    private func step(_ direction: Int, provider: ComicPageProvider, style: TapPageTurnStyle) {
        let effectiveDirection = (comic.readingDirection == .rightToLeft ? -direction : direction) * pageStep
        let next = currentPage + effectiveDirection
        if next >= provider.pageCount {
            if direction > 0, let candidate = nextComicInLibrary {
                pendingNextComic = candidate
            }
            return
        }
        guard next >= 0 else { return }
        resetIdleTimerIfNeeded()
        switch style {
        case .immediate:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { currentPage = next }
        default:
            withAnimation(.easeInOut(duration: 0.2)) { currentPage = next }
        }
    }

    private func toggleControls() {
        resetIdleTimerIfNeeded()
        isControlsVisible.toggle()
    }

    /// Timer "vetrina/kiosk": se il lettore resta inattivo per il tempo scelto in Impostazioni,
    /// torna automaticamente a pagina 1. Ogni interazione (tap, cambio pagina) lo riavvia.
    private func resetIdleTimerIfNeeded() {
        idleResetWorkItem?.cancel()
        guard readerIdleReset.rawValue > 0 else { return }
        let workItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.2)) { currentPage = 0 }
        }
        idleResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(readerIdleReset.rawValue), execute: workItem)
    }

    /// Il fumetto successivo a quello corrente nell'ordine mostrato in libreria, se esiste.
    private var nextComicInLibrary: ComicEntity? {
        guard let index = libraryComics.firstIndex(where: { $0.objectID == comic.objectID }) else { return nil }
        let nextIndex = index + 1
        guard nextIndex < libraryComics.count else { return nil }
        return libraryComics[nextIndex]
    }

    /// Card di conferma mostrata a fine lettura: chiede esplicitamente se aprire il prossimo
    /// fumetto in libreria, mostrandone copertina e titolo prima di procedere.
    private func nextComicConfirmation(_ next: ComicEntity) -> some View {
        VStack(spacing: 16) {
            Text("Fine del fumetto")
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 12) {
                ComicGridItemView(comic: next)
                    .frame(width: 90, height: 135)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continuare con:")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Text(next.title ?? "")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Button(action: { pendingNextComic = nil }) {
                    Text("Annulla")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                Button(action: { switchToComic(next) }) {
                    Text("Apri")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(Color.black.opacity(0.85))
        .cornerRadius(16)
    }

    private func switchToComic(_ next: ComicEntity) {
        pendingNextComic = nil
        onSwitchComic(next)
    }

    private var header: some View {
        HStack(spacing: 2) {
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Libreria")
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(minHeight: 44)
            }
            // Ritaglio: apre la selezione riquadro, l'unico modo per condividere nell'originale
            // (si seleziona sempre un'area, non c'è un tasto "condividi tutta la pagina" a parte).
            // Icona a bolla con puntini come nell'originale (non l'icona standard "crop").
            Button(action: { isPanelSelectionPresented = true }) {
                Image(systemName: "ellipsis.bubble").frame(width: 44, height: 44)
            }
            Spacer(minLength: 4)
            // Info fumetto (con vai-a-pagina/preferiti/direzione lettura, che prima stavano in
            // un Menu a tendina — mai presente nell'originale, e già noto essere inaffidabile
            // con contenuti interattivi su questo target, vedi ToolsPanelView): tap prolungato
            // sul titolo, per non aggiungere un'altra icona all'header.
            Text(comic.title ?? "")
                .font(.subheadline.bold())
                .lineLimit(1)
                .onLongPressGesture { isInfoPresented = true }
            Spacer(minLength: 4)
            headerTrailingActions
        }
        .foregroundColor(chromeForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(chromeBackground)
        // Il materiale di sistema segue lo scheme corrente: forziamo qui quello coerente con
        // "Sfondo pagina" (nero/bianco/auto), come già fa chromeForeground per il testo/icone.
        .environment(\.colorScheme, isBackgroundDark ? .dark : .light)
        .buttonStyle(PlainButtonStyle())
    }

    /// Le 4 icone finali dell'header quando c'è spazio per mostrarle singolarmente (iPad, Mac,
    /// iPhone in landscape) — condivisa da entrambi i rami di `headerTrailingActions`.
    private var expandedTrailingActions: some View {
        Group {
            newComicsButton
            nowReadingButton
            Button(action: { isAccountsPresented = true }) {
                Image(systemName: "cloud").frame(width: 44, height: 44)
            }
            Button(action: { isToolsPresented = true }) {
                Image(systemName: "wrench.and.screwdriver").frame(width: 44, height: 44)
            }
        }
    }

    /// Su iPhone (larghezza compatta) le 4 icone finali dell'header non ci stanno comode:
    /// le raccogliamo in un menu "..." unico, come fa già nativamente la toolbar di Libreria
    /// quando lo spazio non basta. Su iPad/Mac restano le singole icone, invariate.
    @ViewBuilder
    private var headerTrailingActions: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            Menu {
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
            .popover(isPresented: $isNewComicsPresented) {
                NewComicsView(comics: recentComics) {
                    isNewComicsPresented = false
                    if $0 != comic { onSwitchComic($0) }
                } onClear: {
                    newTrayClearedAtTimestamp = Date().timeIntervalSince1970
                    isNewComicsPresented = false
                }
            }
            .popover(isPresented: $isNowReadingPresented) {
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

    /// Fumetti importati negli ultimi 7 giorni, come in libreria (stessa chiave "Cancella"
    /// condivisa via @AppStorage). Vuoto se il reader è aperto senza contesto di libreria.
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
            Image(systemName: "envelope").frame(width: 44, height: 44)
        }
        .popover(isPresented: $isNewComicsPresented) {
            NewComicsView(comics: recentComics) {
                isNewComicsPresented = false
                if $0 != comic { onSwitchComic($0) }
            } onClear: {
                newTrayClearedAtTimestamp = Date().timeIntervalSince1970
                isNewComicsPresented = false
            }
        }
    }

    /// Il fumetto aperto più di recente nella libreria, come nel pulsante omonimo lì.
    private var lastReadComic: ComicEntity? {
        libraryComics
            .filter { $0.dateLastOpened != nil }
            .max { ($0.dateLastOpened ?? .distantPast) < ($1.dateLastOpened ?? .distantPast) }
    }

    @ViewBuilder
    private var nowReadingButton: some View {
        if let lastRead = lastReadComic {
            Button(action: { isNowReadingPresented = true }) {
                Image(systemName: "book").frame(width: 44, height: 44)
            }
            .popover(isPresented: $isNowReadingPresented) {
                NowReadingView(comic: lastRead) {
                    isNowReadingPresented = false
                    if lastRead != comic { onSwitchComic(lastRead) }
                }
            }
        }
    }

    private var footer: some View {
        Group {
            if let provider = provider, provider.pageCount > 1 {
                let upperBound = min(currentPage + pageStep, provider.pageCount)
                let label = upperBound - currentPage > 1
                    ? "\(currentPage + 1)–\(upperBound) / \(provider.pageCount)"
                    : "\(currentPage + 1) / \(provider.pageCount)"
                HStack(spacing: 4) {
                    // Colonna a larghezza fissa: la larghezza del numero di pagina varia
                    // (es. "1 / 20" vs "10–11 / 20") e senza pre-allocare lo spazio lo
                    // slider accanto si sposterebbe ogni volta che cambia pagina.
                    VStack(spacing: 0) {
                        Text(label)
                            .font(.caption.monospacedDigit())
                        // Scambia quale metà (sopra/sotto) avanza/retrocede in modalità una mano.
                        Button(action: { isOneHandedZonesReversed.toggle() }) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .rotationEffect(.degrees(isOneHandedZonesReversed ? 180 : 0))
                                .frame(width: 20, height: 24)
                        }
                    }
                    .frame(width: 70)
                    pageSlider(provider: provider)
                    if isDoublePageAllowed {
                        // Cicla singola → doppia → automatica pagina.
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
                    }
                }
                .foregroundColor(chromeForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(chromeBackground)
                .environment(\.colorScheme, isBackgroundDark ? .dark : .light)
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private var pageLayoutModeIconName: String {
        if isDoublePageAutoMode { return "a.square" }
        return isDoublePageEnabled ? "square.split.2x1" : "square"
    }

    private func cyclePageLayoutMode() {
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
        // Non usiamo più lo Slider di sistema: sovrapposto al TabView(.page), il suo
        // pan gesture interno perde l'arbitraggio con quello di scroll della pagina (la
        // pagina gira invece di trascinare il pallino). Un DragGesture con priorità alta
        // vince sempre sul gesture di swipe sottostante.
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

            Color.clear
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard maxValue > 0 else { return }
                            let fraction = min(max(value.location.x / width, 0), 1)
                            let target = Int((Double(isRTL ? 1 - fraction : fraction) * maxValue).rounded())
                            let starts = spreadStarts(pageCount: provider.pageCount)
                            currentPage = starts.min(by: { abs($0 - target) < abs($1 - target) }) ?? 0
                        }
                )
        }
        .frame(height: 24)
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }

    private func toggleReadingDirection() {
        comic.readingDirection = comic.readingDirection == .rightToLeft ? .leftToRight : .rightToLeft
        try? context.save()
    }


    private func loadComic() {
        guard provider == nil else { return }
        let url = LibraryStorage.fileURL(forRelativePath: comic.relativePath ?? "")
        let format = comic.format
        let startingPage = Int(comic.lastReadPage)

        // Il download da iCloud può richiedere più di qualche secondo (file grandi, connessione
        // lenta): lo registriamo nella scheda Downloads con un progresso reale, invece di far
        // fallire il lettore dopo un timeout fisso come accadeva prima.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if LibraryStorage.isPendingDownload(url) {
                    let downloadItem = DispatchQueue.main.sync {
                        DownloadManager.shared.register(title: comic.title ?? "Fumetto")
                    }
                    do {
                        try LibraryStorage.downloadIfNeeded(
                            url,
                            isCancelled: { downloadItem.isCancelled }
                        ) { progress in
                            downloadItem.updateProgress(progress)
                        }
                    } catch {
                        DispatchQueue.main.async { DownloadManager.shared.remove(downloadItem) }
                        throw error
                    }
                    DispatchQueue.main.async { DownloadManager.shared.remove(downloadItem) }
                }
                let loaded = try ComicPageProviderFactory.makeProvider(for: url, format: format)
                DispatchQueue.main.async {
                    provider = loaded
                    let clampedStart = min(startingPage, max(0, loaded.pageCount - 1))
                    let starts = spreadStarts(pageCount: loaded.pageCount)
                    currentPage = starts.last(where: { $0 <= clampedStart }) ?? 0
                    if comic.pageCount == 0 {
                        comic.pageCount = Int32(loaded.pageCount)
                        try? context.save()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    loadError = error.localizedDescription
                }
            }
        }
    }
}

/// Zone di tap per cambiare pagina: due terzi laterali (avanti/indietro) e una fascia centrale
/// per mostrare/nascondere i controlli, oppure — in modalità "una mano" — l'intero lato
/// sinistro/destro (senza fascia centrale, per restare comodi col pollice a schermo intero).
private struct PageTapZones: View {
    let oneHanded: Bool
    /// In modalità "una mano", scambia quale lato (sinistro/destro) avanza e quale
    /// retrocede: comodo per adattarsi a mano destra/sinistra o a come si tiene il telefono.
    let oneHandedReversed: Bool
    let hotCorners: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleControls: () -> Void
    /// Angoli attivi con "Hot corners": in alto a sinistra esce dalla lettura, in alto a
    /// destra apre le impostazioni, in basso a destra alterna la doppia pagina — corrispondono
    /// ai tre comportamenti documentati nei tooltip dell'app originale.
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
                        zone(action: onExit)
                            .frame(width: 88, height: 88)
                        Spacer()
                        zone(action: onOpenSettings)
                            .frame(width: 88, height: 88)
                    }
                    mainZones(proxy: proxy)
                    HStack {
                        Spacer()
                        zone(action: onToggleDoublePage)
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
            HStack(spacing: 0) {
                zone(action: sharedAction)
                    .frame(width: min(proxy.size.width * 0.18, 90))
                zone(action: onToggleControls)
                zone(action: sharedAction)
                    .frame(width: min(proxy.size.width * 0.18, 90))
            }
        } else {
            HStack(spacing: 0) {
                zone(action: onPrevious)
                    .frame(width: min(proxy.size.width * 0.18, 90))
                zone(action: onToggleControls)
                zone(action: onNext)
                    .frame(width: min(proxy.size.width * 0.18, 90))
            }
        }
    }

    private func zone(action: @escaping () -> Void) -> some View {
        // simultaneousGesture, non .onTapGesture: quest'ultimo reclama il tocco in esclusiva,
        // impedendo allo swipe nativo del TabView(.page) sottostante di funzionare del tutto
        // (su iOS il cambio pagina via swipe restava morto anche con le zone di tap disattivate,
        // perché non è questo il gesture ad essere il problema — .onTapGesture in generale sì).
        Color.clear
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(action))
    }
}

/// Mostra una singola pagina, o due affiancate in modalità doppia pagina. In un ambiente
/// con layoutDirection .rightToLeft, l'HStack viene automaticamente rispecchiato da SwiftUI:
/// la pagina con indice più basso resta quindi a destra, come da convenzione manga.
private struct PageSpreadView: View {
    let provider: ComicPageProvider
    let leadingIndex: Int
    let isDoublePage: Bool
    let isZoomed: Binding<Bool>

    var body: some View {
        HStack(spacing: 0) {
            PageView(provider: provider, index: leadingIndex, isDoublePage: isDoublePage, isZoomed: isZoomed)
            if isDoublePage, leadingIndex + 1 < provider.pageCount {
                PageView(provider: provider, index: leadingIndex + 1, isDoublePage: isDoublePage, isZoomed: isZoomed)
            }
        }
    }
}

private struct PageView: View {
    let provider: ComicPageProvider
    let index: Int
    let isDoublePage: Bool
    let isZoomed: Binding<Bool>
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    @AppStorage("singlePageZoomMode") private var singlePageZoomMode = PageZoomMode.auto
    @AppStorage("doublePageZoomMode") private var doublePageZoomMode = PageZoomMode.auto
    @AppStorage("motionBlurEnabled") private var isMotionBlurEnabled = true
    @State private var image: PlatformImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// Sfoca leggermente l'immagine in proporzione alla velocità del trascinamento mentre si fa
    /// pan su una pagina ingrandita ("Motion-blur": "Make panning a feel little smoother" nel
    /// tooltip originale) — non un filtro estetico permanente, sparisce a fine gesto.
    @State private var motionBlurRadius: CGFloat = 0

    /// "Automatico"/"Adatta pagina" mostrano l'intera pagina (comportamento storico, invariato).
    /// "Adatta larghezza" è l'unico caso che cambia layout: scala alla larghezza disponibile e,
    /// se il risultato eccede l'altezza dello schermo, rende la pagina scorrevole verticalmente.
    private var effectiveZoomMode: PageZoomMode {
        isDoublePage ? doublePageZoomMode : singlePageZoomMode
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image = image {
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
                        image.asSwiftUIImage
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(scale)
                            .offset(offset)
                            .blur(radius: motionBlurRadius)
                            .overlay(tintOverlay)
                            .gesture(magnifyGesture)
                            // Attivo solo da zoomata: a scale 1 non deve intercettare il drag,
                            // altrimenti ruba il tocco allo swipe-pagina sottostante (TabView
                            // nativo o pager manuale) anche se poi non fa nulla (guard scale > 1).
                            .gesture(dragGesture, including: scale > 1 ? .all : .subviews)
                            .onTapGesture(count: 2) { toggleZoom() }
                    }
                } else {
                    ProgressView().accentColor(.white)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .onAppear { loadImage(targetSize: proxy.size) }
        }
        .clipped()
    }

    @ViewBuilder
    private var tintOverlay: some View {
        if let tint = theme.pageTint, theme.pageTintOpacity > 0 {
            tint.opacity(theme.pageTintOpacity).blendMode(.multiply)
        }
    }

    private func loadImage(targetSize: CGSize) {
        guard image == nil else { return }
        let autoCrop = isAutoCropEnabled
        let upscale = isUpscalingEnabled
        let autoTintContrast = isAutoTintContrastEnabled
        DispatchQueue.global(qos: .userInitiated).async {
            guard var loaded = try? provider.image(atPage: index) else { return }
            if autoCrop {
                loaded = ImageProcessing.autoCropWhiteBorders(loaded)
            }
            if autoTintContrast {
                loaded = ImageProcessing.autoTintAndContrast(loaded)
            }
            if upscale {
                loaded = ImageProcessing.upscaleIfNeeded(loaded, targetSize: targetSize)
            }
            DispatchQueue.main.async { self.image = loaded }
        }
    }

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

    private func syncZoomedState() {
        isZoomed.wrappedValue = scale > 1.01
    }

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

#if os(iOS)
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Intercetta un pan a due dita per regolare la luminosità dello schermo, come
/// "Two-finger-swipe brightness" nell'app originale — senza rubare tocchi alle viste
/// sottostanti (swipe pagina, tap zone, pinch-to-zoom).
private struct TwoFingerBrightnessView: UIViewRepresentable {
    /// Delta verticale normalizzato (-1...1) da sommare alla luminosità corrente.
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> WindowPanRelayView {
        let view = WindowPanRelayView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: WindowPanRelayView, context: Context) {
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (CGFloat) -> Void
        init(onChange: @escaping (CGFloat) -> Void) { self.onChange = onChange }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view, view.bounds.height > 0 else { return }
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
/// nil (come faceva prima in base al numero di dita già premute) non funziona, perché un tocco
/// viene assegnato in modo definitivo alla vista risultante dall'hit-test al suo `touchesBegan`
/// — se il primo dito è già stato instradato al pager sottostante, "rubare" il secondo dito qui
/// lo isola dal primo e nessun recognizer arriva mai a vedere entrambi i tocchi insieme (né
/// questo pan, né il pinch-to-zoom della pagina sotto).
///
/// Il pan a due dita viene quindi agganciato alla finestra invece che a questa vista: la
/// finestra è antenata di qualunque vista venga colpita dall'hit-test (pager, tap zone,
/// immagine), quindi il suo recognizer riceve comunque entrambi i tocchi.
private final class WindowPanRelayView: UIView {
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
        recognizer.maximumNumberOfTouches = 2
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

/// `defersSystemGestures(on:)` esiste solo da iOS 16: sotto, nessun-op (l'unico effetto perso
/// è la precedenza dello swipe-pagina sul gesto di sistema del Dock/App Switcher su iPad).
private struct DefersBottomSystemGesturesIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.defersSystemGestures(on: .bottom)
        } else {
            content
        }
    }
}
#endif

#if os(macOS)
private enum ReaderKey {
    case leftArrow
    case rightArrow
    case space
}

/// Intercetta le frecce e la barra spaziatrice per la navigazione da tastiera nel reader su Mac.
private struct KeyEventMonitor: NSViewRepresentable {
    let onKey: (ReaderKey) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitoringView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitoringView)?.onKey = onKey
    }

    final class MonitoringView: NSView {
        var onKey: ((ReaderKey) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                switch event.keyCode {
                case 123: self?.onKey?(.leftArrow); return nil
                case 124: self?.onKey?(.rightArrow); return nil
                case 49: self?.onKey?(.space); return nil
                default: return event
                }
            }
        }

        deinit {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
#endif
