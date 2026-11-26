import SwiftUI

/// Transition style for the page change, used both for "Tap page-turn" and for "Swipe
/// page-turn" (same options for both). With "Scroll" the swipe uses `TabView(.page)`'s
/// native pager on iOS (follows the finger); the other options switch to a manually
/// managed pager — see the note in ReaderView.
enum TapPageTurnStyle: String, CaseIterable, Identifiable {
    case disabled
    case slide
    case immediate
    case fade

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disabled: AppLocalization.localizedString("Disattivato", comment: "Page turn animation")
        case .slide: AppLocalization.localizedString("Scorrimento", comment: "Page turn animation")
        case .immediate: AppLocalization.localizedString("Immediato", comment: "Page turn animation")
        case .fade: AppLocalization.localizedString("Dissolvenza", comment: "Page turn animation")
        }
    }
}

/// How the page is fitted to the screen. "Fit page" shows the whole page; "Fit width" scales
/// to the screen's width, making the page scrollable vertically if it's taller than the screen.
/// A stored "auto" from earlier versions (it behaved exactly like "Fit page") no longer
/// decodes, so `@AppStorage` falls back to the `.fitPage` default.
enum PageZoomMode: String, CaseIterable, Identifiable {
    case fitPage
    case fitWidth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fitPage: AppLocalization.localizedString("Adatta pagina", comment: "Page zoom mode")
        case .fitWidth: AppLocalization.localizedString("Adatta larghezza", comment: "Page zoom mode")
        }
    }
}

/// The reader's page layout, as the settings show it: the same three states the reader's own
/// button cycles through, stored in the two keys the reader reads (`doublePageAutoMode`,
/// `doublePageMode`). A plain "double page by default" toggle only set the second key, which
/// "Automatico" (the default) ignores.
enum PageLayoutChoice: String, CaseIterable, Identifiable {
    case automatic, single, double

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: AppLocalization.localizedString("Automatico", comment: "Page layout")
        case .single: AppLocalization.localizedString("Pagina singola", comment: "Page layout")
        case .double: AppLocalization.localizedString("Doppia pagina", comment: "Page layout")
        }
    }

    static func binding(autoMode: Binding<Bool>, doublePage: Binding<Bool>) -> Binding<PageLayoutChoice> {
        Binding(
            get: { autoMode.wrappedValue ? .automatic : (doublePage.wrappedValue ? .double : .single) },
            set: { choice in
                autoMode.wrappedValue = choice == .automatic
                if choice != .automatic { doublePage.wrappedValue = choice == .double }
            }
        )
    }
}

/// "ⓘ" icon with a pop-up explanation.
struct InfoButton: View {
    let text: LocalizedStringKey
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .platformPopover(isPresented: $isPresented) {
            infoText.presentationCompactAdaptation(.popover)
        }
    }

    private var infoText: some View {
        Text(text)
            .font(.footnote)
            .multilineTextAlignment(.leading)
            // The fixed width must be given to the Text *before* the padding: without a
            // concrete width the popover proposes an ambiguous size and the computed height
            // truncates the last lines.
            .frame(width: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding()
    }
}

/// `compact: true` omits the trailing Spacer: use it for a Picker's label, where SwiftUI
/// already adds the current value and the little arrow after the whole label on its own —
/// a Spacer here would make it expand awkwardly instead of staying compact next to the title.
func infoLabel(_ title: LocalizedStringKey, info: LocalizedStringKey, compact: Bool = false) -> some View {
    HStack(spacing: compact ? 4 : nil) {
        Text(title)
        if !compact { Spacer() }
        InfoButton(text: info)
    }
}

@available(*, deprecated, renamed: "infoLabel")
func labelWithInfo(_ title: LocalizedStringKey, info: LocalizedStringKey, compact: Bool = false) -> some View {
    infoLabel(title, info: info, compact: compact)
}

