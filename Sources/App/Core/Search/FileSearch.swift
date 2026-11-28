import Foundation

/// The Find Files engine: walks the starting folders, applies every active predicate (AND),
/// then the content search, then (optionally) duplicate grouping. Runs synchronously; the
/// dialog puts it on a background queue. Unreadable folders and files are reported in
/// `errors` and the search carries on.
public final class FileSearch {
    public struct Report {
        public var found: [SearchItem] = []
        public var duplicateGroups: [DuplicateFinder.Group]?
        public var errors: [String] = []
        public var scanned = 0
        public var cancelled = false

        public var fileCount: Int { found.filter { !$0.isDirectory }.count }
        public var directoryCount: Int { found.filter(\.isDirectory).count }
    }

    /// The selected items of the panel, for "Only search in selected directories/files".
    public var selectedItems: [URL] = []

    private let config: FileSearchConfiguration
    private let predicate: SearchPredicate
    private let content: ContentMatcher?
    private let roots: [URL]
    private let isCancelled: () -> Bool
    /// Called for each match as it is found (not in duplicate mode, which needs the full set first).
    private let onFound: (SearchItem) -> Void
    /// Called now and then with the number of items looked at and the folder being searched.
    private let onProgress: (Int, String) -> Void
    /// Connected servers: `ccftp://` roots are searched through their session.
    private let sessions: SyncSessionLookup
    /// Files larger than this are not downloaded for a text search on a server.
    public static let remoteContentLimit: Int64 = 200 << 20

    /// Checks the settings and prepares the search. Throws `SearchValidationError` for bad input.
    public init(config: FileSearchConfiguration, selectedItems: [URL] = [], base: URL,
                isCancelled: @escaping () -> Bool = { false },
                onFound: @escaping (SearchItem) -> Void = { _ in },
                onProgress: @escaping (Int, String) -> Void = { _, _ in },
                sessions: @escaping SyncSessionLookup = { _ in nil },
                remoteAddress: (String) -> URL? = { _ in nil }) throws {
        self.config = config
        self.sessions = sessions
        self.isCancelled = isCancelled
        self.onFound = onFound
        self.onProgress = onProgress
        predicate = .all(try SearchQueryBuilder.predicates(for: config))
        content = config.general.content.enabled ? try ContentMatcher(config.general.content) : nil
        roots = try Self.resolveRoots(config: config, selectedItems: selectedItems, base: base, remoteAddress: remoteAddress)
        if config.advanced.duplicates.enabled && config.advanced.duplicates.sameContents && roots.contains(where: \.isRemoteLocation) {
            throw SearchValidationError(message: "Duplicates by content cannot be searched on a server (every file would have to be downloaded). Untick “same contents”.")
        }
    }

