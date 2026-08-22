import SwiftUI
import CoreData

struct AddAccountView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// Set only when shown inline in tvOS's Account split view (`AccountsView.tvOSDetailContent`),
    /// where there's no sheet/push to dismiss — `save()` calls this instead of `dismiss()` there.
    var onSaved: (() -> Void)?

    @State private var kind: RemoteAccountKind
    @State private var name = ""
    @State private var serverURLString = ""
    @State private var username = ""
    @State private var password = ""
    @State private var validationError: String?

    // SMB-only fields.
    @State private var smbHost = ""
    @State private var smbPort = "445"
    @State private var smbShare = ""
    @State private var smbWorkgroup = ""
    @State private var smbResolvedAddressOverride = ""
    @StateObject private var discovery = SMBDiscoveryService()
    @State private var speedTestResult: String?
    @State private var isRunningSpeedTest = false

    // Automation, available for every account kind (SMB, WebDAV, OPDS).
    @State private var autoScanEnabled = true
    @State private var smartFoldersEnabled = true
    @State private var preCacheDetailsEnabled = true
    @State private var preCacheCoversEnabled = true

    init(initialKind: RemoteAccountKind = .opds, onSaved: (() -> Void)? = nil) {
        _kind = State(initialValue: initialKind)
        self.onSaved = onSaved
    }

    var body: some View {
        #if os(tvOS)
        tvOSForm
            .onChange(of: kind, perform: updateDiscovery)
            .onAppear { updateDiscovery(kind) }
            .onDisappear { discovery.stop() }
        #else
        NavigationStack {
            formContent
                .navigationTitle("Nuovo account")
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
        .onAppear { updateDiscovery(kind) }
        .onDisappear { discovery.stop() }
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
            discovery.start()
        } else {
            discovery.stop()
        }
    }

    private var formContent: some View {
        Form {
            Section(header: Text("Tipo di account")) {
                Picker("Tipo", selection: $kind) {
                    ForEach(RemoteAccountKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
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

                Section(
                    header: Text("Server"),
                    footer: Text("L'indirizzo del NAS in rete locale, es. 192.168.1.10 o nas.local. Se non compare sopra nell'elenco trovato in rete, inseriscilo qui manualmente.")
                ) {
                    TextField("Nome account", text: $name)
                    TextField("Indirizzo", text: $smbHost)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)
                    TextField("Condivisione", text: $smbShare)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)
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

            Section(header: Text("Credenziali (opzionali)")) {
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
        }
    }

    /// `DisclosureGroup` is unavailable on tvOS, so the "Avanzate" fields are shown flat there
    /// (in a plain `Section`) instead of collapsed behind a disclosure toggle.
    @ViewBuilder
    private var advancedSMBSection: some View {
        #if os(tvOS)
        Section(header: Text("Avanzate")) {
            advancedSMBFields
        }
        #else
        Section {
            DisclosureGroup("Avanzate") {
                advancedSMBFields
            }
        }
        #endif
    }

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

    /// Shown inline as a category's content in `AccountsView`'s tvOS split view, not its own
    /// sheet — no "Annulla" needed (switching to another category is the equivalent), just the
    /// form and a "Salva" action. Its own `NavigationStack`: the "Tipo" Picker needs one to push
    /// its selection screen on tvOS, and the split view's detail pane doesn't supply one.
    #if os(tvOS)
    private var tvOSForm: some View {
        NavigationStack {
            formContent
                .tvOSListFocusFix()
                .navigationTitle("Nuovo account")
                .toolbar {
                    ToolbarItem { Button("Salva", action: save) }
                }
        }
    }
    #endif

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if kind == .smb {
            saveSMB(trimmedName: trimmedName)
            return
        }

        let trimmedURL = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL), url.scheme != nil else {
            validationError = "Inserisci un URL valido, comprensivo di http:// o https://"
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
                    speedTestResult = "Connessione non riuscita: \(error.localizedDescription)"
                    isRunningSpeedTest = false
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

        RemoteAccountEntity.create(
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
        try? context.save()
        if let onSaved { onSaved() } else { dismiss() }
    }
}
