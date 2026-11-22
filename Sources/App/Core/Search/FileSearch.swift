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

    /// Checks the settings and prepares the search. Throws `SearchValidationError` for bad input.
    public init(config: FileSearchConfiguration, selectedItems: [URL] = [], base: URL,
                isCancelled: @escaping () -> Bool = { false },
                onFound: @escaping (SearchItem) -> Void = { _ in },
                onProgress: @escaping (Int, String) -> Void = { _, _ in }) throws {
        self.config = config
        self.isCancelled = isCancelled
        self.onFound = onFound
        self.onProgress = onProgress
        predicate = .all(try SearchQueryBuilder.predicates(for: config))
        content = config.general.content.enabled ? try ContentMatcher(config.general.content) : nil

        if config.general.selectedItemsOnly {
            guard !selectedItems.isEmpty else {
                throw SearchValidationError(message: "Nothing is selected in the panel to search in.")
            }
            roots = selectedItems
        } else {
            let typed = config.general.searchPaths
            guard !typed.isEmpty else { throw SearchValidationError(message: "Enter a folder in “Search in”.") }
            var urls: [URL] = []
            for path in typed {
                let expanded = (path as NSString).expandingTildeInPath
                let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded))
                    .standardizedFileURL
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                    throw SearchValidationError(message: "“\(path)” is not a folder.")
                }
                urls.append(url)
            }
            roots = urls
        }
    }

    public func run() -> Report {
        var report = Report()
        for root in roots {
            if isCancelled() { break }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
                walk(root, into: &report)
            } else if let item = SearchItem.read(root) {
                // A selected file is tested on its own.
                report.scanned += 1
                consider(item, into: &report)
            }
        }
        if config.advanced.duplicates.enabled && !isCancelled() {
            report.duplicateGroups = DuplicateFinder.groups(of: report.found, config: config.advanced.duplicates,
                                                            errors: &report.errors, isCancelled: isCancelled)
        }
        report.cancelled = isCancelled()
        return report
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
        let maxLevel: Int?
        switch config.general.depth {
        case .all: maxLevel = nil
        case .currentOnly: maxLevel = 1
        case .limited(let n): maxLevel = max(1, n + 1)
        }
        let realPrefix = real.path.hasSuffix("/") ? real.path : real.path + "/"
        var lastProgress = Date.distantPast

        for case let url as URL in walker {
            if isCancelled() { break }
            let level = walker.level
            let relative = url.path.hasPrefix(realPrefix) ? String(url.path.dropFirst(realPrefix.count)) : url.lastPathComponent
            let shown = root.appendingPathComponent(relative)
            guard let item = SearchItem.read(shown, statPath: url.path) else { continue }  // vanished meanwhile
            if item.isDirectory, let maxLevel = maxLevel, level >= maxLevel {
                walker.skipDescendants()
            }
            report.scanned += 1
            if Date().timeIntervalSince(lastProgress) > 0.2 {
                lastProgress = Date()
                onProgress(report.scanned, shown.deletingLastPathComponent().path)
            }
            consider(item, into: &report, readPath: url)
        }
        report.errors += walkErrors
    }

    private func consider(_ item: SearchItem, into report: inout Report, readPath: URL? = nil) {
        guard predicate.test(item) else { return }
        if let content = content {
            do {
                let outcome = try content.search(readPath ?? item.url, isCancelled: isCancelled)
                switch outcome {
                case .skipped: return
                case .contains: if config.general.content.invertMatch { return }
                case .lacks: if !config.general.content.invertMatch { return }
                }
            } catch {
                report.errors.append("\(item.url.path): \((error as NSError).localizedDescription)")
                return
            }
        }
        report.found.append(item)
        if !config.advanced.duplicates.enabled { onFound(item) }
    }
}
