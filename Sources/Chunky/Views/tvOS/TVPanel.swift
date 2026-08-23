#if os(tvOS)
import SwiftUI

/// Shared header for tvOS screens presented as the root of a sheet: a plain title row plus
/// trailing actions instead of the system navigation bar, which in a compact sheet crams its
/// title and toolbar buttons together (see the equivalent comment history on `AccountsView`,
/// the pattern's original home before it moved here). `content` gets the tvOS 17 List/Form
/// clipping fix automatically — see `View.tvOSListFocusFix()`.
struct TVPanel<Actions: View, Content: View>: View {
    let title: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 32) {
                Text(title)
                    .font(.title2.bold())
                Spacer()
                actions
            }
            .padding(.horizontal, 48)
            .padding(.top, 24)
            .padding(.bottom, 28)

            content
                .tvOSListFocusFix()
                .padding(.horizontal, 48)
        }
    }
}

extension View {
    /// A resting-state background pill for a List row — plain `List` rows on tvOS are just bare
    /// text on the blurred background until focused, which reads as unfinished next to real
    /// tvOS apps (e.g. Infuse's Settings screen, which pills every row light gray at rest and
    /// orange when focused). Chain onto row content inside a `List`.
    func tvOSRowBackground() -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
    }
}

/// tvOS renders `Label`'s icon and title with zero gap between them in list rows ("↓Downloads")
/// — an explicit layout keeps a readable spacing there. Shared by `AccountsView` and
/// `ComicInfoSheet`, which both used to hand-roll their own identical copy of this.
func tvOSRowLabel(_ title: String, systemImage: String, tint: Color = .primary) -> some View {
    HStack(spacing: 24) {
        Image(systemName: systemImage)
            .foregroundColor(tint)
            .frame(width: 44)
        Text(title)
    }
}
#endif
