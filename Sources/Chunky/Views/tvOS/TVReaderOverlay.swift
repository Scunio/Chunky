#if os(tvOS)
import SwiftUI
import CoreData

/// A request to show the reader over the whole tvOS UI.
struct TVReaderRequest: Identifiable {
    let comic: ComicEntity
    let libraryComics: [ComicEntity]
    var id: NSManagedObjectID { comic.objectID }
}

struct TVOpenReaderAction {
    let handler: (TVReaderRequest) -> Void

    func callAsFunction(_ comic: ComicEntity, libraryComics: [ComicEntity]) {
        handler(TVReaderRequest(comic: comic, libraryComics: libraryComics))
    }
}

private struct TVOpenReaderKey: EnvironmentKey {
    static let defaultValue = TVOpenReaderAction { _ in }
}

private struct TVPresentedReaderComicIDKey: EnvironmentKey {
    static let defaultValue: NSManagedObjectID? = nil
}

extension EnvironmentValues {
    var tvOpenReader: TVOpenReaderAction {
        get { self[TVOpenReaderKey.self] }
        set { self[TVOpenReaderKey.self] = newValue }
    }

    var tvPresentedReaderComicID: NSManagedObjectID? {
        get { self[TVPresentedReaderComicIDKey.self] }
        set { self[TVPresentedReaderComicIDKey.self] = newValue }
    }
}

/// Hosts the reader as a root overlay instead of a `.fullScreenCover`: a Menu press inside the
/// reader reaches the reader's own `.onExitCommand` (which first resets zoom, then closes),
/// rather than being consumed by the system's cover dismissal.
struct TVReaderOverlayModifier: ViewModifier {
    @State private var request: TVReaderRequest?

    func body(content: Content) -> some View {
        ZStack {
            content
                .disabled(request != nil)
                .accessibilityHidden(request != nil)
                .environment(\.tvOpenReader, TVOpenReaderAction { request = $0 })
                .environment(\.tvPresentedReaderComicID, request?.id)
            if let request {
                ReaderView(comic: request.comic, libraryComics: request.libraryComics)
                    .id(request.id)
                    .environment(\.readerCloseAction, close)
                    .onExitCommand(perform: close)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.3)) { request = nil }
    }
}

extension View {
    func tvReaderOverlay() -> some View {
        modifier(TVReaderOverlayModifier())
    }
}
#endif
