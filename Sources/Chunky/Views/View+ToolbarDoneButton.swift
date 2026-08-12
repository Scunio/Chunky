import SwiftUI

/// Le view come SettingsView/ColorThemeView/ParentalLockSettingsView sono pensate per essere
/// spinte in una NavigationView esistente (che offre già un bottone indietro). Quando vengono
/// presentate da sole in uno sheet (es. dal menu Tools del reader) serve un modo esplicito per
/// chiuderle.
extension View {
    func toolbarDoneButton(action: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Chiudi", action: action)
            }
        }
    }
}
