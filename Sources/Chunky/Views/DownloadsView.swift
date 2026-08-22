import SwiftUI

/// Schermata "Downloads" raggiunta dalla riga omonima del pannello Accounts: elenca i fumetti
/// in scaricamento da un account remoto (WebDAV/OPDS), con avanzamento per ciascuno e "Stop all"
/// per annullarli tutti.
struct DownloadsView: View {
    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
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
            // See `AccountsView.tvOSPanel` for why this is needed on tvOS 17.
            #if os(tvOS)
            .scrollClipDisabled(true)
            #endif

            Button(action: { downloadManager.stopAll() }) {
                Text("Stop all")
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .foregroundColor(.red)
            .disabled(downloadManager.activeDownloads.isEmpty)
        }
        .navigationTitle("Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
