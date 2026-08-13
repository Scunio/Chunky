import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            LibraryView()
        }
        #if os(iOS)
        .navigationViewStyle(StackNavigationViewStyle())
        #endif
        // Avviata una sola volta per tutta la durata dell'app (la query è inerte se iCloud non
        // è attivo): fermarla e riavviarla entrando/uscendo dal lettore costringerebbe a una
        // nuova fase di raccolta ogni volta.
        .onAppear { ICloudDownloadTracker.shared.start() }
    }
}
