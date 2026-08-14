#if os(macOS)
import SwiftUI

/// Preferenze macOS: sidebar di categorie + pannello di dettaglio, come il System Settings.app
/// di macOS Ventura+, invece dell'unica `Form` lunga e navigabile di `SettingsView` (quella
/// resta per iOS, dov'è il pattern corretto). Ogni categoria mostra tutto il proprio contenuto
/// senza ulteriore navigazione: le HIG di macOS non prevedono un back-button dentro le
/// Preferenze.
///
/// Non usiamo una `TabView` a icone (lo stile "Preferenze classiche" di Mail/Safari/Xcode):
/// quando è lei il contenuto diretto di `Settings`, macOS genera un pannello a dimensione
/// fissa che ignora `.windowResizability` — verificato dal vivo, zoom e resize a mano non
/// avevano alcun effetto. La sidebar è una finestra normale, quindi resta ridimensionabile.
struct MacSettingsView: View {
    private enum Category: String, CaseIterable, Identifiable {
        case reading, navigation, appearance, imageQuality, parentalLock, advanced, diagnostics, info

        var id: String { rawValue }

        var title: String {
            switch self {
            case .reading: "Lettura"
            case .navigation: "Navigazione"
            case .appearance: "Colori"
            case .imageQuality: "Qualità immagine"
            case .parentalLock: "Blocco genitori"
            case .advanced: "Avanzate"
            case .diagnostics: "Diagnostica"
            case .info: "Informazioni"
            }
        }

        var systemImage: String {
            switch self {
            case .reading: "book"
            case .navigation: "hand.tap"
            case .appearance: "paintpalette"
            case .imageQuality: "wand.and.stars"
            case .parentalLock: "lock"
            case .advanced: "gearshape.2"
            case .diagnostics: "stethoscope"
            case .info: "info.circle"
            }
        }
    }

    @State private var selection: Category? = .reading

    var body: some View {
        NavigationSplitView {
            List(Category.allCases, selection: $selection) { category in
                Label(category.title, systemImage: category.systemImage)
                    .tag(category)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            content(for: selection ?? .reading)
                .navigationTitle((selection ?? .reading).title)
                // Larghezza minima del solo pannello di dettaglio: senza questa, righe con
                // controlli larghi (es. "Colore evidenziazione" col suo ColorPicker) traboccano
                // e vengono ritagliate dal bordo della colonna quando la finestra è stretta
                // (verificato dal vivo).
                .frame(minWidth: 420)
        }
        .navigationSplitViewStyle(.balanced)
        // Il pulsante per collassare la sidebar è generato dal sistema (dall'NSSplitViewController
        // sotto NavigationSplitView), lo stesso identico controllo di Mail/Note/Finder — non è
        // rimovibile con API pubbliche, e i tentativi di affiancargli altro nella toolbar
        // (provato dal vivo) lo hanno solo reso più disallineato. Lo lasciamo: per un utente Mac
        // è un elemento nativo riconoscibile, non un errore di questa finestra.
        .frame(minWidth: 680, idealWidth: 760, minHeight: 460, idealHeight: 640)
    }

    @ViewBuilder
    private func content(for category: Category) -> some View {
        switch category {
        case .reading: ReadingSettingsTab()
        case .navigation: NavigationSettingsTab()
        case .appearance: ColorThemeView()
        case .imageQuality: ImageQualitySettingsTab()
        case .parentalLock: ParentalLockSettingsTab()
        case .advanced: AdvancedSettingsTab()
        case .diagnostics: DiagnosticsSettingsTab()
        case .info: InfoSettingsTab()
        }
    }
}

private struct ReadingSettingsTab: View {
    @AppStorage("defaultReadingDirection") private var defaultReadingDirectionRawValue = ReadingDirection.leftToRight.rawValue
    @AppStorage("doublePageMode") private var isDoublePageEnabled = false
    @AppStorage("doublePageCoverAlone") private var isCoverAlone = true
    @AppStorage("singlePageZoomMode") private var singlePageZoomMode = PageZoomMode.auto
    @AppStorage("doublePageZoomMode") private var doublePageZoomMode = PageZoomMode.auto

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
                Toggle("Doppia pagina di default", isOn: $isDoublePageEnabled)
                Toggle(isOn: $isCoverAlone) {
                    labelWithInfo("Copertina da sola", info: "In doppia pagina, mostra sempre la prima pagina (di solito la copertina) da sola invece che affiancata alla seconda. L'accoppiamento a due pagine riprende dalla seconda pagina in poi.")
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
        }
        .formStyle(.grouped)
    }
}

