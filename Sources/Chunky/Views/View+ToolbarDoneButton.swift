import SwiftUI

/// Views like SettingsView/ColorThemeView/ParentalLockSettingsView are designed to be
/// pushed into an existing NavigationView (which already offers a back button). When they're
/// presented on their own in a sheet (e.g. from the reader's Tools menu) an explicit way to
/// close them is needed.
extension View {
    func toolbarDoneButton(action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        // tvOS's navigation bar crams toolbar buttons against the centered title in a
        // compact sheet, so views that need a close affordance there draw their own
        // (AccountsView's header) — adding this on top would only duplicate it.
        self
        #else
        toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Chiudi", action: action)
            }
        }
        #endif
    }
}
