#if os(tvOS)
import SwiftUI

/// Decorative left-hand panel for the Account setup flow (list → account detail → add-account
/// form), matching Infuse's "Condivisioni" screens (confirmed via on-device photos of a
/// well-made tvOS app): a static "syncing across devices" motif that keeps every screen in the
/// flow visually connected instead of leaving bare empty space next to the pill list.
struct TVIllustrationPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Image(systemName: "wifi")
                .font(.system(size: 46))
                .foregroundColor(.secondary)

            HStack(spacing: 18) {
                Image(systemName: "arrow.up.right")
                Image(systemName: "arrow.down.left")
            }
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.secondary.opacity(0.6))

            HStack(spacing: 24) {
                Image(systemName: "desktopcomputer")
                Image(systemName: "appletv.fill")
                Image(systemName: "ipad")
            }
            .font(.system(size: 34))
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 48)
        .padding(.top, 60)
    }
}

#Preview {
    TVIllustrationPanel()
}
#endif