    private static func resolveRoots(
        config: FileSearchConfiguration,
        selectedItems: [URL],
        base: URL,
        remoteAddress: (String) -> URL?
    ) throws -> [URL] {
        if config.general.selectedItemsOnly {
            guard !selectedItems.isEmpty else {
                throw SearchValidationError(message: "Nothing is selected in the panel to search in.")
            }
            return selectedItems
        }
        let typed = config.general.searchPaths
        guard !typed.isEmpty else { throw SearchValidationError(message: "Enter a folder in “Search in”.") }
        return try typed.map { path in
            if let remote = remoteAddress(path) ?? (path.hasPrefix(RemoteSession.scheme + "://") ? URL(string: path) : nil) {
                return remote
            }
            let expanded = (path as NSString).expandingTildeInPath
            let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded))
                .standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                throw SearchValidationError(message: "“\(path)” is not a folder.")
            }
            return url
        }
    }

    public func run() -> Report {
        var report = Report()
        for root in roots where !isCancelled() {
            searchRoot(root, into: &report)
        }
        if config.advanced.duplicates.enabled && !isCancelled() {
            report.duplicateGroups = DuplicateFinder.groups(of: report.found, config: config.advanced.duplicates,
                                                            errors: &report.errors, isCancelled: isCancelled)
        }
        report.cancelled = isCancelled()
        return report
    }

    private func searchRoot(_ root: URL, into report: inout Report) {
        if root.isRemoteLocation { searchRemote(root, into: &report) } else { searchLocal(root, into: &report) }
    }

    private func searchLocal(_ root: URL, into report: inout Report) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
            walk(root, into: &report)
        } else if let item = SearchItem.read(root) {
            // A selected file is tested on its own.
            report.scanned += 1
            consider(item, into: &report)
        }
    }

    private func walk(_ root: URL, into report: inout Report) {
        // A starting folder that is a link is walked through its target; results keep the typed path.
        let real = FileSystemLister.realPath(of: root)
        var walkErrors: [String] = []
        guard let walker = FileManager.default.enumerator(
            at: real, includingPropertiesForKeys: nil, options: [],
            errorHandler: { url, error in
                walkErrors.append("\(url.path): \((error as NSError).localizedDescription)")
                return true
            }
        ) else {
            report.errors.append("\(root.path): cannot be read")
            return
        }
        let maxLevel: Int? = remoteMaxLevel
        let realPrefix = real.path.hasSuffix("/") ? real.path : real.path + "/"
        var lastProgress = Date.distantPast
        walkEntries(walker, realPrefix: realPrefix, root: root, maxLevel: maxLevel, lastProgress: &lastProgress, into: &report)
        report.errors += walkErrors
    }

    private func walkEntries(
        _ walker: FileManager.DirectoryEnumerator, realPrefix: String, root: URL,
        maxLevel: Int?, lastProgress: inout Date, into report: inout Report
    ) {
        for case let url as URL in walker {
            if isCancelled() { break }
            visitWalkedURL(url, walker: walker, realPrefix: realPrefix, root: root,
                           maxLevel: maxLevel, lastProgress: &lastProgress, into: &report)
        }
    }

    private func visitWalkedURL(
        _ url: URL, walker: FileManager.DirectoryEnumerator, realPrefix: String,
        root: URL, maxLevel: Int?, lastProgress: inout Date, into report: inout Report
    ) {
        let level = walker.level
        let relative = url.path.hasPrefix(realPrefix) ? String(url.path.dropFirst(realPrefix.count)) : url.lastPathComponent
        guard let item = SearchItem.read(relative: relative, under: root, statPath: url.path) else { return }  // vanished meanwhile
        if item.isDirectory, let maxLevel = maxLevel, level >= maxLevel { walker.skipDescendants() }
        report.scanned += 1
        reportProgressIfDue(scanned: report.scanned, folder: item.url.deletingLastPathComponent().path, lastProgress: &lastProgress)
        consider(item, into: &report, readPath: url)
    }

    private func reportProgressIfDue(scanned: Int, folder: String, lastProgress: inout Date) {
        guard Date().timeIntervalSince(lastProgress) > 0.2 else { return }
        lastProgress = Date()
        onProgress(scanned, folder)
    }

    // MARK: Servers

    /// A server folder (or a selected server file): walked listing by listing, with the same filters.
    private var remoteMaxLevel: Int? {
        switch config.general.depth {
        case .all: return nil
        case .currentOnly: return 1
        case .limited(let n): return max(1, n + 1)
        }
    }

    private func searchRemote(_ root: URL, into report: inout Report) {
        guard let session = sessions(root) else {
            report.errors.append("\(root.absoluteString): the server connection is closed.")
            return
        }
        let rootPath = RemoteSession.path(of: root)
        if searchRemoteSingleFile(rootPath, session: session, into: &report) { return }
        let maxLevel: Int? = remoteMaxLevel
        var queue: [(path: String, level: Int)] = [(rootPath, 0)]
        var next = 0
        var lastProgress = Date.distantPast
        while next < queue.count, !isCancelled() {
            let (dir, level) = queue[next]
            next += 1
            guard let listing = fetchRemoteDirectory(dir, session: session, into: &report) else { continue }
            reportProgressIfDue(scanned: report.scanned, folder: session.addressLabel + dir, lastProgress: &lastProgress)
            processRemoteListing(listing, dir: dir, level: level, maxLevel: maxLevel, session: session, queue: &queue, into: &report)
        }
    }

    private func fetchRemoteDirectory(_ dir: String, session: RemoteSession, into report: inout Report) -> [RemoteEntry]? {
        do {
            return try session.fetch(dir, useCache: false, store: false)
        } catch {
            report.errors.append("\(session.addressLabel)\(dir): \((error as? FTPError)?.message ?? error.localizedDescription)")
            return nil
        }
    }

    private func processRemoteListing(
        _ listing: [RemoteEntry], dir: String, level: Int, maxLevel: Int?,
        session: RemoteSession, queue: inout [(path: String, level: Int)], into report: inout Report
    ) {
        for entry in listing where !isCancelled() {
            let path = (dir == "/" ? "" : dir) + "/" + entry.name
            report.scanned += 1
            if shouldDescendRemote(entry, level: level, maxLevel: maxLevel, scanned: report.scanned) {
                queue.append((path, level + 1))
            }
            considerRemote(item(entry, path: path, session: session), session: session, into: &report)
        }
    }

    private func shouldDescendRemote(_ entry: RemoteEntry, level: Int, maxLevel: Int?, scanned: Int) -> Bool {
        entry.isDirectory && (maxLevel.map { level + 1 < $0 } ?? true)
            && level + 1 < RemoteSession.maxDepth && scanned < RemoteSession.maxEntries
    }

    private func searchRemoteSingleFile(_ rootPath: String, session: RemoteSession, into report: inout Report) -> Bool {
        // A selected entry may be a file: look it up in its folder's listing.
        let parent = (rootPath as NSString).deletingLastPathComponent
        guard rootPath != "/",
              let entry = (try? session.fetch(parent.isEmpty ? "/" : parent))?.first(where: { $0.name == (rootPath as NSString).lastPathComponent }),
              !entry.isDirectory else { return false }
        report.scanned += 1
        considerRemote(item(entry, path: rootPath, session: session), session: session, into: &report)
        return true
    }

    /// A server entry as a search item (owner unknown: never "system"; permissions from the listing).
    private func item(_ entry: RemoteEntry, path: String, session: RemoteSession) -> SearchItem {
        let type = entry.isDirectory ? UInt16(S_IFDIR) : UInt16(S_IFREG)
        return SearchItem(url: session.url(for: path), name: entry.name, isDirectory: entry.isDirectory,
                          size: entry.isDirectory ? 0 : entry.size, modified: entry.modified ?? .distantPast,
                          mode: type | UInt16(entry.permissions ?? 0o644), flags: 0, ownerID: UInt32.max)
    }

    /// Name/size/date/attribute filters first; a text search downloads the file to a temporary folder.
    private func considerRemote(_ item: SearchItem, session: RemoteSession, into report: inout Report) {
        guard predicate.test(item) else { return }
        guard content != nil, !item.isDirectory else { return consider(item, into: &report) }
        guard item.size <= Self.remoteContentLimit else {
            report.errors.append("\(session.addressLabel)\(RemoteSession.path(of: item.url)): larger than 200 MB, not downloaded for the text search")
            return
        }
        downloadAndConsiderRemote(item, session: session, into: &report)
    }

    private func downloadAndConsiderRemote(_ item: SearchItem, session: RemoteSession, into report: inout Report) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cc-find-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent(item.name)
        let cancel = CancelFlag()
        do {
            try session.client.download(RemoteSession.path(of: item.url), to: local, expectedSize: item.size, resume: false,
                                        cancel: cancel, progress: { [isCancelled] _ in if isCancelled() { cancel.cancel() } })
        } catch FTPError.cancelled {
            return
        } catch {
            report.errors.append("\(session.addressLabel)\(RemoteSession.path(of: item.url)): \((error as? FTPError)?.message ?? error.localizedDescription)")
            return
        }
        consider(item, into: &report, readPath: local)
    }

    private func consider(_ item: SearchItem, into report: inout Report, readPath: URL? = nil) {
        guard predicate.test(item) else { return }
        if let content = content, !matchesContent(content, item: item, readPath: readPath, into: &report) {
            return
        }
        report.found.append(item)
        if !config.advanced.duplicates.enabled { onFound(item) }
    }

    private func matchesContent(_ content: ContentMatcher, item: SearchItem, readPath: URL?, into report: inout Report) -> Bool {
        do {
            let outcome = try content.search(readPath ?? item.url, isCancelled: isCancelled)
            return Self.outcomeMatches(outcome, invertMatch: config.general.content.invertMatch)
        } catch {
            report.errors.append("\(item.url.path): \((error as NSError).localizedDescription)")
            return false
        }
    }

    private static func outcomeMatches(_ outcome: ContentMatcher.Outcome, invertMatch: Bool) -> Bool {
        switch outcome {
        case .skipped: return false
        case .contains: return !invertMatch
        case .lacks: return invertMatch
        }
    }
}
