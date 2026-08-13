import SwiftUI
import CoreData

struct AddAccountView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.presentationMode) private var presentationMode

    @State private var kind: RemoteAccountKind
    @State private var name = ""
    @State private var serverURLString = ""
    @State private var username = ""
    @State private var password = ""
    @State private var validationError: String?

    init(initialKind: RemoteAccountKind = .opds) {
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        NavigationView {
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

                Section(header: Text("Credenziali (opzionali)")) {
                    TextField("Nome utente", text: $username)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)
                    SecureField("Password", text: $password)
                }

                if let validationError = validationError {
                    Section {
                        Text(validationError)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Nuovo account")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Annulla") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Salva", action: save)
                }
                #else
                ToolbarItem {
                    Button("Annulla") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem {
                    Button("Salva", action: save)
                }
                #endif
            }
        }
        .sheetSized()
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
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
            in: context
        )
        try? context.save()
        presentationMode.wrappedValue.dismiss()
    }
}
