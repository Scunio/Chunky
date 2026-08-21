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

enum PlatformSafeArea {
    /// Status bar / notch / Dynamic Island height, read straight from the key window. The
    /// reader's tap zones live in a `.ignoresSafeArea()` pager (see `ReaderView.iOSPager`),
    /// so their coordinate space starts at the true top of the screen — a header positioned
    /// at the normal, safe-area-respecting spot therefore sits `topInset` points *below*
    /// that origin. `PageTapZoneGeometry`'s own `topInset` exclusion band needs to start
    /// from y=0 in that space, i.e. cover this inset *plus* the header's own height, or a
    /// tap on the header (in the gap between y=0 and where the header visually begins)
    /// falls through to the ordinary page-turn zones underneath.
    static var topInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    /// Home indicator height, read the same way as `topInset`. The reader's host reports no
    /// safe area of its own (see `StatusBarControllingHost`), so the chrome can't get the
    /// inset from the environment: the footer pads by this value instead to keep its content
    /// clear of the indicator (see `ReaderView.footer`).
    static var bottomInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    /// Last non-zero `topInset`, i.e. the height the status bar has when it's showing. The
    /// reader's host reports no safe area of its own (see `StatusBarControllingHost`), so its
    /// header has to pad by this to clear the status bar — and it can't read `topInset` live:
    /// the body is re-evaluated the moment the controls appear, before UIKit has brought the
    /// status bar back, so a live read would still be zero and the header would land under it.
    @MainActor static var statusBarHeight: CGFloat {
        let current = topInset
        if current > 0 { lastStatusBarHeight = current }
        return lastStatusBarHeight
    }
    @MainActor private static var lastStatusBarHeight: CGFloat = 0

    /// True window size, unaffected by the status bar's own height changing — unlike
    /// `GeometryReader`'s `.size`, which still tracks it despite `.ignoresSafeArea()`.
    static var windowSize: CGSize {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first(where: \.isKeyWindow)?
            .bounds.size ?? .zero
    }
}

/// Hosts SwiftUI content in a `UIViewController` that drives its own status bar visibility,
/// instead of through SwiftUI's `.statusBar(hidden:)` modifier layered on top of
/// `.ignoresSafeArea()` content — see the comment on `ReaderView`'s use of this. That
/// combination has a known glitch: changing `.statusBar(hidden:)` inside
/// an animated SwiftUI transaction doesn't coordinate with the safe-area transition UIKit
/// runs for the status bar itself, so `.ignoresSafeArea()` content visibly jumps for a
/// frame. Apple's own apps (Photos, in full-screen browsing) hide/show the status bar
/// together with their chrome without this jump because they control
/// `prefersStatusBarHidden` directly on a real view controller, which is what this does.
final class StatusBarControllingHostingController<Content: View>: UIHostingController<Content> {
    var isStatusBarHidden = true {
        didSet {
            guard isStatusBarHidden != oldValue else { return }
            setNeedsStatusBarAppearanceUpdate()
        }
    }
    override var prefersStatusBarHidden: Bool { isStatusBarHidden }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
}

/// See `StatusBarControllingHostingController`.
struct StatusBarControllingHost<Content: View>: UIViewControllerRepresentable {
    var isStatusBarHidden: Bool
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> StatusBarControllingHostingController<Content> {
        let controller = StatusBarControllingHostingController(rootView: content())
        controller.isStatusBarHidden = isStatusBarHidden
        controller.view.backgroundColor = .clear
        // The content is a full-screen reader: without this it stops at the safe area, and
        // `.ignoresSafeArea()` inside can't get past it — SwiftUI can't undo the inset UIKit
        // imposes on a child hosting controller. The chrome positions itself with
        // `PlatformSafeArea` instead (see `ReaderView.footer`).
        controller.safeAreaRegions = []
        return controller
    }

    func updateUIViewController(_ controller: StatusBarControllingHostingController<Content>, context: Context) {
        controller.rootView = content()
        controller.isStatusBarHidden = isStatusBarHidden
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
        #elseif os(tvOS)
        // tvOS's default sheet width is too narrow for a `.navigationTitle` at that
        // platform's larger title font size together with the toolbar's "+"/"Chiudi"
        // buttons on the same line — the title got clipped mid-word ("Acc...").
        self.frame(minWidth: 900, minHeight: 700)
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

extension View {
    /// `popover` doesn't exist at all on tvOS (no anchored-popup paradigm on a TV); a `sheet`
    /// is the closest cross-platform equivalent for the small "Now Reading"/"New comics"
    /// panels that use this elsewhere.
    @ViewBuilder
    func platformPopover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(tvOS)
        self.sheet(isPresented: isPresented, content: content)
        #else
        self.popover(isPresented: isPresented, content: content)
        #endif
    }
}
