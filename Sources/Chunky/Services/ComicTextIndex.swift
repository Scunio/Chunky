import Foundation
import CoreGraphics

/// A line of text that matches the search, along with the page it's found on.
struct ComicTextMatch: Identifiable, Equatable {
    let pageIndex: Int
    let line: RecognizedTextLine

    /// The page index alone isn't enough as identity: the same page can contain several matching
    /// lines, and in a List they'd end up collapsed into one.
    var id: String { "\(pageIndex)-\(line.boundingBox.minY)-\(line.text)" }
    var text: String { line.text }
}

/// Text from every page of a comic, for search in the reader.
///
/// Three constraints shaped this class:
///
/// - **The scan starts at the current page and expands outward.** Indexing from the
///   beginning would mean, on a 200-page volume, minutes before search gives a useful
///   result; the user is almost always searching for something they just saw.
/// - **Results appear incrementally.** The same progressive pattern already used for
///   downloading from iCloud: you can search while the scan is still running.
/// - **The index is persisted, not cached.** OCR-ing an entire volume is too expensive to
///   let the system discard it when it needs space, so the file lives in Application
///   Support (where the Core Data store already is) and is indexed on the comic's
///   `objectID`, which survives file renames — something `relativePath` doesn't (see
///   `LibraryStorage.availableDestination`).
final class ComicTextIndex: ObservableObject {
    /// Already-known lines, by page. Updated on the main thread as the scan progresses.
    @Published private(set) var lines: [Int: [RecognizedTextLine]] = [:]
    @Published private(set) var isScanning = false

    let pageCount: Int
    var scannedPageCount: Int { lines.count }
    var isComplete: Bool { scannedPageCount >= pageCount }

    /// True when every page has been read and none contained recognizable text: without
    /// distinguishing this case, a wordless page and a genuinely absent word would give the same
    /// "No matches", and the user would keep trying different words for nothing.
    var hasNoRecognizableText: Bool {
        isComplete && lines.values.allSatisfy(\.isEmpty)
    }

    private let provider: ComicPageProvider
    private let storageURL: URL?
    private let queue = DispatchQueue(label: "com.scunio.Chunky.ComicTextIndex", qos: .utility)
    private let cancelLock = NSLock()
    private var cancelledFlag = false
    /// The authoritative copy of the index, read and written **only** on `queue`. `lines` exists
    /// for the UI and travels on the main thread: taking the snapshot to save from there would
    /// mean capturing it while the latest pages are still queued toward the main thread, and
    /// writing to disk less than what had actually been recognized.
    private var storedLines: [Int: [RecognizedTextLine]]

