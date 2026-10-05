import SwiftUI
import CoreData

struct AddAccountView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Set only when shown inline in tvOS's Account split view (`AccountsView.tvOSDetailContent`),
    /// where there's no sheet/push to dismiss — `save()` calls this instead of `dismiss()` there.
    var onSaved: (() -> Void)?

    @State private var kind: RemoteAccountKind
    @State private var name = ""
    @State private var serverURLString = ""
    @State private var username = ""
    @State private var password = ""
    @State private var validationError: String?
    /// Conferma di eliminazione (solo modifica): azione distruttiva sempre con alert.
    @State private var isConfirmingDelete = false

    // SMB-only fields.
    @State private var smbHost = ""
    @State private var smbPort = "445"
    @State private var smbShare = ""
    @State private var smbWorkgroup = ""
    @State private var smbResolvedAddressOverride = ""
    @StateObject private var discovery = SMBDiscoveryService()
    /// Preflight del permesso "Rete locale": se è indeciso fa comparire il
    /// prompt di sistema, se è negato guida al toggle nelle Impostazioni.
    @StateObject private var localNetwork = LocalNetworkPermission()
    @State private var speedTestResult: String?
    @State private var isRunningSpeedTest = false
    // Share discovery ("Sfoglia condivisioni"): lets the user pick a share from what the server
    // actually offers instead of typing its exact name blind.
    @State private var isBrowsingShares = false
    @State private var availableShares: [String] = []
    @State private var shareBrowseError: String?
    #if os(tvOS)
    @State private var isAdvancedExpanded = false
    #endif

    // Automation, available for every account kind (SMB, WebDAV, OPDS).
    @State private var autoScanEnabled = true
    @State private var smartFoldersEnabled = true
    @State private var preCacheDetailsEnabled = true
    @State private var preCacheCoversEnabled = true

    /// Account esistente in modifica (`nil` = creazione). Best practice: un solo
    /// form per crea+modifica così validazione, test velocità e gestione Rete
    /// locale restano identici; il `kind` in modifica è bloccato (cambiare tipo
    /// orfanerebbe i campi specifici e va fatto con elimina+ricrea).
    private var editingAccount: RemoteAccountEntity?
    /// Chiamato dopo un'eliminazione riuscita perché il chiamante chiuda anche la
    /// vista sottostante (es. il browser aperto su quell'account): senza, si resta
    /// dentro un oggetto cancellato. La lista si aggiorna da sola via FetchRequest.
    var onDeleted: (() -> Void)?
    private var isEditing: Bool { editingAccount != nil }

    init(initialKind: RemoteAccountKind = .opds, onSaved: (() -> Void)? = nil) {
        _kind = State(initialValue: initialKind)
        self.editingAccount = nil
        self.onSaved = onSaved
    }

    /// Modalità modifica: pre-compila tutti i campi dall'account (password inclusa,
    /// letta dal Keychain). L'oggetto è sullo stesso main context della vista.
    init(editing account: RemoteAccountEntity, onSaved: (() -> Void)? = nil, onDeleted: (() -> Void)? = nil) {
        let kind = account.kind
        _kind = State(initialValue: kind)
        self.editingAccount = account
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _name = State(initialValue: account.name ?? "")
        _username = State(initialValue: account.username ?? "")
        _password = State(initialValue: account.password ?? "")
        _autoScanEnabled = State(initialValue: account.autoScanEnabled)
        _smartFoldersEnabled = State(initialValue: account.smartFoldersEnabled)
        _preCacheDetailsEnabled = State(initialValue: account.preCacheDetailsEnabled)
        _preCacheCoversEnabled = State(initialValue: account.preCacheCoversEnabled)
        if kind == .smb {
            _serverURLString = State(initialValue: "")
            _smbHost = State(initialValue: account.serverURL?.host ?? "")
            _smbPort = State(initialValue: account.portNumber > 0 ? String(account.portNumber) : "445")
            _smbShare = State(initialValue: account.shareName ?? "")
            _smbWorkgroup = State(initialValue: account.domainOrWorkgroup ?? "")
            _smbResolvedAddressOverride = State(initialValue: account.resolvedAddressOverride ?? "")
        } else {
            _serverURLString = State(initialValue: account.serverURLString ?? "")
            _smbHost = State(initialValue: "")
            _smbPort = State(initialValue: "445")
            _smbShare = State(initialValue: "")
            _smbWorkgroup = State(initialValue: "")
            _smbResolvedAddressOverride = State(initialValue: "")
        }
    }

    var body: some View {
        #if os(tvOS)
        tvOSForm
            .onChange(of: kind, perform: updateDiscovery)
            .onChange(of: scenePhase, perform: recheckOnForeground)
            .onAppear { updateDiscovery(kind) }
            .onDisappear { discovery.stop(); localNetwork.stop() }
        #else
        NavigationStack {
            formContent
                .navigationTitle(isEditing ? "Modifica account" : "Nuovo account")
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Annulla") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Salva", action: save)
                    }
                    #else
                    ToolbarItem {
                        Button("Annulla") { dismiss() }
                    }
                    ToolbarItem {
                        Button("Salva", action: save)
                    }
                    #endif
                }
        }
        .sheetSized()
        .onChange(of: kind, perform: updateDiscovery)
        .onChange(of: scenePhase, perform: recheckOnForeground)
        .onAppear { updateDiscovery(kind) }
        .onDisappear { discovery.stop(); localNetwork.stop() }
        #endif
    }

    /// Both underlying flags always move together (see the comment on the "Pre-cache" toggle) —
    /// the model still stores them separately in case a future partial-read implementation makes
    /// them genuinely independent.
    private var precacheBinding: Binding<Bool> {
        Binding(
            get: { preCacheDetailsEnabled && preCacheCoversEnabled },
            set: {
                preCacheDetailsEnabled = $0
                preCacheCoversEnabled = $0
            }
        )
    }

    private func updateDiscovery(_ kind: RemoteAccountKind) {
        if kind == .smb {
            // Entrambi fanno operazioni di rete locale: il primo che parte fa
            // comparire il prompt di sistema se il permesso è ancora indeciso.
            discovery.start()
            localNetwork.check()
        } else {
            discovery.stop()
            localNetwork.stop()
        }
    }

    /// Blocco privacy CONFERMATO: solo il preflight `NWBrowser` con
    /// PolicyDenied (-65570) lo prova. Un EPERM SMB da solo è solo un sospetto
    /// (spesso credenziali/condivisione sbagliate): resta come errore sotto il
    /// campo interessato, mai come banner (TN3179).
    private var isBlockedBySystem: Bool {
        localNetwork.status == .denied
    }

    /// Rivaluta il permesso quando l'app torna in primo piano: se l'utente ha
    /// flippato il toggle nelle Impostazioni di sistema, lo stato cambia solo
    /// rifacendo il check — così non serve alcun bottone "Riprova".
    private func recheckOnForeground(_ phase: ScenePhase) {
        guard phase == .active, kind == .smb, localNetwork.status == .denied else { return }
        localNetwork.stop()
        discovery.start()
        localNetwork.check()
    }

    /// Banner mostrato SOLO a blocco privacy confermato dal preflight
    /// (PolicyDenied). Solo testo con il percorso manuale: il deep-link alle
    /// Impostazioni apre la pagina vuota dell'app (il toggle sta sotto
    /// Privacy e sicurezza, non raggiungibile via API), quindi il bottone
    /// portava in un vicolo cieco. Niente "Riprova": al ritorno in app il
    /// check riparte da solo via `recheckOnForeground`.
    private var localNetworkHelpSection: some View {
        Section(header: Text("Serve l'accesso alla rete locale")) {
            Text("Chunky è bloccato dalle Impostazioni di sistema: senza questo permesso non raggiungiamo il NAS. Non serve reinserire nulla, basta attivarlo e tornare qui.")
                .font(.footnote)
            #if os(tvOS)
            Text("Percorso: Impostazioni → App → Chunky → \"Rete locale\".")
                .font(.footnote)
                .foregroundColor(.secondary)
            #elseif os(iOS)
            Text("Percorso: Impostazioni → Privacy e sicurezza → Rete locale → Chunky.")
                .font(.footnote)
                .foregroundColor(.secondary)
            #elseif os(macOS)
            Text("Percorso: Impostazioni di Sistema → Privacy e sicurezza → Rete locale → Chunky.")
                .font(.footnote)
                .foregroundColor(.secondary)
            #endif
        }
    }

    /// iOS/macOS only — tvOS has its own `tvOSFormContent` (see below).
    #if !os(tvOS)
    private var formContent: some View {
        Form {
            Section(header: Text("Tipo di account"), footer: Group {
                if isEditing { Text("Il tipo non si può cambiare in modifica: per passare a un altro tipo elimina e ricrea l'account.") }
            }) {
                Picker("Tipo", selection: $kind) {
                    ForEach(RemoteAccountKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .disabled(isEditing)
                #if os(iOS)
                .pickerStyle(.segmented)
                #endif
            }

            if kind == .smb {
                if !discovery.servers.isEmpty {
                    Section(header: Text("Trovati in rete")) {
                        ForEach(discovery.servers) { server in
                            Button(action: { applyDiscovered(server) }) {
                                Label(server.name, systemImage: RemoteAccountKind.smb.systemImage)
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }

                if isBlockedBySystem {
                    localNetworkHelpSection
                }

                Section(
                    header: Text("1. NAS in rete"),
                    footer: Text("Tocca il NAS se compare sopra, altrimenti scrivi l'indirizzo a mano (es. 192.168.1.10). Alla prima ricerca l'iPhone chiede \"Rete locale\": serve Consenti, altrimenti blocca tutto qui.")
                ) {
                    TextField("Nome account", text: $name)
                    TextField("Indirizzo", text: $smbHost)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)
                }

                Section(
                    header: Text("2. Condivisione"),
                    footer: Text("Non serve indovinare il nome: premi il pulsante con le credenziali compilate e scegli dall'elenco reale del NAS.")
                ) {
                    TextField("Condivisione", text: $smbShare)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)
                    Button(isBrowsingShares ? "Ricerca in corso..." : "Sfoglia condivisioni", action: browseShares)
                        .disabled(isBrowsingShares || smbHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let shareBrowseError {
                        Text(shareBrowseError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                if !availableShares.isEmpty {
                    Section(header: Text("Condivisioni trovate")) {
                        ForEach(availableShares, id: \.self) { share in
                            Button(action: { smbShare = share }) {
                                Text(share)
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }

                advancedSMBSection
            } else {
                Section(
                    header: Text("Server"),
                    footer: Text(kind == .opds
                        ? "L'indirizzo del catalogo OPDS, es. http://192.168.1.10:8080/opds"
                        : "L'indirizzo del server WebDAV, es. https://miocloud.example.com/remote.php/dav/files/utente/")
                ) {
                    TextField("Nome account", text: $name)
                    TextField("URL del server", text: $serverURLString)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)
                }
            }

            Section(header: Text(kind == .smb ? "3. Credenziali (servono quasi sempre)" : "Credenziali (opzionali)")) {
                TextField("Nome utente", text: $username)
                    #if os(iOS)
                    .autocapitalization(.none)
                    #endif
                    .disableAutocorrection(true)
                SecureField("Password", text: $password)
            }

            Section(
                header: Text("Automazione"),
                footer: Text("Con \"Pre-cache\" attivo, ogni fumetto nuovo trovato viene scaricato subito per intero, invece di aspettare che lo apri: non esiste un modo per leggere solo titolo/copertina senza scaricare tutto il file, quindi su librerie grandi può consumare parecchia banda.")
            ) {
                Toggle("Scansione automatica", isOn: $autoScanEnabled)
                Toggle("Cartelle Smart", isOn: $smartFoldersEnabled)
                // Un solo controllo, non due: non esiste un modo per scaricare solo i dettagli
                // (ComicInfo.xml) senza anche il resto del file, quindi "dettagli" e
                // "illustrazioni" finiscono per fare esattamente la stessa cosa — vedi
                // RemoteAccountScanner.registerPlaceholder.
                Toggle("Pre-cache (dettagli e copertine)", isOn: precacheBinding)
            }

            if let validationError = validationError {
                Section {
                    Text(validationError)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }

            if isEditing {
                Section {
                    Button("Elimina account", role: .destructive, action: { isConfirmingDelete = true })
                }
            }
        }
        .alert("Eliminare questo account?", isPresented: $isConfirmingDelete) {
            Button("Elimina", role: .destructive, action: deleteEditingAccount)
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Viene rimossa solo la connessione con le sue credenziali: i fumetti già scaricati restano in libreria.")
        }
    }
    #endif

    /// Only reached from `formContent` (iOS/macOS) — tvOS builds its own advanced-fields
    /// rows directly in `tvOSFormContent`. `DisclosureGroup` doesn't exist on tvOS at all
    /// (not just unused there — the type itself fails to compile), hence the `#if`.
    #if !os(tvOS)
    private var advancedSMBSection: some View {
        Section {
            DisclosureGroup("Avanzate") {
                advancedSMBFields
            }
        }
    }
    #endif

    private var advancedSMBFields: some View {
        Group {
            TextField("Porta", text: $smbPort)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            TextField("Workgroup (opzionale)", text: $smbWorkgroup)
                #if os(iOS)
                .autocapitalization(.none)
                #endif
                .disableAutocorrection(true)
            TextField("Modifica gli Endpoint (IP risolto, opzionale)", text: $smbResolvedAddressOverride)
                #if os(iOS)
                .keyboardType(.URL)
                .autocapitalization(.none)
                #endif
                .disableAutocorrection(true)

            Button(isRunningSpeedTest ? "Test in corso..." : "Test di velocità", action: runSpeedTest)
                .disabled(isRunningSpeedTest || smbHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || smbShare.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let speedTestResult {
                Text(speedTestResult)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// tvOS-only: same fields/logic as `formContent`, but each section is one merged card
    /// (`TVFormSection`/`TVFormRow`) instead of a `Form`'s separate floating pills per row —
    /// `.listStyle(.grouped)` was tried first and confirmed (on-device and in the Simulator)
    /// to NOT produce that on tvOS, so this is a hand-rolled plain `VStack`, no `List`/`Form`.
    #if os(tvOS)
    private var tvOSFormContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            TVFormFieldRow(label: "Tipo") {
                Picker("", selection: $kind) {
                    ForEach(RemoteAccountKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .disabled(isEditing)
            }
            if isEditing {
                Text("Il tipo non si può cambiare in modifica.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            if kind == .smb {
                if !discovery.servers.isEmpty {
                    TVFormSectionLabel(title: "Trovati in rete")
                    ForEach(discovery.servers) { server in
                        Button(action: { applyDiscovered(server) }) {
                            Label(server.name, systemImage: RemoteAccountKind.smb.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.card)
                    }
                }

                if isBlockedBySystem {
                    Text("Serve l'accesso alla rete locale: Impostazioni → App → Chunky → \"Rete locale\". Torna qui dopo averlo attivato.")
                        .font(.footnote)
                        .foregroundColor(.red)
                }

                TVFormFieldRow(label: "1. Nome") { TextField("es. Il mio NAS", text: $name) }
                TVFormFieldRow(label: "1. Indirizzo") { TextField("es. 192.168.1.10", text: $smbHost).disableAutocorrection(true) }
                TVFormFieldRow(label: "2. Condivisione") { TextField("es. Video", text: $smbShare).disableAutocorrection(true) }
                Text("Tocca il NAS in \"Trovati in rete\" se compare, altrimenti scrivi l'indirizzo a mano. Poi premi \"Sfoglia condivisioni\" e scegli dall'elenco reale del NAS.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Button(isBrowsingShares ? "Ricerca in corso..." : "Sfoglia condivisioni", action: browseShares)
                    .buttonStyle(.card)
                    .disabled(isBrowsingShares || smbHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let shareBrowseError {
                    Text(shareBrowseError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
                if !availableShares.isEmpty {
                    TVFormSectionLabel(title: "Condivisioni trovate")
                    ForEach(availableShares, id: \.self) { share in
                        Button(action: { smbShare = share }) {
                            Text(share)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.card)
                    }
                }

                TVFormDisclosureRow(title: "Avanzate", isExpanded: $isAdvancedExpanded)
                if isAdvancedExpanded {
                    TVFormFieldRow(label: "Porta") { TextField("445", text: $smbPort) }
                    TVFormFieldRow(label: "Workgroup") { TextField("opzionale", text: $smbWorkgroup).disableAutocorrection(true) }
                    TVFormFieldRow(label: "Endpoint") { TextField("IP risolto, opzionale", text: $smbResolvedAddressOverride).disableAutocorrection(true) }
                    Button(isRunningSpeedTest ? "Test in corso..." : "Test di velocità", action: runSpeedTest)
                        .disabled(isRunningSpeedTest || smbHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || smbShare.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let speedTestResult {
                        Text(speedTestResult)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                TVFormFieldRow(label: "Nome") { TextField("es. La mia libreria", text: $name) }
                TVFormFieldRow(label: "URL del server") {
                    TextField(kind == .opds ? "es. http://192.168.1.10:8080/opds" : "es. https://miocloud.example.com/…", text: $serverURLString)
                        .disableAutocorrection(true)
                }
                Text(kind == .opds
                    ? "L'indirizzo del catalogo OPDS, es. http://192.168.1.10:8080/opds"
                    : "L'indirizzo del server WebDAV, es. https://miocloud.example.com/remote.php/dav/files/utente/")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            TVFormSectionLabel(title: kind == .smb ? "3. Credenziali (servono quasi sempre)" : "Credenziali (opzionali)")
            TVFormFieldRow(label: "Nome utente") { TextField("opzionale", text: $username).disableAutocorrection(true) }
            TVFormFieldRow(label: "Password") { SecureField("opzionale", text: $password) }

            TVFormSectionLabel(title: "Automazione")
            TVFormToggleRow(label: "Scansione automatica", isOn: $autoScanEnabled)
            TVFormToggleRow(label: "Cartelle Smart", isOn: $smartFoldersEnabled)
            TVFormToggleRow(label: "Pre-cache (dettagli e copertine)", isOn: precacheBinding)
            Text("Con \"Pre-cache\" attivo, ogni fumetto nuovo trovato viene scaricato subito per intero, invece di aspettare che lo apri: non esiste un modo per leggere solo titolo/copertina senza scaricare tutto il file, quindi su librerie grandi può consumare parecchia banda.")
                .font(.footnote)
                .foregroundColor(.secondary)

            if let validationError {
                Text(validationError)
                    .foregroundColor(.red)
                    .font(.footnote)
            }

            TVFormPrimaryButton(title: "Salva", action: save)
                .padding(.top, 12)

            if isEditing {
                Button("Elimina account", action: { isConfirmingDelete = true })
                    .buttonStyle(.card)
                    .foregroundColor(.red)
            }
        }
    }
    #endif

    /// Pushed from `AccountsView`'s tvOS account list (`NavigationLink`), not shown as its own
    /// sheet — no "Annulla" needed (Menu/back is the equivalent), just the form and "Salva" at
    /// the bottom. No `NavigationStack` of its own: it's pushed inside the one `AccountsView`
    /// already provides, and nesting a second `NavigationStack` inside that one would break
    /// push/pop instead of extending it.
    #if os(tvOS)
    private var tvOSForm: some View {
        ScrollView {
            // Title lives in the layout, not `.navigationTitle` — same fix as
            // `ColorThemeView`/`ParentalLockSettingsView`: on tvOS that overlays a fixed
            // screen position instead of a sticky header, so it scrolls right through when
            // the form is this long. "Salva" moved into the form itself (see
            // `TVFormPrimaryButton` at the bottom), matching Infuse's bottom-of-form
            // primary action instead of a small top-corner toolbar button.
            VStack(alignment: .leading, spacing: 24) {
                Text(isEditing ? "Modifica account" : "Nuovo account")
                    .font(.largeTitle.bold())
                tvOSFormContent
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
        }
        .alert("Eliminare questo account?", isPresented: $isConfirmingDelete) {
            Button("Elimina", role: .destructive, action: deleteEditingAccount)
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Viene rimossa solo la connessione con le sue credenziali: i fumetti già scaricati restano in libreria.")
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        // Same missing-affordance fix as `DownloadsView` — this view hides its own nav bar
        // *and* is pushed from the Account tab's hidden-nav-bar `NavigationStack` root, so
        // Menu would otherwise exit the whole app instead of popping back to the Account list.
        .onExitCommand { dismiss() }
    }
    #endif

    /// Elimina l'account in modifica: solo la riga di configurazione più la password
    /// nel Keychain. Nel modello non esiste alcuna relazione tra account e fumetti,
    /// quindi libreria e file scaricati restano intatti.
    private func deleteEditingAccount() {
        guard let existing = editingAccount else { return }
        KeychainStore.deletePassword(forAccount: existing.stableID)
        context.delete(existing)
        try? context.save()
        // Prima chiude Modifica, poi il chiamante chiude l'eventuale browser sopra
        // l'account cancellato (doppio dismiss standard: sheet e poi push).
        if let onSaved { onSaved() } else { dismiss() }
        onDeleted?()
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // In modifica il kind è bloccato: usa quello dell'account esistente anche
        // se lo @State fosse rimasto su un altro valore.
        let effectiveKind = isEditing ? (editingAccount?.kind ?? kind) : kind
        if effectiveKind == .smb {
            saveSMB(trimmedName: trimmedName)
            return
        }

        let trimmedURL = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL), url.scheme != nil else {
            validationError = "Inserisci un URL valido, comprensivo di http:// o https://"
            return
        }

        if let existing = editingAccount {
            existing.name = trimmedName.isEmpty ? (url.host ?? "Account") : trimmedName
            existing.serverURLString = trimmedURL
            existing.username = username.isEmpty ? nil : username
            existing.password = password.isEmpty ? nil : password
            existing.autoScanEnabled = autoScanEnabled
            existing.smartFoldersEnabled = smartFoldersEnabled
            existing.preCacheDetailsEnabled = preCacheDetailsEnabled
            existing.preCacheCoversEnabled = preCacheCoversEnabled
            // La configurazione è cambiata: il vecchio errore non è più valido,
            // la prossima scansione riprova da zero.
            existing.lastScanError = nil
            try? context.save()
            if let onSaved { onSaved() } else { dismiss() }
            return
        }

        RemoteAccountEntity.create(
            kind: kind,
            name: trimmedName.isEmpty ? url.host ?? "Account" : trimmedName,
            serverURLString: trimmedURL,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            autoScanEnabled: autoScanEnabled,
            smartFoldersEnabled: smartFoldersEnabled,
            preCacheDetailsEnabled: preCacheDetailsEnabled,
            preCacheCoversEnabled: preCacheCoversEnabled,
            in: context
        )
        try? context.save()
        if let onSaved { onSaved() } else { dismiss() }
    }

    private func applyDiscovered(_ server: DiscoveredSMBServer) {
        smbHost = server.host
        if name.isEmpty { name = server.name }
    }

    /// Builds an `SMBConnectionInfo` straight from the form fields and probes it directly —
    /// no `RemoteAccountEntity`/Core Data/Keychain round-trip needed for what's just a stateless
    /// network check, and no scratch managed-object context to get the threading contract wrong on.
    private func runSpeedTest() {
        speedTestResult = nil

        let trimmedHost = smbHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedShare = smbShare.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWorkgroup = smbWorkgroup.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOverride = smbResolvedAddressOverride.trimmingCharacters(in: .whitespacesAndNewlines)

        // Same validation as saveSMB(): a speed test against a silently-defaulted port would
        // report success/failure for the wrong port and mislead whoever reads the result before
        // saving.
        guard let port = Int32(smbPort.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            speedTestResult = "Porta non valida."
            return
        }

        isRunningSpeedTest = true
        let connection = SMBConnectionInfo(
            host: trimmedOverride.isEmpty ? trimmedHost : trimmedOverride,
            port: port,
            share: trimmedShare,
            domain: trimmedWorkgroup.isEmpty ? nil : trimmedWorkgroup,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password
        )

        Task {
            do {
                let result = try await SMBClient().measureThroughput(for: connection)
                await MainActor.run {
                    if let megabytesPerSecond = result.megabytesPerSecond {
                        speedTestResult = String(format: "Connesso in %.0f ms · ~%.1f MB/s", result.connectLatency * 1000, megabytesPerSecond)
                    } else {
                        speedTestResult = String(format: "Connesso in %.0f ms (nessun fumetto trovato per misurare il download)", result.connectLatency * 1000)
                    }
                    isRunningSpeedTest = false
                }
            } catch {
                await MainActor.run {
                    speedTestResult = "Connessione non riuscita: \(error.chunkyFriendlyDescription)"
                    DiagnosticLog.log("SMB speed test host=\(trimmedHost) EPERM=\(error.isLocalNetworkDenied) preflight=\(localNetwork.status) err=\(error.localizedDescription)")
                    isRunningSpeedTest = false
                }
            }
        }
    }

    /// Connects with just host/port/credentials (no share yet) and lists what the server
    /// offers, so "Condivisione" can be picked from real results instead of typed blind.
    private func browseShares() {
        shareBrowseError = nil
        availableShares = []

        let trimmedHost = smbHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return }
        let trimmedWorkgroup = smbWorkgroup.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOverride = smbResolvedAddressOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int32(smbPort.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            shareBrowseError = "Porta non valida."
            return
        }

        isBrowsingShares = true
        Task {
            do {
                let shares = try await SMBClient().listShares(
                    host: trimmedOverride.isEmpty ? trimmedHost : trimmedOverride,
                    port: port,
                    domain: trimmedWorkgroup.isEmpty ? nil : trimmedWorkgroup,
                    username: username.isEmpty ? nil : username,
                    password: password.isEmpty ? nil : password
                )
                await MainActor.run {
                    availableShares = shares.map(\.name)
                    isBrowsingShares = false
                    if availableShares.isEmpty {
                        shareBrowseError = "Nessuna condivisione trovata."
                    }
                }
            } catch {
                await MainActor.run {
                    shareBrowseError = "Impossibile elencare le condivisioni: \(error.chunkyFriendlyDescription)"
                    DiagnosticLog.log("SMB browse host=\(trimmedHost) EPERM=\(error.isLocalNetworkDenied) preflight=\(localNetwork.status) err=\(error.localizedDescription)")
                    isBrowsingShares = false
                }
            }
        }
    }

    private func saveSMB(trimmedName: String) {
        let trimmedHost = smbHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedShare = smbShare.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            validationError = "Inserisci l'indirizzo del NAS."
            return
        }
        guard !trimmedShare.isEmpty else {
            validationError = "Inserisci il nome della condivisione."
            return
        }
        guard let port = Int32(smbPort.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            validationError = "La porta deve essere un numero valido."
            return
        }

        var components = URLComponents()
        components.scheme = "smb"
        components.host = trimmedHost
        guard let url = components.url else {
            validationError = "Inserisci un indirizzo valido."
            return
        }

        let trimmedWorkgroup = smbWorkgroup.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOverride = smbResolvedAddressOverride.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = editingAccount {
            AppLog.log("Salva Modifica id=\(existing.stableID.uuidString) host=\(trimmedHost) share=\(trimmedShare) userPresente=\(!username.isEmpty) passLen=\(password.count)")
            existing.name = trimmedName.isEmpty ? trimmedHost : trimmedName
            existing.serverURLString = url.absoluteString
            existing.username = username.isEmpty ? nil : username
            if password.isEmpty {
                AppLog.log("Salva Modifica: campo vuoto, cancello password id=\(existing.stableID.uuidString)")
                KeychainStore.deletePassword(forAccount: existing.stableID)
            } else {
                let report = KeychainStore.savePassword(password, forAccount: existing.stableID)
                AppLog.log("Salva Modifica id=\(existing.stableID.uuidString) report ok=\(report.ok) (scrittura \(report.writeStatus), lettura \(report.readStatus))")
                if !report.ok {
                    validationError = "Password non salvata (scrittura \(report.writeStatus), lettura \(report.readStatus))."
                    return
                }
            }
            existing.portNumber = port
            existing.shareName = trimmedShare
            existing.domainOrWorkgroup = trimmedWorkgroup.isEmpty ? nil : trimmedWorkgroup
            existing.resolvedAddressOverride = trimmedOverride.isEmpty ? nil : trimmedOverride
            existing.autoScanEnabled = autoScanEnabled
            existing.smartFoldersEnabled = smartFoldersEnabled
            existing.preCacheDetailsEnabled = preCacheDetailsEnabled
            existing.preCacheCoversEnabled = preCacheCoversEnabled
            existing.lastScanError = nil
            do {
                try context.save()
                AppLog.log("Salva Modifica id=\(existing.stableID.uuidString): Core Data ok")
            } catch {
                AppLog.log("Salva Modifica id=\(existing.stableID.uuidString): Core Data FALLITO: \(error.localizedDescription)")
            }
            if let onSaved { onSaved() } else { dismiss() }
            return
        }

        let created = RemoteAccountEntity.create(
            kind: .smb,
            name: trimmedName.isEmpty ? trimmedHost : trimmedName,
            serverURLString: url.absoluteString,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            portNumber: port,
            shareName: trimmedShare,
            domainOrWorkgroup: trimmedWorkgroup.isEmpty ? nil : trimmedWorkgroup,
            resolvedAddressOverride: trimmedOverride.isEmpty ? nil : trimmedOverride,
            autoScanEnabled: autoScanEnabled,
            smartFoldersEnabled: smartFoldersEnabled,
            preCacheDetailsEnabled: preCacheDetailsEnabled,
            preCacheCoversEnabled: preCacheCoversEnabled,
            in: context
        )
        if !password.isEmpty {
            let report = KeychainStore.savePassword(password, forAccount: created.stableID)
            if !report.ok {
                DiagnosticLog.log("Keychain: salvataggio fallito in Creazione id=\(created.stableID.uuidString) (scrittura \(report.writeStatus), lettura \(report.readStatus))")
                validationError = "Password non salvata (scrittura \(report.writeStatus), lettura \(report.readStatus))."
                context.delete(created)
                try? context.save()
                return
            }
        }
        try? context.save()
        if let onSaved { onSaved() } else { dismiss() }
    }
}

#Preview {
    // Wrapped in its own `NavigationStack` here only for the preview: in the real app tvOS
    // pushes this from `AccountsView`'s own stack (see `tvOSForm`'s doc comment) — a bare
    // preview needs *some* stack ancestor for the "Tipo" Picker's push to work.
    let controller = PersistenceController(inMemory: true)
    return NavigationStack {
        AddAccountView(initialKind: .smb)
    }
    .environment(\.managedObjectContext, controller.container.viewContext)
}