private struct NavigationSettingsTab: View {
    @AppStorage("tapPageTurnStyle") private var tapPageTurnStyle = TapPageTurnStyle.slide
    @AppStorage("swipePageTurnStyle") private var swipePageTurnStyle = TapPageTurnStyle.slide
    @AppStorage("tapToPanEnabled") private var isTapToPanEnabled = false
    @AppStorage("oneHandedMode") private var isOneHandedModeEnabled = false
    @AppStorage("hotCornersEnabled") private var isHotCornersEnabled = false
    @AppStorage("readerIdleResetSeconds") private var readerIdleReset = ReaderIdleResetOption.never

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
    }
}

private struct ImageQualitySettingsTab: View {
    @AppStorage("autoCropEnabled") private var isAutoCropEnabled = false
    @AppStorage("upscalingEnabled") private var isUpscalingEnabled = false
    @AppStorage("motionBlurEnabled") private var isMotionBlurEnabled = true
    @AppStorage("autoTintContrastEnabled") private var isAutoTintContrastEnabled = false

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
    }
}

private struct ParentalLockSettingsTab: View {
    @AppStorage("kioskModeEnabled") private var isKioskModeEnabled = false

    var body: some View {
        Form {
            ParentalLockSections()
            Section {
                Toggle("Modalità Kiosk", isOn: $isKioskModeEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettingsTab: View {
    @AppStorage("includeInBackup") private var isIncludedInBackup = false

    var body: some View {
        Form {
            Section(
                footer: Text("Se disattivato, la cartella dei fumetti non viene inclusa nei backup di iCloud/iTunes — utile per risparmiare spazio se hai già una copia altrove.")
            ) {
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
                // Senza iCloud la cartella libreria vive nel container sandbox
                // (~/Library/Containers/com.scunio.Chunky/...), che nessuno trova da sé nel
                // Finder: un modo diretto per arrivarci, invece di lasciarlo nascosto.
                Button("Mostra la cartella della libreria nel Finder") {
                    RevealInFinder.reveal(LibraryStorage.rootFolderURL())
                }
            }
            ICloudStatusSections()
        }
        .formStyle(.grouped)
    }
}

private struct DiagnosticsSettingsTab: View {
    var body: some View {
        // Pannello a sé, non affiancata ad altre sezioni in "Avanzate": lo ScrollView a
        // altezza fissa del log smetteva di rispettare il proprio limite quando condivideva la
        // Form con altre sezioni importate da altrove (verificato dal vivo — il testo del log
        // si espandeva senza contenimento). Qui replica esattamente la struttura di
        // `DiagnosticsView`, l'unica testata a funzionare bene.
        Form {
            DiagnosticsSections()
        }
        .formStyle(.grouped)
    }
}

private struct InfoSettingsTab: View {
    @State private var isShowingAcknowledgements = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Versione")
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(.secondary)
                }
                Button("Licenze open source…") {
                    isShowingAcknowledgements = true
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingAcknowledgements) {
            NavigationStack {
                AcknowledgementsView()
                    .toolbarDoneButton { isShowingAcknowledgements = false }
            }
            .frame(minWidth: 420, minHeight: 480)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
#endif
