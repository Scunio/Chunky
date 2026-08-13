#if os(macOS)
import AppKit
import Foundation

enum RevealInFinder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
#endif
