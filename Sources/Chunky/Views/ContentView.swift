import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            LibraryView()
        }
        #if os(iOS)
        .navigationViewStyle(StackNavigationViewStyle())
        #endif
    }
}
