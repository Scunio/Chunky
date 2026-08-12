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
    @AppStorage("doublePageMode") private var isDoublePageEnabled = false
    @AppStorage("tapToTurnEnabled") private var isTapToTurnEnabled = true
    @AppStorage("oneHandedMode") private var isOneHandedModeEnabled = false
    @AppStorage("hotCornersEnabled") private var isHotCornersEnabled = false
    @AppStorage("twoFingerBrightnessEnabled") private var isTwoFingerBrightnessEnabled = true
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var provider: ComicPageProvider?
    /// Indice della pagina "principale" (la prima, più a sinistra in LTR) dello spread corrente.
    @State private var currentPage: Int = 0
    @State private var loadError: String?
    @State private var isControlsVisible = true
    @State private var isSharePresented = false
    @State private var shareImage: PlatformImage?
    @State private var pendingNextComic: ComicEntity?
    @State private var isPanelSelectionPresented = false
    @State private var pendingCropShareImage: PlatformImage?
    @State private var isPageJumpPresented = false
    @State private var jumpPageNumber = 1
    @State private var isInfoPresented = false
    @State private var isToolsColorsPresented = false
    @State private var isToolsSettingsPresented = false
    @State private var isToolsParentalLockPresented = false
    @State private var isToolsICloudPresented = false
    @State private var isNowReadingPresented = false

    /// Due pagine verticali affiancate su uno schermo stretto di iPhone lasciano un vuoto enorme
    /// sopra e sotto (l'immagine combinata è troppo larga rispetto all'altezza disponibile):
    /// la doppia pagina ha senso solo con più spazio orizzontale (iPad, Mac).
    private var isDoublePageAllowed: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        true
        #endif
    }

    private var pageStep: Int { (isDoublePageEnabled && isDoublePageAllowed) ? 2 : 1 }

    /// Indici di inizio di ogni spread (1 o 2 pagine), usati come "tag"/passi di navigazione.
    private func spreadStarts(pageCount: Int) -> [Int] {
        Array(stride(from: 0, to: pageCount, by: pageStep))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let provider = provider {
                #if os(iOS)
                iOSPager(provider: provider)
                #else
                macOSPager(provider: provider)
                #endif
            } else if let loadError = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.yellow)
                    Text(loadError)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else {
                ProgressView().accentColor(.white)
            }

            #if os(iOS)
            if isTwoFingerBrightnessEnabled {
                TwoFingerBrightnessView { delta in
                    UIScreen.main.brightness = min(max(UIScreen.main.brightness + delta, 0), 1)
                }
            }
            #endif

            if isControlsVisible {
                VStack {
                    header
                    Spacer()
                    footer
                }
                .allowsHitTesting(true)
            }

            if let next = pendingNextComic {
                nextComicConfirmation(next)
            }

            if isPageJumpPresented, let provider = provider {
                pageJumpCard(provider: provider)
            }
        }
        #if os(iOS)
        .statusBar(hidden: !isControlsVisible)
        #endif
        .onAppear(perform: loadComic)
        .onChange(of: currentPage) { newValue in
            guard let provider = provider else { return }
            comic.lastReadPage = Int32(min(max(newValue, 0), provider.pageCount - 1))
            comic.dateLastOpened = Date()
            try? context.save()
        }
        .onChange(of: isDoublePageEnabled) { _ in
            // Cambiando il passo di pagina, l'indice corrente potrebbe non essere più
            // un inizio-spread valido (es. da pagina pari a passo 2): lo riallineiamo,
            // altrimenti il tag del TabView non trova corrispondenza e mostra la pagina sbagliata.
            guard let provider = provider else { return }
            let starts = spreadStarts(pageCount: provider.pageCount)
            currentPage = starts.last(where: { $0 <= currentPage }) ?? 0
        }
        #if os(iOS)
        .sheet(isPresented: $isSharePresented) {
            if let shareImage = shareImage {
                ActivityShareSheet(activityItems: [shareImage])
            }
        }
        #endif
        .sheet(isPresented: $isPanelSelectionPresented, onDismiss: {
            // Il foglio di condivisione va aperto solo a chiusura completata di questo sheet,
            // altrimenti su iOS le due presentazioni sovrapposte possono fallire silenziosamente.
            if let pending = pendingCropShareImage {
                pendingCropShareImage = nil
                presentShareImage(pending)
            }
        }) {
            if let provider = provider {
                PanelSelectionView(pageIndex: currentPage, provider: provider) { cropped in
                    pendingCropShareImage = cropped
                    isPanelSelectionPresented = false
                }
            }
        }
        .sheet(isPresented: $isInfoPresented) {
            ComicInfoSheet(comic: comic, loadedPageCount: provider?.pageCount)
        }
        .sheet(isPresented: $isToolsColorsPresented) {
            NavigationView { ColorThemeView().toolbarDoneButton { isToolsColorsPresented = false } }
        }
        .sheet(isPresented: $isToolsSettingsPresented) {
            NavigationView { SettingsView().toolbarDoneButton { isToolsSettingsPresented = false } }
        }
        .sheet(isPresented: $isToolsParentalLockPresented) {
            NavigationView { ParentalLockSettingsView().toolbarDoneButton { isToolsParentalLockPresented = false } }
        }
        .sheet(isPresented: $isToolsICloudPresented) {
            NavigationView { ICloudStatusView().toolbarDoneButton { isToolsICloudPresented = false } }
        }
        .sheet(isPresented: $isNowReadingPresented) {
            NowReadingView(comic: comic) { isNowReadingPresented = false }
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
    private func iOSPager(provider: ComicPageProvider) -> some View {
        ZStack {
            TabView(selection: $currentPage) {
                ForEach(spreadStarts(pageCount: provider.pageCount), id: \.self) { start in
                    PageSpreadView(provider: provider, leadingIndex: start, isDoublePage: isDoublePageEnabled && isDoublePageAllowed)
                        .tag(start)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .environment(\.layoutDirection, comic.readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)

            if isTapToTurnEnabled {
                PageTapZones(oneHanded: isOneHandedModeEnabled, hotCorners: isHotCornersEnabled) {
                    step(-1, provider: provider)
                } onNext: {
                    step(1, provider: provider)
                } onToggleControls: {
                    isControlsVisible.toggle()
                }
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    // simultaneousGesture, non .onTapGesture: quest'ultimo reclama il tocco in
                    // esclusiva e impedisce allo swipe nativo del TabView sottostante di funzionare.
                    .simultaneousGesture(TapGesture().onEnded { isControlsVisible.toggle() })
            }
        }
    }
    #else
    private func macOSPager(provider: ComicPageProvider) -> some View {
        ZStack {
            PageSpreadView(provider: provider, leadingIndex: currentPage, isDoublePage: isDoublePageEnabled && isDoublePageAllowed)
                .id(currentPage)
                .environment(\.layoutDirection, comic.readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)

            if isTapToTurnEnabled {
                PageTapZones(oneHanded: isOneHandedModeEnabled, hotCorners: isHotCornersEnabled) {
                    step(-1, provider: provider)
                } onNext: {
                    step(1, provider: provider)
                } onToggleControls: {
                    isControlsVisible.toggle()
                }
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isControlsVisible.toggle() }
            }
        }
        .background(KeyEventMonitor { keyCode in
            switch keyCode {
            case .leftArrow: step(-1, provider: provider)
            case .rightArrow: step(1, provider: provider)
            case .space: step(1, provider: provider)
            }
        })
    }
    #endif

    /// Avanza/retrocede di uno spread, rispettando la direzione di lettura corrente (manga = invertita).
    private func step(_ direction: Int, provider: ComicPageProvider) {
        let effectiveDirection = (comic.readingDirection == .rightToLeft ? -direction : direction) * pageStep
        let next = currentPage + effectiveDirection
        if next >= provider.pageCount {
            if direction > 0, let candidate = nextComicInLibrary {
                pendingNextComic = candidate
            }
            return
        }
        guard next >= 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentPage = next
        }
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
        HStack {
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Libreria")
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.45)))
            }
            Menu {
                Button(action: {
                    jumpPageNumber = currentPage + 1
                    isPageJumpPresented = true
                }) {
                    Label("Vai a pagina...", systemImage: "number")
                }
                Button(action: { isInfoPresented = true }) {
                    Label("Info fumetto", systemImage: "info.circle")
                }
                Button(action: toggleFavorite) {
                    Label(
                        comic.isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                        systemImage: comic.isFavorite ? "star.fill" : "star"
                    )
                }
                Button(action: toggleReadingDirection) {
                    Label(
                        comic.readingDirection == .rightToLeft ? "Direzione: occidentale" : "Direzione: manga",
                        systemImage: comic.readingDirection == .rightToLeft ? "arrow.right" : "arrow.left"
                    )
                }
                Button(action: { isNowReadingPresented = true }) {
                    Label("Ora in lettura", systemImage: "book")
                }
            } label: {
                Image(systemName: "ellipsis.bubble")
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            Spacer()
            Text(comic.title ?? "")
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
            // Busta: apre la selezione riquadro, l'unico modo per condividere nell'originale
            // (si seleziona sempre un'area, non c'è un tasto "condividi tutta la pagina" a parte).
            Button(action: { isPanelSelectionPresented = true }) {
                Image(systemName: "envelope")
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            if isDoublePageAllowed {
                Button(action: { isDoublePageEnabled.toggle() }) {
                    Image(systemName: isDoublePageEnabled ? "book.fill" : "book")
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
            }
            Button(action: { isToolsICloudPresented = true }) {
                Image(systemName: "icloud")
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            Menu {
                Button(action: { isToolsColorsPresented = true }) {
                    Label("Colori", systemImage: "paintpalette")
                }
                Button(action: { isToolsSettingsPresented = true }) {
                    Label("Impostazioni", systemImage: "gearshape")
                }
                Button(action: { isToolsParentalLockPresented = true }) {
                    Label("Blocco genitori", systemImage: "lock")
                }
            } label: {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
        }
        .padding()
        .buttonStyle(PlainButtonStyle())
    }

    private var footer: some View {
        Group {
            if let provider = provider, provider.pageCount > 1 {
                VStack(spacing: 6) {
                    pageSlider(provider: provider)
                    let upperBound = min(currentPage + pageStep, provider.pageCount)
                    let label = upperBound - currentPage > 1
                        ? "\(currentPage + 1)–\(upperBound) / \(provider.pageCount)"
                        : "\(currentPage + 1) / \(provider.pageCount)"
                    Text(label)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            }
        }
    }

    private func pageSlider(provider: ComicPageProvider) -> some View {
        let sliderBinding = Binding<Double>(
            get: { Double(currentPage) },
            set: { newValue in
                let starts = spreadStarts(pageCount: provider.pageCount)
                let nearest = starts.min(by: { abs($0 - Int(newValue)) < abs($1 - Int(newValue)) }) ?? 0
                currentPage = nearest
            }
        )
        let maxValue = Double(max(provider.pageCount - 1, 0))
        // Lo Slider di sistema, su uno sfondo scuro, ha una traccia quasi invisibile (resta
        // visibile solo il pallino): disegniamo una traccia nostra dietro e rendiamo
        // trasparente quella nativa, mantenendo il pallino bianco di sistema.
        return ZStack {
            GeometryReader { proxy in
                let progress = maxValue > 0 ? CGFloat(currentPage) / CGFloat(maxValue) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(Color.white).frame(width: proxy.size.width * progress)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
            }
            Slider(value: sliderBinding, in: 0...maxValue, step: 1)
                .accentColor(.clear)
        }
        .frame(height: 24)
        .environment(\.layoutDirection, comic.readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }

    private func toggleReadingDirection() {
        comic.readingDirection = comic.readingDirection == .rightToLeft ? .leftToRight : .rightToLeft
        try? context.save()
    }


    private func loadComic() {
        guard provider == nil else { return }
        let url = LibraryStorage.fileURL(forRelativePath: comic.relativePath ?? "")
        let format = comic.format
        let resetPolicyRawValue = UserDefaults.standard.string(forKey: "resetToFirstPagePolicy")
        let resetPolicy = ResetToFirstPagePolicy(rawValue: resetPolicyRawValue ?? "") ?? .never
        let startingPage = (resetPolicy == .always && comic.isFinished) ? 0 : Int(comic.lastReadPage)

        // Il download da iCloud può richiedere qualche secondo: eseguito fuori dal thread
        // principale così l'interfaccia resta reattiva mentre mostriamo il loading spinner.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try LibraryStorage.ensureDownloaded(url)
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
/// per mostrare/nascondere i controlli, oppure — in modalità "una mano" — metà superiore/inferiore
/// per restare comodo con il pollice mentre si tiene il telefono con una mano sola.
private struct PageTapZones: View {
    let oneHanded: Bool
    let hotCorners: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleControls: () -> Void

    var body: some View {
        GeometryReader { proxy in
            if hotCorners {
                ZStack {
                    zone(action: onToggleControls)
                    VStack {
                        Spacer()
                        HStack {
                            zone(action: onPrevious)
                                .frame(width: 88, height: 88)
                            Spacer()
                            zone(action: onNext)
                                .frame(width: 88, height: 88)
                        }
                    }
                }
            } else if oneHanded {
                VStack(spacing: 0) {
                    zone(action: onPrevious)
                        .frame(height: proxy.size.height * 0.35)
                    zone(action: onToggleControls)
                        .frame(height: proxy.size.height * 0.3)
                    zone(action: onNext)
                        .frame(height: proxy.size.height * 0.35)
                }
            } else {
                HStack(spacing: 0) {
                    zone(action: onPrevious)
                        .frame(width: proxy.size.width * 0.3)
                    zone(action: onToggleControls)
                        .frame(width: proxy.size.width * 0.4)
                    zone(action: onNext)
                        .frame(width: proxy.size.width * 0.3)
                }
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

    var body: some View {
        HStack(spacing: 0) {
            PageView(provider: provider, index: leadingIndex)
            if isDoublePage, leadingIndex + 1 < provider.pageCount {
                PageView(provider: provider, index: leadingIndex + 1)
            }
        }
    }
}

private struct PageView: View {
    let provider: ComicPageProvider
    let index: Int
    @ObservedObject private var theme = AppTheme.shared
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    @State private var image: PlatformImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image = image {
                    image.asSwiftUIImage
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .overlay(tintOverlay)
                        .gesture(magnifyGesture)
                        .gesture(dragGesture)
                        .onTapGesture(count: 2) { toggleZoom() }
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
            }
            .onEnded { _ in
                lastScale = scale
                if scale == 1 { offset = .zero; lastOffset = .zero }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in lastOffset = offset }
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

/// Intercetta un pan a due dita (ignorando quelli a un dito, così non ruba i tap per cambiare
/// pagina) per regolare la luminosità dello schermo, come "Two-finger-swipe brightness"
/// nell'app originale.
private struct TwoFingerBrightnessView: UIViewRepresentable {
    /// Delta verticale normalizzato (-1...1) da sommare alla luminosità corrente.
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = PassthroughUnlessTwoTouchesView()
        view.backgroundColor = .clear
        let recognizer = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 2
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
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

        /// Lascia passare anche i gesture di SwiftUI sotto (tap zone, swipe pagina):
        /// questo riconoscitore deve coesistere con quelli, non sostituirli.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
}

/// Una UIView a schermo intero, se coperta da hit-testing normale, intercetta OGNI tocco
/// (anche a un dito) perché è la vista più in alto: pur non avendo un gesture che riconosce
/// un solo dito, il tocco resta comunque "catturato" qui e non arriva mai al TabView sotto
/// (niente swipe pagina, niente tap zone). Restituendo nil da hitTest per i tocchi singoli,
/// li lasciamo passare attraverso; solo con 2+ dita questa vista li intercetta davvero.
private final class PassthroughUnlessTwoTouchesView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let touches = event?.allTouches, touches.count >= 2 else { return nil }
        return super.hitTest(point, with: event)
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