struct SettingsView: View {
    @AppStorage("defaultReadingDirection") private var defaultReadingDirectionRawValue = ReadingDirection.leftToRight.rawValue
    @AppStorage("doublePageMode") private var isDoublePageEnabled = false
    @AppStorage("doublePageAutoMode") private var isDoublePageAutoMode = true
    @AppStorage("doublePageCoverAlone") private var isCoverAlone = true
    @AppStorage("tapPageTurnStyle") private var tapPageTurnStyle = TapPageTurnStyle.slide
    @AppStorage("swipePageTurnStyle") private var swipePageTurnStyle = TapPageTurnStyle.slide
    @AppStorage("fadeTransitionDuration") private var fadeTransitionDuration = 0.25
    @AppStorage("tapToPanEnabled") private var isTapToPanEnabled = false
    @AppStorage("hotCornersEnabled") private var isHotCornersEnabled = false
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    @AppStorage("twoFingerBrightnessEnabled") private var isTwoFingerBrightnessEnabled = true
    @AppStorage("singlePageZoomMode") private var singlePageZoomMode = PageZoomMode.fitPage
    @AppStorage("doublePageZoomMode") private var doublePageZoomMode = PageZoomMode.fitPage
    #if os(macOS)
    @AppStorage("includeInBackup") private var isIncludedInBackup = true
    #endif

