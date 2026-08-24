import SwiftUI

/// Schermata "Downloads" raggiunta dalla riga omonima del pannello Accounts: elenca i fumetti
/// in scaricamento da un account remoto (WebDAV/OPDS), con avanzamento per ciascuno e "Stop all"
/// per annullarli tutti.
struct DownloadsView: View {
    @ObservedObject private var downloadManager = DownloadManager.shared
    #if os(tvOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(tvOS)
        // Same fix as `ColorThemeView`/`ParentalLockSettingsView`: `.navigationTitle` overlays a
        // fixed screen position on tvOS instead of a sticky header, so an unbounded download
        // queue scrolls right through it. `TVPanel` puts the title in the layout instead.
        TVPanel(title: "Downloads") {
            EmptyView()
        } content: {
            downloadList
        }
        // Pushed from the Account tab's own `NavigationStack`, whose root hides its nav bar
        // (see `AccountsView.tvOSAccountList`) — same missing-affordance issue already fixed on
        // `TVComicDetailView`: with no visible bar anywhere in the stack, Menu falls through to
        // exiting the whole app instead of popping one level (confirmed live: with an empty
        // download queue, a single Menu press here landed on the tvOS Home Screen, not back on
        // the Account list). `.onExitCommand` alone wasn't enough with nothing else in this
        // screen reliably focusable in that state (an empty `List` plus a `.disabled` "Stop
        // all" — a disabled `Button` can't be forced focusable by any modifier order, confirmed
        // live); making the whole panel explicitly focusable gives it a real target. Verified
        // live: Menu from an empty Downloads screen now correctly pops back to the Account list.
        .focusable(true)
        .onExitCommand { dismiss() }
        #else
        downloadList
            .navigationTitle("Downloads")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        #endif
    }

    private var downloadList: some View {
        VStack(spacing: 0) {
            List(downloadManager.activeDownloads) { item in
                DownloadRow(item: item)
                    // No swipe-to-reveal on tvOS's remote: `DownloadRow` shows its own
                    // always-visible cancel button there instead.
                    #if !os(tvOS)
                    .swipeActions {
                        Button(role: .destructive, action: item.cancel) {
                            Label("Annulla", systemImage: "xmark")
                        }
                    }
                    #endif
            }
            .listStyle(.plain)
            .tvOSListFocusFix()

            Button(action: { downloadManager.stopAll() }) {
                Text("Stop all")
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .foregroundColor(.red)
            .disabled(downloadManager.activeDownloads.isEmpty)
        }
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(item.fractionCompleted * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                #if os(tvOS)
                Button(action: item.cancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                #endif
            }
            ProgressView(value: item.fractionCompleted)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    DownloadsView()
}
