import SwiftUI
#if os(iOS)
import UIKit

extension UIScreen {
    /// `UIScreen.main` is deprecated in a multi-scene world: brightness needs to be read/written
    /// on the active scene's screen, not on an implicit main screen.
    static var current: UIScreen? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
    }
}
#endif

/// Boundary between the two platforms for presentations: content views stay
/// agnostic, and ask here "show me the way that's appropriate" instead of branching on their own.
extension View {
    /// A sheet without explicit dimensions stays, on Mac, a small fixed modal — not
    /// the full-height panel one would expect. Not needed on iOS: the system already
    /// picks a good size for sheets on its own.
    ///
    /// The minimum width is the one `ToolsPanelView`/`SettingsView` need so that
    /// a label like "Highlight Color" doesn't get truncated — even for the simpler
    /// forms (AddAccountView, ComicInfoSheet), which stay readable when wider too.
    func sheetSized() -> some View {
        #if os(macOS)
        self.frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 680)
        #else
        self
        #endif
    }
}

extension View {
    /// Background of the parental lock screen, shared by all the windows it
    /// appears in (library, reader, Preferences on Mac). Must stay OPAQUE: a translucent
    /// material would let the content it's supposed to hide show through.
    func lockScreenBackground() -> some View {
        self.background(.background, ignoresSafeAreaEdges: .all)
    }
}
