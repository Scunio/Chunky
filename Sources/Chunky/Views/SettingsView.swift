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
        case .disabled: "Disattivato"
        case .slide: "Scorrimento"
        case .immediate: "Immediato"
        case .fade: "Dissolvenza"
        }
    }
}

/// How the page is fitted to the screen. "Fit page" shows the whole page (current/original
/// behavior); "Fit width" scales to the screen's width, making the page scrollable
/// vertically if it's taller than the screen.
enum PageZoomMode: String, CaseIterable, Identifiable {
    case auto
    case fitPage
    case fitWidth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Automatico"
        case .fitPage: "Adatta pagina"
        case .fitWidth: "Adatta larghezza"
        }
    }
}

/// The observed options for the reset-to-page-1 timer after inactivity (a feature designed
/// for "showcase/kiosk" use, related to Kiosk Mode): the number is in seconds, 0 = "Never".
enum ReaderIdleResetOption: Int, CaseIterable, Identifiable {
    case never = 0
    case seconds10 = 10
    case seconds20 = 20
    case seconds30 = 30
    case minute1 = 60
    case minutes2 = 120
    case minutes3 = 180

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .never: "Mai"
        case .seconds10: "Dopo 10 secondi"
        case .seconds20: "Dopo 20 secondi"
        case .seconds30: "Dopo 30 secondi"
        case .minute1: "Dopo 1 minuto"
        case .minutes2: "Dopo 2 minuti"
        case .minutes3: "Dopo 3 minuti"
        }
    }
}

/// "ⓘ" icon with a pop-up explanation.
struct InfoButton: View {
    let text: String
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
func labelWithInfo(_ title: String, info: String, compact: Bool = false) -> some View {
    HStack(spacing: compact ? 4 : nil) {
        Text(title)
        if !compact { Spacer() }
        InfoButton(text: info)
    }
}

struct SettingsView: View {
    @AppStorage("defaultReadingDirection") private var defaultReadingDirectionRawValue = ReadingDirection.leftToRight.rawValue
    @AppStorage("doublePageMode") private var isDoublePageEnabled = false
    @AppStorage("doublePageCoverAlone") private var isCoverAlone = true
    @AppStorage("tapPageTurnStyle") private var tapPageTurnStyle = TapPageTurnStyle.slide
    @AppStorage("swipePageTurnStyle") private var swipePageTurnStyle = TapPageTurnStyle.slide
    @AppStorage("fadeTransitionDuration") private var fadeTransitionDuration = 0.25
    @AppStorage("tapToPanEnabled") private var isTapToPanEnabled = false
    @AppStorage("oneHandedMode") private var isOneHandedModeEnabled = false
    @AppStorage("hotCornersEnabled") private var isHotCornersEnabled = false
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("motionBlurEnabled") private var isMotionBlurEnabled = true
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false
    @AppStorage("kioskModeEnabled") private var isKioskModeEnabled = false
    @AppStorage("twoFingerBrightnessEnabled") private var isTwoFingerBrightnessEnabled = true
    @AppStorage("singlePageZoomMode") private var singlePageZoomMode = PageZoomMode.auto
    @AppStorage("doublePageZoomMode") private var doublePageZoomMode = PageZoomMode.auto
    @AppStorage("readerIdleResetSeconds") private var readerIdleReset = ReaderIdleResetOption.never
    @AppStorage("crashReportingEnabled") private var isCrashReportingEnabled = true
    @AppStorage("includeInBackup") private var isIncludedInBackup = false

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
                footer: Text("Si applica ai nuovi fumetti importati. Puoi comunque cambiare la direzione per ogni fumetto dal lettore.")
            ) {
                Picker("Direzione predefinita", selection: defaultReadingDirection) {
                    ForEach(ReadingDirection.allCases) { direction in
                        Text(direction.label).tag(direction)
                    }
                }
                #if os(iOS)
                .pickerStyle(.inline)
                #endif
                Toggle("Doppia pagina di default", isOn: $isDoublePageEnabled)
                Toggle(isOn: $isCoverAlone) {
                    labelWithInfo("Copertina da sola", info: "In doppia pagina, mostra sempre la prima pagina (di solito la copertina) da sola invece che affiancata alla seconda. L'accoppiamento a due pagine riprende dalla seconda pagina in poi.")
                }
            }

