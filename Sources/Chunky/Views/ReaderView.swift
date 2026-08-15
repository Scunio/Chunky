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
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    // Su Mac il reader vive nella propria finestra (WindowGroup(for: ComicID.self)), non in uno
    // .sheet: dismiss() lì non ha alcun effetto. dismissWindow() chiude la finestra che la
    // contiene, che è il vero equivalente di "esci dalla lettura" qui.
    @Environment(\.dismissWindow) private var dismissWindow
    #endif
    /// Scelta esplicita singola/doppia pagina, valida solo quando non si è in modalità automatica.
    @AppStorage("doublePageMode") private var isDoublePageEnabled = false
    /// In automatico, la doppia pagina segue semplicemente lo spazio disponibile (isDoublePageAllowed).
    @AppStorage("doublePageAutoMode") private var isDoublePageAutoMode = true
    /// Se vera, la prima pagina (di solito la copertina) è sempre mostrata da sola anche in
    /// doppia pagina, e l'accoppiamento a due pagine riprende dalla seconda.
    @AppStorage("doublePageCoverAlone") private var isCoverAlone = true
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
    /// Stile e verso dell'ultimo cambio pagina: il pager li usa per scegliere la transizione.
    /// Servono perché lo stile è per-gesto (tap e swipe hanno impostazioni indipendenti), quindi
    /// non si può leggerlo dall'AppStorage al momento di costruire la vista: bisogna sapere
    /// *quale* gesto ha innescato il cambio.
    @State private var turnStyle = TapPageTurnStyle.slide
    /// +1 = l'indice di pagina cresce, -1 = cala (già al netto della direzione di lettura).
    @State private var turnDirection = 1
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Dimensioni del viewport, per capire se c'è davvero spazio orizzontale per la doppia
    /// pagina: su iPad la size class resta "regular" anche in verticale, quindi da sola non
    /// basta a evitare lo spreco di spazio (due pagine strette con bande nere sopra/sotto).
    @State private var viewportSize: CGSize = .zero
    @State private var provider: ComicPageProvider?
    #if os(macOS)
    @State private var pageCache: PageImageCache?
    // Duplicano le chiavi lette anche da `PageView`: servono qui per invalidare la cache
    // quando cambiano (vedi `.onChange` più sotto), non per l'elaborazione stessa.
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    #endif
    /// Indice della pagina "principale" (la prima, più a sinistra in LTR) dello spread corrente.
    @State private var currentPage: Int = 0
    @State private var loadError: String?
    /// Avanzamento (0...1) del download iCloud del fumetto che si sta aprendo, nil se non c'è
    /// nessun download in corso: apre il fumetto si può sempre, è l'apertura stessa a scaricarlo.
    @State private var downloadProgress: Double?
    /// Il download in corso, per poterlo annullare direttamente dal lettore.
    @State private var downloadItem: DownloadItem?
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
    /// basta su iPad, dove resta "regular" anche in verticale. Logica in `DoublePagePolicy`:
    /// su macOS non esiste una size class compatta, quindi la decisione dipende sempre e solo
    /// dalle proporzioni misurate.
    private var isDoublePageAllowed: Bool {
        #if os(iOS)
        DoublePagePolicy.isAllowed(viewportSize: viewportSize, isCompactWidth: horizontalSizeClass != .regular)
        #else
        DoublePagePolicy.isAllowed(viewportSize: viewportSize, isCompactWidth: false)
        #endif
    }

    /// Doppia pagina effettiva: in automatico segue lo spazio disponibile, altrimenti la scelta manuale.
    private var effectiveDoublePage: Bool {
        isDoublePageAutoMode ? isDoublePageAllowed : (isDoublePageEnabled && isDoublePageAllowed)
    }

    private var pageStep: Int { effectiveDoublePage ? 2 : 1 }

    private func pagination(pageCount: Int) -> ReaderPagination {
        ReaderPagination(
            pageCount: pageCount,
            pageStep: pageStep,
            isRightToLeft: comic.readingDirection == .rightToLeft,
            coverIsAlone: isCoverAlone
        )
    }

    /// Indici di inizio di ogni spread (1 o 2 pagine), usati come "tag"/passi di navigazione.
    private func spreadStarts(pageCount: Int) -> [Int] {
        pagination(pageCount: pageCount).spreadStarts
    }

    // Cambiando il passo di pagina, l'indice corrente potrebbe non essere più un
    // inizio-spread valido (es. da pagina pari a passo 2): lo riallineiamo, altrimenti
    // il tag del TabView non trova corrispondenza e mostra la pagina sbagliata.
    private func realignCurrentPageToSpreadStart() {
        guard let provider = provider else { return }
        currentPage = pagination(pageCount: provider.pageCount).realigned(currentPage)
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

    /// Materiale traslucido di sistema, come il `.toolbar` nativo di Libreria.
    private var chromeBackground: some View {
        Rectangle().fill(.bar)
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
                    .onChange(of: proxy.size) { viewportSize = proxy.size }
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
            } else if let downloadProgress = downloadProgress {
                downloadOverlay(progress: downloadProgress)
            } else {
                ProgressView().accentColor(chromeForeground)
            }

            #if os(iOS)
            if isTwoFingerBrightnessEnabled {
                TwoFingerBrightnessView { delta in
                    guard let screen = UIScreen.current else { return }
                    screen.brightness = min(max(screen.brightness + delta, 0), 1)
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
                if tapPageTurnStyle != .disabled {
                    if isOneHandedModeEnabled {
                        // In modalità una mano i due lati fanno la stessa azione, quindi le
                        // frecce puntano entrambe nella stessa direzione (quella dell'azione
                        // condivisa) invece che una avanti e una indietro.
                        let sharedSymbol = isOneHandedZonesReversed ? "arrowtriangle.left" : "arrowtriangle.right"
                        HStack {
                            Image(systemName: sharedSymbol)
                            Spacer()
                            Image(systemName: sharedSymbol)
                        }
                        .font(.title2)
                        .foregroundColor(chromeForeground.opacity(0.35))
                        .padding(.horizontal, 14)
                        .allowsHitTesting(false)
                    } else {
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
            }

            if let next = pendingNextComic {
                nextComicConfirmation(next)
            }

            if isPageJumpPresented, let provider = provider {
                pageJumpCard(provider: provider)
            }

            // Sovrapposta direttamente alla pagina già visibile (non un'altra schermata/sheet):
            // si vede ancora la pagina sotto, non un fumetto ricaricato a sé stante.
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
        .defersSystemGestures(on: .bottom)
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
        .onChange(of: currentPage) { _, newValue in
            guard let provider = provider else { return }
            comic.lastReadPage = Int32(min(max(newValue, 0), provider.pageCount - 1))
            comic.dateLastOpened = Date()
            try? context.save()
        }
        .onChange(of: isDoublePageEnabled) { realignCurrentPageToSpreadStart() }
        .onChange(of: isDoublePageAutoMode) { realignCurrentPageToSpreadStart() }
        .onChange(of: viewportSize) { realignCurrentPageToSpreadStart() }
        #if os(macOS)
        // Le voci in cache sono state elaborate con le opzioni precedenti: senza svuotarla,
        // una pagina già vista mostrerebbe il ritaglio/tint vecchio finché non esce dalla
        // finestra di prefetch.
        .onChange(of: isAutoCropEnabled) { purgePageCache() }
        .onChange(of: isUpscalingEnabled) { purgePageCache() }
        .onChange(of: isAutoTintContrastEnabled) { purgePageCache() }
        #endif
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
            NavigationStack { AccountsView().toolbarDoneButton { isAccountsPresented = false } }
                .sheetSized()
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

    private func exitReader() {
        #if os(macOS)
        dismissWindow()
        #else
        dismiss()
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
        let target = pagination(pageCount: provider.pageCount).realigned(jumpPageNumber - 1)
        turnStyle = tapPageTurnStyle
        turnDirection = target > currentPage ? 1 : -1
        withAnimation(.easeInOut(duration: 0.2)) {
            currentPage = target
        }
        isPageJumpPresented = false
    }

    #if os(macOS)
    /// La pagina (o lo spread) corrente, con la transizione dell'ultimo cambio pagina.
    ///
    /// L'ordine dei due `.environment` è voluto: quello più esterno vale per il layer della
    /// transizione, così i bordi di `.move(edge:)` si risolvono sempre in LTR e il verso lo
    /// decidiamo noi in `pageTurnTransition`; quello interno rispecchia lo spread per i manga.
    private func pagerContent(provider: ComicPageProvider) -> some View {
        PageSpreadView(provider: provider, leadingIndex: currentPage, pagination: pagination(pageCount: provider.pageCount), isZoomed: $isZoomed, imageCache: pageCache)
            .environment(\.layoutDirection, comic.readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
            .id(currentPage)
            .transition(pageTurnTransition)
            .environment(\.layoutDirection, .leftToRight)
            // Avviato appena `currentPage` cambia, non dentro `PageView.onAppear`: così il
            // prefetch parte subito, in parallelo con l'animazione di transizione, invece di
            // aspettare che la pagina in arrivo lo richieda.
            .task(id: currentPage) {
                await prefetchAroundCurrentPage(provider: provider)
            }
    }

    private func prefetchAroundCurrentPage(provider: ComicPageProvider) async {
        guard let pageCache else { return }
        // Deve combaciare con `proxy.size` che `PageView.loadImage` userà davvero: in doppia
        // pagina ogni `PageView` occupa circa metà larghezza del viewport (HStack(spacing: 0)
        // in `PageSpreadView`), non l'intero viewport. Senza questo, `ProcessingOptions` non
        // coincide mai tra prefetch e richiesta reale, e la cache va in miss ad ogni pagina —
        // esattamente nella modalità (doppia pagina + upscaling) in cui costa di più.
        let pageTargetSize = effectiveDoublePage
            ? CGSize(width: viewportSize.width / 2, height: viewportSize.height)
            : viewportSize
        let options = PageImageCache.ProcessingOptions(
            autoCrop: isAutoCropEnabled,
            autoTintContrast: isAutoTintContrastEnabled,
            upscaleTargetSize: isUpscalingEnabled ? pageTargetSize : nil
        )
        await pageCache.prefetch(around: currentPage, radius: 2, pageCount: provider.pageCount, options: options)
    }

    /// Traduce lo stile del gesto che ha innescato il cambio nella transizione corrispondente:
    /// scorrimento laterale, dissolvenza o taglio netto (per "Immediato" l'animazione è già
    /// disattivata in `step`, qui basta non aggiungere effetti).
    private var pageTurnTransition: AnyTransition {
        switch turnStyle {
        case .fade:
            return .opacity
        case .slide:
            // La pagina con indice più alto sta a destra in LTR e a sinistra nei manga: è da
            // lì che deve entrare quando l'indice cresce, e dal lato opposto quando cala.
            let indexIncreasing = turnDirection > 0
            let rightToLeft = comic.readingDirection == .rightToLeft
            let entering: Edge = (indexIncreasing != rightToLeft) ? .trailing : .leading
            return .asymmetric(
                insertion: .move(edge: entering),
                removal: .move(edge: entering == .trailing ? .leading : .trailing)
            )
        case .immediate, .disabled:
            return .identity
        }
    }

    #endif

    #if os(iOS)
    /// Quando lo swipe deve seguire il dito si usa `TabView(.page)`: il paging interattivo di
    /// `UIPageViewController` non porta a termine la transizione dentro questa gerarchia (il pan
    /// parte, il dataSource restituisce la pagina vicina, ma `didFinishAnimating` non arriva mai —
    /// verificato anche con il contenuto ridotto a un colore pieno, quindi non è colpa dei gesti
    /// della pagina né degli overlay). Il TabView invece funziona, al prezzo di non poter
    /// sostituire la propria animazione di slide.
    ///
    /// Per gli altri stili serve proprio quello: "Immediato" e "Dissolvenza" non sono
    /// rappresentabili da un trascinamento continuo, quindi lì il paging a gesto è spento, lo
    /// swipe viene riconosciuto come gesto discreto e la pagina gira in modo programmatico con
    /// l'animazione giusta — cosa che `PageTurnPager` sa fare e il TabView no.
    @ViewBuilder
    private func iOSPager(provider: ComicPageProvider) -> some View {
        if swipePageTurnStyle == .slide && tapPageTurnStyle == .slide {
            nativeSwipePager(provider: provider)
        } else {
            programmaticPager(provider: provider)
        }
    }

    /// Le zone di tap stanno *dentro* il contenuto della pagina, non sovrapposte al pager in uno
    /// ZStack: una view sovrapposta (anche `Color.clear`) è un fratello disegnato sopra la scroll
    /// view del pager e l'hit-test UIKit le assegna ogni tocco, swipe compresi — il pager non ne
    /// riceve nessuno e il cambio pagina resta morto (`simultaneousGesture` non cambia l'hit-test,
    /// riguarda solo l'arbitraggio fra gesture). Da dentro il contenuto sono invece subview della
    /// scroll view, che continua a riconoscere il pan dal proprio recognizer.
    private func pageContent(provider: ComicPageProvider, start: Int) -> some View {
        ZStack {
            PageSpreadView(provider: provider, leadingIndex: start, pagination: pagination(pageCount: provider.pageCount), isZoomed: $isZoomed)
                .environment(\.layoutDirection, comic.readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)

            tapZonesOrControlsToggle(provider: provider)
        }
    }

    private func nativeSwipePager(provider: ComicPageProvider) -> some View {
        TabView(selection: $currentPage) {
            ForEach(spreadStarts(pageCount: provider.pageCount), id: \.self) { start in
                pageContent(provider: provider, start: start)
                    .tag(start)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .environment(\.layoutDirection, comic.readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }

    private func programmaticPager(provider: ComicPageProvider) -> some View {
        let isInteractiveSwipe = swipePageTurnStyle == .slide && !isZoomed
        return ZStack {
            PageTurnPager(
                starts: spreadStarts(pageCount: provider.pageCount),
                selection: $currentPage,
                rightToLeft: comic.readingDirection == .rightToLeft,
                turnStyle: turnStyle,
                interactiveSwipe: isInteractiveSwipe,
                resetToken: PagerResetToken(
                    doublePage: effectiveDoublePage,
                    rightToLeft: comic.readingDirection == .rightToLeft,
                    pageCount: provider.pageCount
                )
            ) { start in
                pageContent(provider: provider, start: start)
            }

            if !isInteractiveSwipe && swipePageTurnStyle != .disabled && !isZoomed {
                discreteSwipeCatcher(provider: provider)
            }
        }
    }

    /// Riconosce lo swipe come gesto discreto (soglia superata = una pagina) per gli stili che
    /// il paging interattivo non sa rendere. `simultaneousGesture` per non rubare il tocco alle
    /// zone di tap sottostanti.
    private func discreteSwipeCatcher(provider: ComicPageProvider) -> some View {
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

    @ViewBuilder
    private func tapZonesOrControlsToggle(provider: ComicPageProvider) -> some View {
        if tapPageTurnStyle != .disabled {
            PageTapZones(oneHanded: isOneHandedModeEnabled, oneHandedReversed: isOneHandedZonesReversed, hotCorners: isHotCornersEnabled, rightToLeft: comic.readingDirection == .rightToLeft) {
                // Con "Tap-to-pan" anche la zona "indietro" avanza: comodo se non riesci a
                // raggiungere comodamente entrambi i lati dello schermo.
                step(isTapToPanEnabled ? 1 : -1, provider: provider, style: tapPageTurnStyle)
            } onNext: {
                step(1, provider: provider, style: tapPageTurnStyle)
            } onToggleControls: {
                toggleControls()
            } onExit: {
                exitReader()
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
    #if os(macOS)
    private func purgePageCache() {
        guard let pageCache else { return }
        Task { await pageCache.purge() }
    }
    #endif

    private func macOSPager(provider: ComicPageProvider) -> some View {
        ZStack {
            pagerContent(provider: provider)

            if tapPageTurnStyle != .disabled {
                PageTapZones(oneHanded: isOneHandedModeEnabled, oneHandedReversed: isOneHandedZonesReversed, hotCorners: isHotCornersEnabled, rightToLeft: comic.readingDirection == .rightToLeft) {
                    step(-1, provider: provider, style: tapPageTurnStyle)
                } onNext: {
                    step(1, provider: provider, style: tapPageTurnStyle)
                } onToggleControls: {
                    toggleControls()
                } onExit: {
                    exitReader()
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
        .background(ScrollSwipeMonitor { direction in
            guard swipePageTurnStyle != .disabled, !isZoomed else { return }
            step(direction, provider: provider, style: swipePageTurnStyle)
        })
        // Pubblicata solo mentre questa vista è viva, quindi solo mentre una finestra reader è
        // davvero in scena — nessun filtro sul blocco genitori qui, perché con `lock.isLocked`
        // `ReaderWindowContainer` mostra `ParentalLockGateView` al posto di `ReaderView`,
        // quindi questo codice non è proprio montato.
        .focusedSceneValue(\.readerActions, ReaderCommandActions(
            previousPage: { step(-1, provider: provider, style: tapPageTurnStyle) },
            nextPage: { step(1, provider: provider, style: tapPageTurnStyle) }
        ))
    }
    #endif

    /// Avanza/retrocede di uno spread, rispettando la direzione di lettura corrente (manga = invertita).
    /// `style` è quello del gesto che ha innescato il cambio (tap o swipe/tastiera hanno
    /// impostazioni indipendenti) e decide l'animazione, che viene resa da `pageTurnTransition`.
    /// Quando è attivo il pager nativo (swipe e tap entrambi su "Scorrimento") lo slide dello
    /// swipe non passa da qui: lo gestisce il TabView seguendo il dito.
    private func step(_ direction: Int, provider: ComicPageProvider, style: TapPageTurnStyle) {
        switch pagination(pageCount: provider.pageCount).step(from: currentPage, direction: direction) {
        case .endReached(let triggersNextComic):
            if triggersNextComic, let candidate = nextComicInLibrary {
                pendingNextComic = candidate
            }
        case .beginningReached:
            break
        case .page(let next):
            resetIdleTimerIfNeeded()
            turnStyle = style
            turnDirection = next > currentPage ? 1 : -1
            switch style {
            case .immediate:
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { currentPage = next }
            default:
                withAnimation(.easeInOut(duration: 0.2)) { currentPage = next }
            }
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
            turnStyle = tapPageTurnStyle
            turnDirection = -1
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
            Button(action: exitReader) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Libreria")
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(minHeight: 44)
            }
            // Ritaglio: apre la selezione riquadro (si seleziona sempre un'area, non c'è un
            // tasto "condividi tutta la pagina" a parte).
            Button(action: { isPanelSelectionPresented = true }) {
                Image(systemName: "ellipsis.bubble").frame(width: 44, height: 44)
            }
            Spacer(minLength: 4)
            // Info fumetto (vai-a-pagina/preferiti/direzione lettura): tap prolungato sul
            // titolo, per non aggiungere un'altra icona all'header. I Menu a tendina con
            // contenuti interattivi sono inaffidabili su questo target (vedi ToolsPanelView).
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
    /// le raccogliamo in un menu "..." unico. Il reader non vive in una NavigationStack (vedi
    /// header/chromeBackground sopra), quindi qui non c'è una vera toolbar di sistema che
    /// collassi da sola: il trigger è manuale, su horizontalSizeClass. Su iPad/Mac restano le
    /// singole icone, invariate.
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
        // Non usiamo lo Slider di sistema: sovrapposto al TabView(.page), il suo pan gesture
        // interno perde l'arbitraggio con quello di scroll della pagina (la pagina gira invece
        // di trascinare il pallino — verificato dal vivo, il pallino resta fermo mentre il
        // pager mostra gli indicatori di swipe). Un DragGesture con priorità alta vince sempre
        // sul gesture di swipe sottostante.
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
                            // Trascinando il pallino si attraversano molte pagine di seguito:
                            // animarle una per una sarebbe lento e a scatti.
                            turnStyle = .immediate
                            currentPage = starts.min(by: { abs($0 - target) < abs($1 - target) }) ?? 0
                        }
                )
        }
        .frame(height: 24)
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }

    /// Mostrato mentre il fumetto viene scaricato da iCloud: percentuale reale e possibilità di
    /// annullare senza dover passare dalla schermata Downloads.
    @ViewBuilder
    private func downloadOverlay(progress: Double) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.largeTitle)
                .foregroundColor(chromeForeground)
            Text(comic.title ?? "Fumetto")
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

    private func toggleReadingDirection() {
        comic.readingDirection = comic.readingDirection == .rightToLeft ? .leftToRight : .rightToLeft
        try? context.save()
    }

    private func loadComic() {
        guard provider == nil else { return }
        let url = LibraryStorage.fileURL(forRelativePath: comic.relativePath ?? "")
        let format = comic.format
        let startingPage = Int(comic.lastReadPage)

        // La pagina salvata va ripristinata *prima* che il pager esista, non quando arriva il
        // provider: il pager si costruisce leggendo currentPage, quindi se lo trova ancora a 0 e
        // lo vede cambiare subito dopo esegue uno scorrimento programmatico verso la pagina
        // giusta — e il primo swipe dell'utente, che cade dentro quell'assestamento, viene perso
        // (verificato: aprendo a pagina 1, dove non c'è nulla da ripristinare, il primo swipe
        // funziona). Qui il numero di pagine non è ancora noto: l'allineamento all'inizio dello
        // spread avviene dopo, ed è un no-op a pagina singola.
        currentPage = max(0, startingPage)

        // Il download da iCloud può richiedere più di qualche secondo (file grandi, connessione
        // lenta): lo registriamo nella scheda Downloads con un progresso reale, invece di far
        // fallire il lettore dopo un timeout fisso.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if LibraryStorage.isPendingDownload(url) {
                    let title = comic.title ?? "Fumetto"
                    // La chiave è il percorso del file: riaprire lo stesso fumetto mentre scarica
                    // si aggancia al download già in corso invece di aprirne un secondo.
                    let item = DispatchQueue.main.sync {
                        DownloadManager.shared.register(title: title, key: url.path)
                    }
                    DispatchQueue.main.async {
                        downloadItem = item
                        downloadProgress = item.fractionCompleted
                    }
                    do {
                        try LibraryStorage.downloadIfNeeded(
                            url,
                            isCancelled: { item.isCancelled }
                        ) { progress in
                            // `onProgress` arriva dalla coda principale durante il download, ma
                            // dal thread di background nel caso "già scaricato": non si può
                            // scrivere lo stato senza rimbalzare esplicitamente sul main.
                            DispatchQueue.main.async {
                                item.updateProgress(progress)
                                downloadProgress = progress
                            }
                        }
                    } catch {
                        DispatchQueue.main.async {
                            DownloadManager.shared.remove(item)
                            downloadItem = nil
                            downloadProgress = nil
                        }
                        throw error
                    }
                    DispatchQueue.main.async {
                        DownloadManager.shared.remove(item)
                        downloadItem = nil
                        downloadProgress = nil
                    }
                }
                let loaded = try ComicPageProviderFactory.makeProvider(for: url, format: format)
                DispatchQueue.main.async {
                    provider = loaded
                    #if os(macOS)
                    pageCache = PageImageCache(provider: loaded)
                    #endif
                    let clampedStart = min(startingPage, max(0, loaded.pageCount - 1))
                    let starts = spreadStarts(pageCount: loaded.pageCount)
                    let aligned = starts.last(where: { $0 <= clampedStart }) ?? 0
                    // Solo se serve davvero: riassegnare lo stesso valore è innocuo, ma un valore
                    // diverso qui fa scorrere il pager, ed è esattamente ciò che si vuole evitare
                    // quando la pagina ripristinata era già un inizio di spread valido.
                    if aligned != currentPage { currentPage = aligned }
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
    /// Nei manga il lato sinistro è quello che *avanza*: serve solo alle etichette di
    /// accessibilità, perché l'inversione vera del verso avviene già in `step`.
    let rightToLeft: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleControls: () -> Void
    /// Angoli attivi con "Hot corners": in alto a sinistra esce dalla lettura, in alto a
    /// destra apre le impostazioni, in basso a destra alterna la doppia pagina.
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
                        zone(label: "Esci dalla lettura", action: onExit)
                            .frame(width: 88, height: 88)
                        Spacer()
                        zone(label: "Impostazioni", action: onOpenSettings)
                            .frame(width: 88, height: 88)
                    }
                    mainZones(proxy: proxy)
                    HStack {
                        Spacer()
                        zone(label: "Doppia pagina", action: onToggleDoublePage)
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
            let sharedLabel = oneHandedReversed ? previousLabel : nextLabel
            HStack(spacing: 0) {
                zone(label: sharedLabel, action: sharedAction)
                    .frame(width: min(proxy.size.width * 0.18, 90))
                zone(label: "Mostra o nascondi i controlli", action: onToggleControls)
                zone(label: sharedLabel, action: sharedAction)
                    .frame(width: min(proxy.size.width * 0.18, 90))
            }
        } else {
            HStack(spacing: 0) {
                zone(label: previousLabel, action: onPrevious)
                    .frame(width: min(proxy.size.width * 0.18, 90))
                zone(label: "Mostra o nascondi i controlli", action: onToggleControls)
                zone(label: nextLabel, action: onNext)
                    .frame(width: min(proxy.size.width * 0.18, 90))
            }
        }
    }

    /// `onPrevious`/`onNext` sono la zona sinistra e quella destra: nei manga la sinistra è
    /// quella che manda avanti, quindi le etichette vanno scambiate.
    private var previousLabel: String { rightToLeft ? "Pagina successiva" : "Pagina precedente" }
    private var nextLabel: String { rightToLeft ? "Pagina precedente" : "Pagina successiva" }

    /// Etichetta e trait espliciti: la zona è una `Color.clear`, quindi senza questi VoiceOver
    /// non avrebbe alcun modo di girare pagina (e i test automatici nessun bersaglio).
    private func zone(label: String, action: @escaping () -> Void) -> some View {
        // simultaneousGesture, non .onTapGesture: quest'ultimo reclama il tocco in esclusiva,
        // impedendo allo swipe sottostante di funzionare del tutto.
        Color.clear
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(action))
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
    }
}

/// Mostra una singola pagina, o due affiancate in modalità doppia pagina. In un ambiente
/// con layoutDirection .rightToLeft, l'HStack viene automaticamente rispecchiato da SwiftUI:
/// la pagina con indice più basso resta quindi a destra, come da convenzione manga.
private struct PageSpreadView: View {
    let provider: ComicPageProvider
    let leadingIndex: Int
    /// Con la copertina "da sola" attiva, non tutti gli spread hanno la stessa larghezza (la
    /// copertina è 1 pagina, il resto 2), quindi serve la paginazione intera per sapere se
    /// *questo* spread specifico ne mostra una o due.
    let pagination: ReaderPagination
    let isZoomed: Binding<Bool>
    /// Solo macOS: quando presente, le `PageView` la consultano invece di ridecodificare da
    /// disco a ogni ricomparsa. `nil` su iOS, dove il problema non esiste (la cache di
    /// `UIHostingController` in `PageTurnPager` evita già la ricomparsa).
    var imageCache: PageImageCache?

    /// Vero solo se questo specifico spread contiene due pagine: con `coverIsAlone`, lo
    /// spread che inizia alla copertina (indice 0) resta largo 1 anche a passo 2.
    private var showsSecondPage: Bool {
        guard pagination.pageStep > 1, leadingIndex + 1 < pagination.pageCount else { return false }
        let starts = pagination.spreadStarts
        guard let spreadIndex = starts.firstIndex(of: leadingIndex) else { return pagination.pageStep > 1 }
        let nextStart = spreadIndex + 1 < starts.count ? starts[spreadIndex + 1] : pagination.pageCount
        return nextStart - leadingIndex >= 2
    }

    var body: some View {
        // Il GeometryReader qui (non più dentro ogni PageView) è ciò che permette alle due
        // pagine di uno spread di toccarsi: passando un'altezza fissa e lasciando che la
        // larghezza segua le proporzioni dell'immagine, l'HStack le dimensiona in base al
        // loro contenuto invece di dividere lo spazio a metà a prescindere — che è quello che
        // causava la fascia nera tra le pagine (ciascuna centrata nella propria metà, con
        // margini indipendenti anziché uniti).
        GeometryReader { proxy in
            HStack(spacing: 0) {
                PageView(
                    provider: provider, index: leadingIndex, isDoublePage: pagination.pageStep > 1,
                    isZoomed: isZoomed, imageCache: imageCache,
                    pairedHeight: showsSecondPage ? proxy.size.height : nil
                )
                if showsSecondPage {
                    PageView(
                        provider: provider, index: leadingIndex + 1, isDoublePage: pagination.pageStep > 1,
                        isZoomed: isZoomed, imageCache: imageCache, pairedHeight: proxy.size.height
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
    }
}

private struct PageView: View {
    let provider: ComicPageProvider
    let index: Int
    let isDoublePage: Bool
    let isZoomed: Binding<Bool>
    var imageCache: PageImageCache?
    /// Non-nil solo per una pagina che fa davvero parte di uno spread a due, affiancata a
    /// un'altra pagina "toccante" (vedi `PageSpreadView`): in quel caso la larghezza segue le
    /// proporzioni dell'immagine invece di riempire una metà fissa del riquadro.
    var pairedHeight: CGFloat?
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
    /// pan su una pagina ingrandita — non un filtro estetico permanente, sparisce a fine gesto.
    @State private var motionBlurRadius: CGFloat = 0

    /// "Automatico"/"Adatta pagina" mostrano l'intera pagina (comportamento storico, invariato).
    /// "Adatta larghezza" è l'unico caso che cambia layout: scala alla larghezza disponibile e,
    /// se il risultato eccede l'altezza dello schermo, rende la pagina scorrevole verticalmente.
    private var effectiveZoomMode: PageZoomMode {
        isDoublePage ? doublePageZoomMode : singlePageZoomMode
    }

    var body: some View {
        if let pairedHeight, effectiveZoomMode != .fitWidth {
            pairedContent(height: pairedHeight)
        } else {
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
                            #if os(iOS)
                            // `MagnificationGesture`/`DragGesture` SwiftUI, sovrapposti al pager a
                            // scorrimento (`TabView(.page)`, backed da `UIPageViewController`), perdono
                            // l'arbitraggio dei tocchi a due dita col suo scroll view interno — pinch e
                            // pan restano morti (verificato dal vivo su device). Un vero `UIScrollView`
                            // con zoom nativo (come fa l'app Foto: pinch/pan sono il comportamento di
                            // sistema di uno scroll view zoomabile, non gesture aggiunte sopra) partecipa
                            // allo stesso protocollo di coordinamento gesture di UIKit invece di dover
                            // reinventarlo a mano.
                            ZoomableImageView(image: image, isZoomed: isZoomed)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .overlay(tintOverlay)
                            #else
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
                                // altrimenti ruba il tocco allo swipe-pagina sottostante anche se poi
                                // non fa nulla (guard scale > 1).
                                .gesture(dragGesture, including: scale > 1 ? .all : .subviews)
                                .onTapGesture(count: 2) { toggleZoom() }
                            #endif
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
    }

    /// Percorso per una pagina che tocca l'altra metà dello spread: altezza fissa, larghezza
    /// derivata dalle proporzioni dell'immagine (nessun `GeometryReader` a imporre una metà
    /// fissa, che è la causa dello spazio nero tra le pagine). Non copre "Adatta larghezza",
    /// che resta sullo scroll verticale per-pagina: le due nozioni non si combinano bene
    /// (l'una deriva l'altezza dalla larghezza, l'altra il contrario).
    ///
    /// NOTA: su iOS questo percorso usa ancora il vecchio `magnifyGesture`/`dragGesture`
    /// SwiftUI (non `ZoomableImageView`, vedi sopra), perché qui la larghezza non è nota in
    /// anticipo — deriva dalle proporzioni dell'immagine, e `UIViewRepresentable` non sa fare
    /// da sé quel calcolo come fa `Image` con `.scaledToFit()`. In modalità doppia pagina il
    /// pinch-to-zoom potrebbe quindi avere ancora lo stesso problema di arbitraggio gesture col
    /// pager — non testato dal vivo.
    @ViewBuilder
    private func pairedContent(height: CGFloat) -> some View {
        // Stima 2:3 finché non si conoscono le proporzioni reali: evita che il placeholder
        // salti di dimensione quando l'immagine arriva.
        let estimatedWidth = height * 2 / 3
        Group {
            if let image = image {
                image.asSwiftUIImage
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .blur(radius: motionBlurRadius)
                    .overlay(tintOverlay)
                    .gesture(magnifyGesture)
                    .gesture(dragGesture, including: scale > 1 ? .all : .subviews)
                    .onTapGesture(count: 2) { toggleZoom() }
            } else {
                ProgressView().accentColor(.white)
                    .frame(width: estimatedWidth, height: height)
            }
        }
        .onAppear { loadImage(targetSize: CGSize(width: estimatedWidth, height: height)) }
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

        if let imageCache {
            // Percorso macOS: la cache è quasi sempre già calda grazie al prefetch avviato da
            // `ReaderContentView` quando `currentPage` cambia — questa chiamata torna quasi
            // subito invece di ridecodificare da disco.
            let options = PageImageCache.ProcessingOptions(
                autoCrop: autoCrop,
                autoTintContrast: autoTintContrast,
                upscaleTargetSize: upscale ? targetSize : nil
            )
            Task {
                let loaded = await imageCache.image(at: index, options: options)
                await MainActor.run { self.image = loaded }
            }
            return
        }

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
/// Pinch-to-zoom e pan sulla pagina come in Foto: un vero `UIScrollView` con zoom nativo
/// (`minimumZoomScale`/`maximumZoomScale` + `viewForZooming`), non gesture SwiftUI sovrapposte
/// al pager. È lo `UIScrollView` stesso a "vincere" i tocchi a due dita quando c'è zoom da fare,
/// con l'arbitraggio che UIKit già gestisce per questo identico caso — non un
/// `UIGestureRecognizerDelegate` scritto a mano per riprodurlo (come si è dovuto fare per la
/// luminosità a due dita, che non essendo zoom non può appoggiarsi allo stesso meccanismo).
///
/// Disabilita lo scrolling quando non zoomata (`isScrollEnabled = false` a scale 1): a riposo
/// non c'è nulla da scorrere, e uno scroll view "vuoto" può comunque intercettare tocchi che
/// altrimenti spetterebbero al pager sottostante.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    let isZoomed: Binding<Bool>

    func makeCoordinator() -> Coordinator { Coordinator(isZoomed: isZoomed) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.isScrollEnabled = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.isZoomed = isZoomed
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
            // Cambio pagina: si riparte sempre da non zoomato, come nell'app originale (lo
            // zoom non "segue" da una pagina all'altra).
            scrollView.setZoomScale(1, animated: false)
        }
        context.coordinator.layOutImage(in: scrollView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var isZoomed: Binding<Bool>
        weak var imageView: UIImageView?

        init(isZoomed: Binding<Bool>) { self.isZoomed = isZoomed }

        func layOutImage(in scrollView: UIScrollView) {
            guard let imageView, let image = imageView.image else { return }
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0, image.size.width > 0, image.size.height > 0 else { return }
            let aspect = image.size.width / image.size.height
            var fitSize = boundsSize
            if boundsSize.width / boundsSize.height > aspect {
                fitSize.width = boundsSize.height * aspect
            } else {
                fitSize.height = boundsSize.width / aspect
            }
            if imageView.bounds.size != fitSize {
                imageView.bounds = CGRect(origin: .zero, size: fitSize)
                scrollView.contentSize = fitSize
            }
            center(imageView, in: scrollView)
        }

        private func center(_ imageView: UIImageView, in scrollView: UIScrollView) {
            let boundsSize = scrollView.bounds.size
            var frame = imageView.frame
            frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
            frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
            imageView.frame = frame
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if let imageView { center(imageView, in: scrollView) }
            let zoomed = scrollView.zoomScale > 1.01
            scrollView.isScrollEnabled = zoomed
            if isZoomed.wrappedValue != zoomed { isZoomed.wrappedValue = zoomed }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let targetScale: CGFloat = 2.5
                let point = recognizer.location(in: imageView)
                let size = scrollView.bounds.size
                let width = size.width / targetScale
                let height = size.height / targetScale
                let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

/// Cambia quando cambia qualcosa che obbliga a ricostruire tutte le pagine da zero (il numero
/// di pagine per spread, il verso di lettura, il fumetto stesso): i controller in cache
/// mostrerebbero altrimenti spread composti con le regole vecchie.
private struct PagerResetToken: Hashable {
    let doublePage: Bool
    let rightToLeft: Bool
    let pageCount: Int
}

/// Pager del lettore. Espone `UIPageViewController` perché è l'unico componente che offre sia
/// lo scorrimento interattivo che segue il dito sia un cambio pagina programmatico di cui si
/// possa scegliere l'animazione — le due cose che servono per rendere davvero indipendenti le
/// impostazioni "Tap page-turn" e "Swipe page-turn".
private struct PageTurnPager<Content: View>: UIViewControllerRepresentable {
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
        // funzionante il cambio pagina programmatico.
        pager.dataSource = interactiveSwipe ? coordinator : nil

        if coordinator.resetToken != resetToken {
            coordinator.resetToken = resetToken
            coordinator.discardCachedControllers()
            coordinator.currentIndex = selection
            pager.setViewControllers([coordinator.controller(for: selection)], direction: .forward, animated: false)
            return
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
        var resetToken: PagerResetToken
        private var controllers: [Int: UIHostingController<Content>] = [:]

        init(_ parent: PageTurnPager) {
            self.parent = parent
            self.currentIndex = parent.selection
            self.resetToken = parent.resetToken
        }

        func discardCachedControllers() {
            controllers.removeAll()
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

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Intercetta un pan a due dita per regolare la luminosità dello schermo, senza rubare tocchi
/// alle viste sottostanti (swipe pagina, tap zone, pinch-to-zoom).
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
/// nil in base al numero di dita già premute non funziona, perché un tocco
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

#endif

#if os(macOS)
/// Su Mac non esiste lo swipe a dito: l'equivalente è lo scorrimento orizzontale a due dita sul
/// trackpad (o la rotella orizzontale del mouse), che SwiftUI non espone — DragGesture su Mac
/// segue il trascinamento col tasto premuto, non le due dita. Lo leggiamo quindi dagli eventi
/// scrollWheel, con una soglia e un solo scatto per gesto per non saltare più pagine insieme.
private struct ScrollSwipeMonitor: NSViewRepresentable {
    /// +1 = pagina successiva, -1 = precedente (nel senso di lettura, come lo swipe su iOS).
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitoringView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitoringView)?.onSwipe = onSwipe
    }

    final class MonitoringView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var didFireForCurrentGesture = false

        // Chiamato anche quando la vista *esce* da una finestra: senza le due guardie si
        // accumulerebbe un monitor a ogni riapertura del lettore, e un solo swipe girerebbe
        // altrettante pagine.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                removeMonitor()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            // Il monitor è di app, non di vista: senza questo filtro reagiremmo anche agli
            // scorrimenti sopra le impostazioni o un'altra finestra.
            guard let window = window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            // L'inerzia dopo il rilascio delle dita è la coda dello stesso gesto: contarla
            // farebbe girare una seconda pagina da sola.
            guard event.momentumPhase == [] else { return }

            // Una rotella del mouse tradizionale (non un trackpad) non manda mai `.began`/
            // `.ended`: `event.phase` resta sempre vuoto, quindi il reset legato alle fasi
            // sotto non scatta mai per lei. Va gestita a parte, PRIMA del filtro di dominanza
            // orizzontale sotto — che comunque la include, essendo solo un ulteriore controllo.
            if event.phase.isEmpty {
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
                accumulated += event.scrollingDeltaX
                guard abs(accumulated) > 40 else { return }
                let direction = accumulated < 0 ? 1 : -1
                accumulated = 0
                onSwipe?(direction)
                return
            }

            // Il reset ai bordi del gesto resta incondizionato rispetto alla dominanza
            // orizzontale: un frame di inizio/fine gesto verticale deve comunque azzerare lo
            // stato, altrimenti un gesto successivo può risultare già "consumato" e non girare
            // pagina.
            if event.phase.contains(.began) {
                accumulated = 0
                didFireForCurrentGesture = false
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                accumulated = 0
                didFireForCurrentGesture = false
                return
            }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
            accumulated += event.scrollingDeltaX
            guard !didFireForCurrentGesture, abs(accumulated) > 40 else { return }
            didFireForCurrentGesture = true
            onSwipe?(accumulated < 0 ? 1 : -1)
        }

        private func removeMonitor() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

#endif