    private var isCancelled: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelledFlag }
        set { cancelLock.lock(); cancelledFlag = newValue; cancelLock.unlock() }
    }

    init(provider: ComicPageProvider, comicIdentifier: String) {
        self.provider = provider
        self.pageCount = provider.pageCount
        self.storageURL = Self.storageURL(forComicIdentifier: comicIdentifier)
        let loaded = Self.loadIndex(at: storageURL)
        self.lines = loaded
        self.storedLines = loaded
    }

    deinit { isCancelled = true }

    // MARK: - Scanning

    /// Starts (or resumes) scanning the pages not yet indexed, starting from
    /// `page` and expanding outward. Calling it more than once is harmless: if a scan
    /// is already running, a second one doesn't start.
    func startScanning(from page: Int) {
        guard !isScanning, !isComplete else { return }
        isCancelled = false
        isScanning = true

        let known = Set(lines.keys)
        let order = Self.scanOrder(from: page, pageCount: pageCount).filter { !known.contains($0) }

        queue.async { [weak self] in
            guard let self = self else { return }
            var sincePersist = 0

            for index in order {
                if self.isCancelled { break }
                // An `autoreleasepool` per page: a comic's decoded page can weigh tens of
                // MB, and without the explicit release, scanning an entire volume would
                // accumulate all of them until the end of the loop.
                autoreleasepool {
                    let pageLines = self.recognizeLines(atPage: index)
                    self.storedLines[index] = pageLines
                    DispatchQueue.main.async {
                        self.lines[index] = pageLines
                    }
                }

                // Intermediate saves: if the app is closed (or killed) halfway through scanning a
                // long volume, saving only at the end would throw away minutes of OCR already done.
                sincePersist += 1
                if sincePersist >= Self.pagesPerPersist {
                    sincePersist = 0
                    self.persist()
                }
            }

            self.persist()
            DispatchQueue.main.async { self.isScanning = false }
        }
    }

    private static let pagesPerPersist = 10

    func cancelScanning() {
        isCancelled = true
    }

    private func recognizeLines(atPage index: Int) -> [RecognizedTextLine] {
        // Already-digital text first (native PDFs): it's exact and instant, OCR is the fallback.
        if let embedded = try? provider.textLines(atPage: index) {
            return embedded
        }
        guard let image = try? provider.image(atPage: index),
              let cgImage = image.cgImageRepresentation else { return [] }
        return (try? PageTextRecognizer.recognizeLines(in: cgImage)) ?? []
    }

    /// Pages in order of usefulness: first the one being viewed, then progressively the ones
    /// around it, alternating forward and backward.
    static func scanOrder(from page: Int, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        let start = min(max(page, 0), pageCount - 1)
        var order = [start]
        var offset = 1
        while order.count < pageCount {
            if start + offset < pageCount { order.append(start + offset) }
            if start - offset >= 0 { order.append(start - offset) }
            offset += 1
        }
        return order
    }

    // MARK: - Search

    /// Lines that contain `query`, in page order. The comparison ignores case and
    /// diacritics: OCR often gets accents wrong, and searching "perche" should find "perché".
    func matches(for query: String) -> [ComicTextMatch] {
        Self.matches(for: query, in: lines)
    }

    /// (Normalized) rectangles to highlight on a single page.
    func highlights(for query: String, onPage pageIndex: Int) -> [CGRect] {
        Self.matches(for: query, in: [pageIndex: lines[pageIndex] ?? []]).map(\.line.boundingBox)
    }

    /// The actual comparison, kept separate from the object's state because it's the only part
    /// that can be tested without actually running OCR.
    static func matches(for query: String, in lines: [Int: [RecognizedTextLine]]) -> [ComicTextMatch] {
        let needle = normalized(query)
        guard needle.count >= 2 else { return [] }

        return lines.keys.sorted().flatMap { pageIndex -> [ComicTextMatch] in
            (lines[pageIndex] ?? [])
                .filter { normalized($0.text).contains(needle) }
                .map { ComicTextMatch(pageIndex: pageIndex, line: $0) }
        }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Persistence

    private struct IndexFile: Codable {
        /// Changing this invalidates old indexes: needed if the line format or OCR parameters
        /// change someday, otherwise the app would keep reading results produced by rules
        /// different from the current ones.
        let version: Int
        let lines: [Int: [RecognizedTextLine]]
    }

    private static let currentVersion = 1

    /// Deletes the persisted index of a comic removed from the library: without this call
    /// the file in `TextIndex/` would remain orphaned forever, since it isn't in the system
    /// cache and no other code cleans it up.
    static func deleteIndex(forComicIdentifier identifier: String) {
        guard let url = storageURL(forComicIdentifier: identifier) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func storageURL(forComicIdentifier identifier: String) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let folder = support.appendingPathComponent("TextIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(sanitized(identifier)).json")
    }

    /// An objectID's URI contains "/" and ":", which can't appear in a file name.
    static func sanitized(_ identifier: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let name = String(identifier.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        // A long identifier would produce a name beyond the filesystem limit: keep
        // the tail, which is the part that distinguishes one comic from another (the prefix is shared).
        return String(name.suffix(120))
    }

    private static func loadIndex(at url: URL?) -> [Int: [RecognizedTextLine]] {
        guard let url = url,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(IndexFile.self, from: data),
              file.version == currentVersion else { return [:] }
        return file.lines
    }

    /// Only to be called on `queue`: reads `storedLines` without crossing over to the main thread.
    private func persist() {
        guard let storageURL = storageURL, !storedLines.isEmpty,
              let data = try? JSONEncoder().encode(IndexFile(version: Self.currentVersion, lines: storedLines))
        else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