            Section(header: Text("Navigazione")) {
                Toggle(isOn: $isTapToPanEnabled) {
                    labelWithInfo("Tap-to-pan", info: "Toccando un bordo qualsiasi si va sempre avanti, invece che indietro/avanti a seconda del lato. Comodo se tieni il tablet/telefono in una posizione scomoda per raggiungere entrambi i lati. Non si applica con la modalità una mano attiva, che già unifica le due zone a modo suo (vedi sotto).")
                }
                .disabled(isOneHandedModeEnabled)
                Toggle(isOn: $isOneHandedModeEnabled) {
                    labelWithInfo("Modalità una mano", info: "Le zone di tap per cambiare pagina diventano orizzontali (alto/basso) invece che laterali, più comode da raggiungere con il pollice.")
                }
                .disabled(tapPageTurnStyle == .disabled)
                Toggle(isOn: $isHotCornersEnabled) {
                    labelWithInfo("Hot corners", info: "Angoli per raggiungere velocemente alcuni controlli comuni senza richiamare i controlli. Tocca l'angolo in alto a sinistra per uscire dalla lettura, in alto a destra per le impostazioni, in basso a destra per alternare la doppia pagina.")
                }
                .disabled(tapPageTurnStyle == .disabled)
                #if os(iOS)
                Toggle(isOn: $isTwoFingerBrightnessEnabled) {
                    labelWithInfo("Luminosità con due dita", info: "Se attivo, puoi regolare la luminosità dello schermo trascinando su e giù con due dita nella vista di lettura.")
                }
                #endif
                Picker("Tap page-turn", selection: $tapPageTurnStyle) {
                    ForEach(TapPageTurnStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                Picker("Swipe page-turn", selection: $swipePageTurnStyle) {
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

            Section(header: Text("Aspetto")) {
                NavigationLink("Colori", destination: ColorThemeView())
            }

            Section(
                header: Text("Qualità immagine"),
                footer: Text("L'upscaling migliora le pagine a bassa risoluzione con un filtro di qualità superiore al semplice ridimensionamento. Il ritaglio bordi rimuove automaticamente i margini bianchi delle scansioni.")
            ) {
                Toggle(isOn: $isAutoCropEnabled) {
                    labelWithInfo("Ritaglia bordi bianchi", info: "Ritaglia i margini bianchi dei fumetti per sfruttare al meglio lo spazio sullo schermo.")
                }
                Toggle(isOn: $isAutoTintContrastEnabled) {
                    labelWithInfo("Auto tint & contrasto", info: "Corregge pagine ingiallite e inchiostro sbiadito. Lascialo disattivato per fumetti già di buona qualità.")
                }
                Toggle(isOn: $isUpscalingEnabled) {
                    labelWithInfo("Upscaling pagine a bassa risoluzione", info: "Migliora in modo intelligente la nitidezza delle tavole nei fumetti a bassa risoluzione.")
                }
                Toggle(isOn: $isMotionBlurEnabled) {
                    labelWithInfo("Motion-blur", info: "Rende più fluido il movimento quando scorri con il dito una pagina ingrandita.")
                }
            }

            Section(header: Text("Privacy")) {
                NavigationLink("Blocco genitori", destination: ParentalLockSettingsView())
                Toggle("Modalità Kiosk", isOn: $isKioskModeEnabled)
            }

            Section(
                header: Text("Avanzate"),
                footer: Text("Se disattivato, la cartella dei fumetti non viene inclusa nei backup di iCloud/iTunes — utile per risparmiare spazio se hai già una copia altrove.")
            ) {
                NavigationLink("Diagnostica", destination: DiagnosticsView())
                NavigationLink("Stato iCloud", destination: ICloudStatusView())
                #if os(macOS)
                // Without iCloud the library folder lives inside the sandbox container
                // (~/Library/Containers/com.scunio.Chunky/...), which nobody finds on their
                // own in the Finder: a direct way to get there, instead of leaving it hidden.
                Button("Mostra la cartella della libreria nel Finder") {
                    RevealInFinder.reveal(LibraryStorage.rootFolderURL())
                }
                #endif
                Toggle("Includi fumetti nel backup", isOn: Binding(
                    get: { isIncludedInBackup },
                    set: { newValue in
                        isIncludedInBackup = newValue
                        LibraryStorage.setExcludedFromBackup(!newValue)
                    }
                ))
                HStack {
                    Text("Ordinamento pagine")
                    InfoButton(text: "Se le pagine di un fumetto appaiono in un ordine strano (es. le doppie pagine finiscono in fondo), questa impostazione può aiutare a risolvere il problema. Per avere effetto devi uscire e rientrare nella lettura.")
                    Spacer()
                    Text("Automatico")
                        .foregroundColor(.secondary)
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
                Picker("Pagine doppie", selection: $doublePageZoomMode) {
                    ForEach(PageZoomMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section(
                header: Text("Inattività"),
                footer: Text("Se il lettore resta inattivo per il tempo scelto, torna automaticamente a pagina 1 — pensato per l'uso a schermo esposto (vetrina/kiosk), non per l'uso quotidiano.")
            ) {
                Picker(selection: $readerIdleReset) {
                    ForEach(ReaderIdleResetOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    labelWithInfo("Riparti dalla prima pagina", info: "Difficilmente ti servirà, ma se ne hai bisogno eccolo qui.", compact: true)
                }
            }

            // MetricKit, on which this feature depends, doesn't exist on macOS: showing
            // the toggle there would mean promising something that does nothing.
            #if os(iOS)
            Section(
                header: Text("Diagnostica avanzata"),
                footer: Text("Le segnalazioni di crash restano solo su questo dispositivo (nessun server remoto): vengono aggiunte al log diagnostico e possono arrivare con qualche ritardo, generalmente solo su dispositivo fisico.")
            ) {
                Toggle(isOn: $isCrashReportingEnabled) {
                    labelWithInfo("Invia segnalazioni di crash", info: "Le segnalazioni di crash sono anonime, e aiutano a individuare e correggere i problemi.")
                }
            }
            #endif

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