    private var defaultReadingDirection: Binding<ReadingDirection> {
        Binding(
            get: { ReadingDirection(rawValue: defaultReadingDirectionRawValue) ?? .leftToRight },
            set: { defaultReadingDirectionRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section(
                header: Text("Lettura"),
                footer: Text("La direzione predefinita si applica ai nuovi fumetti importati. Puoi comunque cambiarla per ogni fumetto dal lettore.")
            ) {
                Picker("Direzione predefinita", selection: defaultReadingDirection) {
                    ForEach(ReadingDirection.allCases) { direction in
                        Text(direction.label).tag(direction)
                    }
                }
                #if os(iOS)
                .pickerStyle(.inline)
                #endif
                Picker("Pagine", selection: PageLayoutChoice.binding(autoMode: $isDoublePageAutoMode, doublePage: $isDoublePageEnabled)) {
                    ForEach(PageLayoutChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                Toggle(isOn: $isCoverAlone) {
                    infoLabel("Copertina da sola", info: "In doppia pagina, mostra sempre la prima pagina (di solito la copertina) da sola invece che affiancata alla seconda. L'accoppiamento a due pagine riprende dalla seconda pagina in poi.")
                }
            }

            Section(
                header: Text("Zoom"),
                footer: Text("\"Adatta pagina\" mostra sempre l'intera pagina. \"Adatta larghezza\" scala alla larghezza dello schermo e rende la pagina scorrevole verticalmente se più alta dello schermo.")
            ) {
                Picker("Pagine singole", selection: $singlePageZoomMode) {
                    ForEach(PageZoomMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                #if os(macOS)
                // iPhone/iPad zoom a double spread as one pair (`SpreadPairView`), always
                // fitted to the screen: a "Fit width" choice for it would do nothing there.
                Picker("Pagine doppie", selection: $doublePageZoomMode) {
                    ForEach(PageZoomMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                #endif
            }

            Section(header: Text("Navigazione")) {
                Toggle(isOn: $isTapToPanEnabled) {
                    infoLabel("Avanza al tocco sui bordi", info: "Toccando il bordo destro o quello sinistro si va sempre avanti: puoi sfogliare con il pollice senza raggiungere il lato opposto. La fascia centrale resta per mostrare o nascondere i controlli.")
                }
                .disabled(tapPageTurnStyle == .disabled)
                Toggle(isOn: $isHotCornersEnabled) {
                    infoLabel("Angoli attivi", info: "Angoli per raggiungere velocemente alcuni controlli comuni senza richiamare i controlli. Tocca l'angolo in alto a sinistra per uscire dalla lettura, in alto a destra per gli strumenti, in basso a destra per alternare la doppia pagina.")
                }
                .disabled(tapPageTurnStyle == .disabled)
                #if os(iOS)
                Toggle(isOn: $isTwoFingerBrightnessEnabled) {
                    infoLabel("Luminosità con due dita", info: "Se attivo, puoi regolare la luminosità dello schermo trascinando su e giù con due dita nella vista di lettura.")
                }
                #endif
                Picker("Cambio pagina al tocco", selection: $tapPageTurnStyle) {
                    ForEach(TapPageTurnStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                Picker("Cambio pagina con scorrimento", selection: $swipePageTurnStyle) {
                    ForEach(TapPageTurnStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                #if os(iOS)
                // Only affects the iOS pager's cross-dissolve (`PageCollectionPager`):
                // macOS's `.fade` still uses the plain SwiftUI `.opacity` transition, so
                // the slider stays off there rather than sitting next to a control with no
                // visible effect.
                if tapPageTurnStyle == .fade || swipePageTurnStyle == .fade {
                    VStack(alignment: .leading) {
                        Text("Velocità dissolvenza")
                        HStack {
                            Text("Veloce").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $fadeTransitionDuration, in: 0.1...0.6)
                            Text("Lenta").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                #endif
            }

            Section(
                header: Text("Qualità immagine")
            ) {
                Toggle(isOn: $isAutoCropEnabled) {
                    infoLabel("Ritaglia bordi bianchi", info: "Ritaglia i margini bianchi dei fumetti per sfruttare al meglio lo spazio sullo schermo.")
                }
                Toggle(isOn: $isAutoTintContrastEnabled) {
                    infoLabel("Tinta e contrasto automatici", info: "Corregge pagine ingiallite e inchiostro sbiadito. Lascialo disattivato per fumetti già di buona qualità.")
                }
                Toggle(isOn: $isUpscalingEnabled) {
                    infoLabel("Upscaling pagine a bassa risoluzione", info: "Ingrandisce le pagine a bassa risoluzione con un filtro di qualità invece del semplice ridimensionamento, per tavole più nitide.")
                }
            }

            Section(header: Text("Aspetto")) {
                NavigationLink("Colori", destination: ColorThemeView())
                NavigationLink("Lingua", destination: AppLanguageSettings())
            }

            Section(header: Text("Libreria e sincronizzazione")) {
                NavigationLink("Stato iCloud", destination: ICloudStatusView())
                #if os(macOS)
                // Without iCloud the library folder lives inside the sandbox container
                // (~/Library/Containers/com.scunio.Chunky/...), which nobody finds on their
                // own in the Finder: a direct way to get there, instead of leaving it hidden.
                Button("Mostra la cartella della libreria nel Finder") {
                    RevealInFinder.reveal(LibraryStorage.rootFolderURL())
                }
                // Time Machine: on iPhone/iPad the library sits in iCloud Drive, which the
                // device backup never includes anyway, so the toggle is Mac-only.
                Toggle("Includi fumetti nel backup", isOn: Binding(
                    get: { isIncludedInBackup },
                    set: { newValue in
                        isIncludedInBackup = newValue
                        LibraryStorage.setExcludedFromBackup(!newValue)
                    }
                ))
                #endif
            }

            RebuildLibrarySection()

            Section(header: Text("Privacy")) {
                NavigationLink("Blocco genitori", destination: ParentalLockSettingsView())
            }

            // Support: for when something goes wrong, so after everything else.
            Section(header: Text("Supporto")) {
                NavigationLink("Diagnostica", destination: DiagnosticsView())
                Button(action: ToolsPanelView.sendFeedbackEmail) {
                    Label("Feedback / Segnala un problema", systemImage: "envelope")
                }
            }

            Section(header: Text("Informazioni")) {
                HStack {
                    Text("Versione")
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(.secondary)
                }
                NavigationLink("Licenze open source", destination: AcknowledgementsView())
            }
        }
        #if os(macOS)
        // Without an explicit style, a Form pushed into a NavigationStack (not root) on
        // macOS falls back to a flat list with no grouped backgrounds — verified live,
        // completely different look from the same Form shown as the root.
        .formStyle(.grouped)
        // A `maxHeight` here would clip the excess content with no scrolling (verified:
        // that's exactly what happened). Just a width limit, and the window — made
        // resizable in ChunkyApp.swift — can open shorter and let the Form scroll on its
        // own, like any other scrollable list/form.
        .frame(maxWidth: 600)
        #endif
        .navigationTitle("Impostazioni")
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
}
