import SwiftUI

/// Stile di transizione per il cambio pagina, usato sia per "Tap page-turn" che per
/// "Swipe page-turn" (stesse opzioni per entrambi). Con "Scorrimento" lo swipe usa il
/// pager nativo di `TabView(.page)` su iOS (segue il dito); le altre opzioni passano a un
/// pager gestito manualmente — vedi nota in ReaderView.
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

/// Come la pagina viene adattata allo schermo. "Adatta pagina" mostra l'intera pagina
/// (comportamento attuale/di sempre); "Adatta larghezza" scala alla larghezza dello schermo,
/// rendendo la pagina scorrevole verticalmente se più alta dello schermo.
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

/// Le opzioni osservate per il timer di reset a pagina 1 dopo inattività (funzione pensata
/// per l'uso "vetrina/kiosk", vicino a Modalità Kiosk): il numero è in secondi, 0 = "Mai".
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

/// Icona "ⓘ" con spiegazione a comparsa.
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
        .popover(isPresented: $isPresented) {
            infoText.presentationCompactAdaptation(.popover)
        }
    }

    private var infoText: some View {
        Text(text)
            .font(.footnote)
            .padding()
            .frame(maxWidth: 280)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `compact: true` omette lo Spacer finale: usarlo per l'etichetta di un Picker, dove SwiftUI
/// aggiunge già da sé il valore corrente e la freccina dopo l'intera label — uno Spacer qui la
/// farebbe espandere in modo scomposto invece di restare compatta accanto al titolo.
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
                    labelWithInfo("Tap-to-pan", info: "Toccando un bordo qualsiasi si va sempre avanti, invece che indietro/avanti a seconda del lato. Comodo se tieni il tablet/telefono in una posizione scomoda per raggiungere entrambi i lati.")
                }
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
                // Senza iCloud la cartella libreria vive nel container sandbox
                // (~/Library/Containers/com.scunio.Chunky/...), che nessuno trova da sé nel
                // Finder: un modo diretto per arrivarci, invece di lasciarlo nascosto.
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

            // MetricKit, da cui dipende questa funzione, non esiste su macOS: mostrare il
            // toggle lì significherebbe promettere qualcosa che non fa nulla.
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
        // Senza uno stile esplicito, una Form spinta in una NavigationStack (non root) su
        // macOS cade su una lista piatta senza sfondi raggruppati — verificato dal vivo,
        // aspetto completamente diverso dalla stessa Form mostrata come radice.
        .formStyle(.grouped)
        // Un `maxHeight` qui taglierebbe il contenuto in eccesso senza scroll (verificato: è
        // esattamente quello che succedeva). Solo un limite di larghezza, e la finestra —
        // resa ridimensionabile in ChunkyApp.swift — può aprirsi più bassa e lasciare che la
        // Form scorra da sé, come qualunque lista/form scrollabile.
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
