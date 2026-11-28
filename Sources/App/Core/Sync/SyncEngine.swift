import Foundation

// Synchronize Directories — the engine, independent of the UI.
//   DirectoryScanner → FileMatcher (by relative path) → ComparisonEngine (+ ContentComparator)
//   → ActionPlanner (recommended directions) → SyncPlan → SyncExecutor.
// Comparing is strictly read-only; only SyncExecutor changes files, and only for a confirmed plan.

public struct SyncConfiguration: Codable, Equatable {
    public var left: URL
    public var right: URL
    /// File masks for the files compared ("*.*", "*.txt;*.doc", "* | *.tmp").
    public var mask = "*.*"
    public var subdirectories = true
    /// Left is the master: the right side is made an exact copy (files only on the right get deleted).
    public var asymmetric = false
    /// Files with equal size are also compared byte by byte.
    public var byContent = false
    /// Dates do not decide anything: equal size (and content, if checked) means identical.
    public var ignoreDate = false
    /// Folders that are empty, or exist on one side only, are listed (and can be created).
    public var emptyDirectories = false
    /// Restrict the comparison to these top-level names (the panels' selection); nil = everything.
    public var onlyNames: Set<String>?

    public init(left: URL, right: URL) {
        self.left = left
        self.right = right
    }
}

/// What is known about one side of a row.
public struct SyncFileInfo: Equatable {
    public let url: URL
    public let size: Int64
    public let modified: Date
    public let isDirectory: Bool
    /// How exact `modified` is (server listings often give only minutes); dates closer than this match.
    public var datePrecision: TimeInterval = 0
}

/// Finds the connected server session of a `ccftp://` location (nil: a folder on this Mac).
public typealias SyncSessionLookup = (URL) -> RemoteSession?

public enum SyncState: Equatable {
    case identical
    /// The left file is newer (or only on the left).
    case leftNewer
    /// The right file is newer (or only on the right).
    case rightNewer
    /// Different, but no automatic direction (equal dates, or dates ignored).
    case different
    case leftOnly
    case rightOnly
}

public enum SyncAction: Equatable {
    case none
    case copyToRight
    case copyToLeft
    case deleteRight
    case deleteLeft

    public var symbol: String {
        switch self {
        case .none: return ""
        case .copyToRight: return "→"
        case .copyToLeft: return "←"
        case .deleteRight, .deleteLeft: return "✕"
        }
    }
}

public struct SyncRow: Equatable {
    /// Path relative to both roots, "/"-separated.
    public let path: String
    public let left: SyncFileInfo?
    public let right: SyncFileInfo?
    public let state: SyncState
    /// What will happen; starts as the recommendation, the user may change it.
    public var action: SyncAction
    public let recommended: SyncAction

    public var isDirectory: Bool { (left ?? right)?.isDirectory ?? false }
    public var onBothSides: Bool { left != nil && right != nil }

    /// The symbol in the middle column: the action when there is one, else = or ≠.
    public var symbol: String {
        if action != .none { return action.symbol }
        switch state {
        case .identical: return "="
        case .different, .leftNewer, .rightNewer: return "≠"
        case .leftOnly, .rightOnly: return ""
        }
    }
}

public struct SyncComparison {
    public var rows: [SyncRow] = []
    public var errors: [String] = []
    public var cancelled = false

    public var identical: Int { rows.filter { $0.state == .identical && !$0.isDirectory }.count }
    public var different: Int { rows.filter { [.leftNewer, .rightNewer, .different].contains($0.state) }.count }
    public var uniqueLeft: Int { rows.filter { $0.state == .leftOnly && !$0.isDirectory }.count }
    public var uniqueRight: Int { rows.filter { $0.state == .rightOnly && !$0.isDirectory }.count }
    public var filesFound: Int { rows.filter { !$0.isDirectory }.count }

    /// "Files found: 479 (Identical: 105, Different: 110, Unique left: 1, Unique right: 263)"
    public var summary: String {
        "Files found: \(filesFound) (Identical: \(identical), Different: \(different), Unique left: \(uniqueLeft), Unique right: \(uniqueRight))"
    }
}

/// Which rows the result list shows (the Show: buttons). All on by default.
public struct SyncShowFilter: Equatable {
    public var copyRight = true, equal = true, different = true, copyLeft = true
    public var duplicates = true, singles = true
    public init() {}

    public func shows(_ row: SyncRow) -> Bool {
        if row.onBothSides && !duplicates { return false }
        if !row.onBothSides && !singles { return false }
        return showsAction(row.action, state: row.state)
    }

    private func showsAction(_ action: SyncAction, state: SyncState) -> Bool {
        switch action {
        case .copyToRight: return copyRight
        case .copyToLeft: return copyLeft
        case .deleteRight, .deleteLeft: return copyRight || copyLeft
        case .none: return showsUnchangedOrDifferent(state)
        }
    }

    private func showsUnchangedOrDifferent(_ state: SyncState) -> Bool {
        state == .identical ? equal : different
    }
}

public enum SyncEngine {
    /// Two dates this close count as equal (FAT and network shares store times in 2 s steps).
    public static let dateTolerance: TimeInterval = 2

    // MARK: Scanning

    struct Scanned {
        var files: [String: SyncFileInfo] = [:]
        var directories: [String: SyncFileInfo] = [:]
        /// Directories that contain at least one listed entry below them.
        var nonEmpty: Set<String> = []
    }

    static func scan(_ root: URL, config: SyncConfiguration, names: NameMatcher,
                     errors: inout [String], isCancelled: () -> Bool) -> Scanned {
        var result = Scanned()
        let real = FileSystemLister.realPath(of: root)
        var walkErrors: [String] = []
        guard let walker = FileManager.default.enumerator(at: real, includingPropertiesForKeys: nil, options: [],
                                                          errorHandler: { url, error in
            walkErrors.append("\(url.path): \((error as NSError).localizedDescription)")
            return true
        }) else {
            errors.append("\(root.path): cannot be read")
            return result
        }
        let prefix = real.path.hasSuffix("/") ? real.path : real.path + "/"
        // When the folder path has no symlinks, the walker's own URLs are already the ones to show.
        let sameRoot = real.standardizedFileURL.path == root.standardizedFileURL.path
        for case let url as URL in walker where !isCancelled() {
            visitLocalScannedURL(url, root: root, prefix: prefix, sameRoot: sameRoot,
                                 config: config, names: names, walker: walker, into: &result)
        }
        errors += walkErrors
        return result
    }

    private static func visitLocalScannedURL(
        _ url: URL, root: URL, prefix: String, sameRoot: Bool,
        config: SyncConfiguration, names: NameMatcher,
        walker: FileManager.DirectoryEnumerator, into result: inout Scanned
    ) {
        let path = url.path
        guard path.hasPrefix(prefix) else { return }
        let relative = String(path.dropFirst(prefix.count))
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        let item = readScannedItem(url: url, root: root, relative: relative, sameRoot: sameRoot, stat: st)
        if shouldSkipSubtree(relative: relative, isDirectory: item.isDirectory, onlyNames: config.onlyNames, walker: walker) {
            return
        }
        let info = SyncFileInfo(url: item.url, size: item.size, modified: item.modified, isDirectory: item.isDirectory)
        recordScannedEntry(info: info, name: item.name, relative: relative,
                           config: config, names: names, walker: walker, into: &result)
    }

    private static func shouldSkipSubtree(
        relative: String, isDirectory: Bool, onlyNames: Set<String>?, walker: FileManager.DirectoryEnumerator
    ) -> Bool {
        let top = String(relative.split(separator: "/").first ?? "")
        guard let only = onlyNames, !only.contains(top) else { return false }
        // Only call skipDescendants on folders: on a file it would skip the last folder seen instead.
        if isDirectory { walker.skipDescendants() }
        return true
    }

    private static func readScannedItem(url: URL, root: URL, relative: String, sameRoot: Bool, stat st: stat) -> SearchItem {
        if sameRoot { return SearchItem.read(url, stat: st) }
        return SearchItem.read(root.appendingPathComponent(relative, isDirectory: (st.st_mode & S_IFMT) == S_IFDIR), stat: st)
    }

    private static func recordScannedEntry(
        info: SyncFileInfo,
        name: String,
        relative: String,
        config: SyncConfiguration,
        names: NameMatcher,
        walker: FileManager.DirectoryEnumerator,
        into result: inout Scanned
    ) {
        if info.isDirectory {
            if !config.subdirectories { walker.skipDescendants() }
            result.directories[relative] = info
        } else if names.matches(name) {
            result.files[relative] = info
            var parent = (relative as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                result.nonEmpty.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    /// A folder on a server, read listing by listing (links are reported, not followed).
    static func scanRemote(_ root: URL, session: RemoteSession, config: SyncConfiguration, names: NameMatcher,
                           errors: inout [String], isCancelled: () -> Bool) -> Scanned {
        var result = Scanned()
        let base = RemoteSession.path(of: root)
        var queue = [""]
        var next = 0
        var count = 0
        while next < queue.count, !isCancelled() {
            let relativeDir = queue[next]
            next += 1
            guard withinRemoteLimits(relativeDir: relativeDir, count: count, base: base, session: session, errors: &errors) else { break }
            scanRemoteDirectory(relativeDir, base: base, session: session, config: config, names: names,
                                count: &count, result: &result, queue: &queue, errors: &errors)
        }
        return result
    }

    private static func scanRemoteDirectory(
        _ relativeDir: String, base: String, session: RemoteSession,
        config: SyncConfiguration, names: NameMatcher,
        count: inout Int, result: inout Scanned, queue: inout [String], errors: inout [String]
    ) {
        let dir = relativeDir.isEmpty ? base : (base == "/" ? "/" : base + "/") + relativeDir
        guard let listing = fetchRemoteListing(dir, session: session, errors: &errors) else { return }
        count += listing.count
        for entry in listing {
            processRemoteEntry(entry, relativeDir: relativeDir, dir: dir, session: session,
                               config: config, names: names, result: &result, queue: &queue, errors: &errors)
        }
    }

    private static func withinRemoteLimits(
        relativeDir: String, count: Int, base: String, session: RemoteSession, errors: inout [String]
    ) -> Bool {
        if relativeDir.split(separator: "/").count > RemoteSession.maxDepth || count > RemoteSession.maxEntries {
            errors.append("\(session.addressLabel)\(base): \(RemoteSession.tooLarge.message) Stopped reading there.")
            return false
        }
        return true
    }

    private static func fetchRemoteListing(_ dir: String, session: RemoteSession, errors: inout [String]) -> [RemoteEntry]? {
        do { return try session.fetch(dir, useCache: false, store: false) } catch {
            errors.append("\(session.addressLabel)\(dir): \((error as? FTPError)?.message ?? error.localizedDescription)")
            return nil
        }
    }

    private static func processRemoteEntry(
        _ entry: RemoteEntry,
        relativeDir: String,
        dir: String,
        session: RemoteSession,
        config: SyncConfiguration,
        names: NameMatcher,
        result: inout Scanned,
        queue: inout [String],
        errors: inout [String]
    ) {
        let relative = relativeDir.isEmpty ? entry.name : relativeDir + "/" + entry.name
        if let only = config.onlyNames, !only.contains(String(relative.split(separator: "/").first ?? "")) { return }
        if entry.isLink {
            errors.append("\(session.addressLabel)\(dir)/\(entry.name): a link on the server, not compared")
            return
        }
        let info = remoteFileInfo(entry, dir: dir, session: session)
        recordRemoteEntry(info: info, entry: entry, relative: relative, config: config, names: names, result: &result, queue: &queue)
    }

    private static func remoteFileInfo(_ entry: RemoteEntry, dir: String, session: RemoteSession) -> SyncFileInfo {
        let path = (dir == "/" ? "" : dir) + "/" + entry.name
        return SyncFileInfo(url: session.url(for: path), size: entry.size,
                            modified: entry.modified ?? .distantPast, isDirectory: entry.isDirectory,
                            datePrecision: entry.datePrecision)
    }

    private static func recordRemoteEntry(
        info: SyncFileInfo, entry: RemoteEntry, relative: String,
        config: SyncConfiguration, names: NameMatcher, result: inout Scanned, queue: inout [String]
    ) {
        if entry.isDirectory {
            result.directories[relative] = info
            if config.subdirectories { queue.append(relative) }
        } else if names.matches(entry.name) {
            recordRemoteFile(info, relative: relative, into: &result)
        }
    }

    private static func recordRemoteFile(_ info: SyncFileInfo, relative: String, into result: inout Scanned) {
        result.files[relative] = info
        var parent = (relative as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            result.nonEmpty.insert(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    // MARK: Comparing (read-only)

    public static func compare(_ config: SyncConfiguration, sessions: SyncSessionLookup = { _ in nil },
                               isCancelled: () -> Bool = { false },
                               progress: (String) -> Void = { _ in }) throws -> SyncComparison {
        let names = try NameMatcher(pattern: config.mask.isEmpty ? "*.*" : config.mask, regex: false)
        try validateFolders(config, sessions: sessions)

        var result = SyncComparison()
        let left = readSide(config.left, config: config, names: names, sessions: sessions,
                            isCancelled: isCancelled, progress: progress, errors: &result.errors)
        let right = readSide(config.right, config: config, names: names, sessions: sessions,
                             isCancelled: isCancelled, progress: progress, errors: &result.errors)
        let contentConfig = resolveContentConfig(config, errors: &result.errors)
        var rows = buildFileRows(left: left, right: right, config: contentConfig, isCancelled: isCancelled, errors: &result.errors)
        if config.emptyDirectories {
            rows += emptyDirectoryRows(left: left, right: right, config: config, errors: &result.errors)
        }
        result.rows = rows.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        result.cancelled = isCancelled()
        return result
    }

    private static func resolveContentConfig(_ config: SyncConfiguration, errors: inout [String]) -> SyncConfiguration {
        var resolved = config
        if config.byContent && (config.left.isRemoteLocation || config.right.isRemoteLocation) {
            // Comparing content would mean downloading every file pair.
            resolved.byContent = false
            errors.append("“by content” is not available for server folders: files were compared by size and date.")
        }
        return resolved
    }

    private static func readSide(
        _ url: URL, config: SyncConfiguration, names: NameMatcher,
        sessions: SyncSessionLookup, isCancelled: () -> Bool,
        progress: (String) -> Void, errors: inout [String]
    ) -> Scanned {
        if let session = sessions(url) {
            progress("Reading \(session.addressLabel)\(RemoteSession.path(of: url))")
            return scanRemote(url, session: session, config: config, names: names, errors: &errors, isCancelled: isCancelled)
        }
        progress("Reading \(url.path)")
        return scan(url, config: config, names: names, errors: &errors, isCancelled: isCancelled)
    }

    private static func buildFileRows(
        left: Scanned, right: Scanned, config: SyncConfiguration,
        isCancelled: () -> Bool, errors: inout [String]
    ) -> [SyncRow] {
        var rows: [SyncRow] = []
        for path in Set(left.files.keys).union(right.files.keys) {
            if isCancelled() { break }
            let a = left.files[path], b = right.files[path]
            let (state, action) = decide(a, b, config: config, errors: &errors)
            rows.append(SyncRow(path: path, left: a, right: b, state: state, action: action, recommended: action))
        }
        return rows
    }

    private static func validateFolders(_ config: SyncConfiguration, sessions: SyncSessionLookup) throws {
        for (side, url) in [("Left", config.left), ("Right", config.right)] {
            try validateSingleFolder(side: side, url: url, sessions: sessions)
        }
        try ensureSeparateFolders(config.left, config.right)
    }

    private static func validateSingleFolder(side: String, url: URL, sessions: SyncSessionLookup) throws {
        if url.isRemoteLocation {
            guard let session = sessions(url) else {
                throw SearchValidationError(message: "\(side): the server connection is closed. Connect again.")
            }
            let path = RemoteSession.path(of: url)
            do { _ = try session.fetch(path, useCache: false) } catch {
                throw SearchValidationError(message: "\(side) folder “\(session.addressLabel)\(path)” cannot be read: \((error as? FTPError)?.message ?? error.localizedDescription)")
            }
            return
        }
        var fm: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &fm), fm.boolValue else {
            throw SearchValidationError(message: "\(side) folder “\(url.path)” does not exist.")
        }
    }

    private static func ensureSeparateFolders(_ left: URL, _ right: URL) throws {
        // Same folder, or one inside the other (only possible on the same Mac or the same connection).
        let l = folderIdentity(left)
        let r = folderIdentity(right)
        if l == r { throw SearchValidationError(message: "Left and right are the same folder.") }
        if isParentPath(r, of: l) || isParentPath(l, of: r) {
            throw SearchValidationError(message: "One folder is inside the other; choose two separate folders.")
        }
    }

    private static func folderIdentity(_ url: URL) -> String {
        url.isRemoteLocation ? url.normalizedLocation.absoluteString : FileSystemLister.realPath(of: url).path
    }

    private static func isParentPath(_ parent: String, of child: String) -> Bool {
        child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private static func emptyDirectoryRows(
        left: Scanned, right: Scanned, config: SyncConfiguration, errors: inout [String]
    ) -> [SyncRow] {
        var rows: [SyncRow] = []
        for path in Set(left.directories.keys).union(right.directories.keys) {
            guard isOneSidedEmptyDirectory(path: path, left: left, right: right) else { continue }
            let a = left.directories[path], b = right.directories[path]
            let (state, action) = decide(a, b, config: config, errors: &errors)
            rows.append(SyncRow(path: path, left: a, right: b, state: state, action: action, recommended: action))
        }
        return rows
    }

    private static func isOneSidedEmptyDirectory(path: String, left: Scanned, right: Scanned) -> Bool {
        let a = left.directories[path], b = right.directories[path]
        guard a == nil || b == nil else { return false }
        return isEmptyOnSide(a, path: path, in: left) || isEmptyOnSide(b, path: path, in: right)
    }

    private static func isEmptyOnSide(_ dir: SyncFileInfo?, path: String, in scanned: Scanned) -> Bool {
        dir != nil && !scanned.nonEmpty.contains(path)
    }

    /// The state of a pair and the recommended action (the ActionPlanner).
    static func decide(_ a: SyncFileInfo?, _ b: SyncFileInfo?, config: SyncConfiguration,
                       errors: inout [String]) -> (SyncState, SyncAction) {
        if let a = a, let b = b { return decidePair(a, b, config: config, errors: &errors) }
        if a != nil { return (.leftOnly, .copyToRight) }
        if b != nil { return (.rightOnly, config.asymmetric ? .deleteRight : .copyToLeft) }
        return (.identical, .none)
    }

    private static func decidePair(_ a: SyncFileInfo, _ b: SyncFileInfo, config: SyncConfiguration,
                                   errors: inout [String]) -> (SyncState, SyncAction) {
        if a.isDirectory || b.isDirectory { return (.identical, .none) }
        let dateDelta = a.modified.timeIntervalSince(b.modified)
        let tolerance = max(dateTolerance, a.datePrecision, b.datePrecision)
        let sameDate = abs(dateDelta) < max(tolerance, dateTolerance + 0.001)
        if filesMatch(a, b, sameSize: a.size == b.size, sameDate: sameDate, config: config, errors: &errors) {
            return (.identical, .none)
        }
        return decideDifferingPair(dateDelta: dateDelta, tolerance: tolerance, sameDate: sameDate, config: config)
    }

    private static func decideDifferingPair(
        dateDelta: TimeInterval, tolerance: TimeInterval, sameDate: Bool, config: SyncConfiguration
    ) -> (SyncState, SyncAction) {
        if config.asymmetric { return (dateDelta < -tolerance ? .rightNewer : .leftNewer, .copyToRight) }
        if config.ignoreDate || sameDate { return (.different, .none) }
        return dateDelta > 0 ? (.leftNewer, .copyToRight) : (.rightNewer, .copyToLeft)
    }

    private static func filesMatch(
        _ a: SyncFileInfo, _ b: SyncFileInfo,
        sameSize: Bool, sameDate: Bool,
        config: SyncConfiguration, errors: inout [String]
    ) -> Bool {
        if config.byContent && sameSize { return contentsMatch(a.url, b.url, errors: &errors) }
        return sameSize && (config.ignoreDate || sameDate)
    }

    private static func contentsMatch(_ a: URL, _ b: URL, errors: inout [String]) -> Bool {
        let same = DuplicateFinder.identical(a, b)
        if !same && !FileManager.default.isReadableFile(atPath: a.path) {
            errors.append("\(a.path): could not be read")
        }
        return same
    }

    // MARK: Planning

    /// Actions the user may pick for a row, in the order a click cycles through them.
    public static func choices(for row: SyncRow) -> [SyncAction] {
        var list: [SyncAction] = []
        if row.left != nil { list.append(.copyToRight) }
        if row.right != nil { list.append(.copyToLeft) }
        if row.left == nil, row.right != nil { list.append(.deleteRight) }
        if row.right == nil, row.left != nil { list.append(.deleteLeft) }
        list.append(.none)
        return list
    }

    /// Space in the list: ← , = (nothing), delete, → — only those possible for the row.
    public static func spaceCycle(_ row: SyncRow) -> SyncAction {
        let possible = choices(for: row)
        let order = [SyncAction.copyToLeft, .none, .deleteLeft, .deleteRight, .copyToRight].filter { possible.contains($0) }
        guard let i = order.firstIndex(of: row.action) else { return order.first ?? .none }
        return order[(i + 1) % order.count]
    }

    /// Sorts rows for the list: by name (path), size, date of a side, or the action column.
    public enum SortKey: String { case leftName, leftSize, leftDate, action, rightDate, rightSize, rightName }

    public static func sorted(_ indexes: [Int], of rows: [SyncRow], by key: SortKey, ascending: Bool) -> [Int] {
        return indexes.sorted { i, j in
            let r = compareRows(rows[i], rows[j], by: key)
            if r == .orderedSame { return rows[i].path.localizedStandardCompare(rows[j].path) == .orderedAscending }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }

    private static func compareRows(_ a: SyncRow, _ b: SyncRow, by key: SortKey) -> ComparisonResult {
        if key == .leftName || key == .rightName { return a.path.localizedStandardCompare(b.path) }
        if key == .action { return (a.action.symbol + a.symbol).compare(b.action.symbol + b.symbol) }
        return compareMetadataRows(a, b, by: key)
    }

    private static func compareMetadataRows(_ a: SyncRow, _ b: SyncRow, by key: SortKey) -> ComparisonResult {
        switch key {
        case .leftSize: return compareOptional(a.left?.size, b.left?.size)
        case .rightSize: return compareOptional(a.right?.size, b.right?.size)
        case .leftDate: return compareOptional(a.left?.modified, b.left?.modified)
        default: return compareOptional(a.right?.modified, b.right?.modified)
        }
    }

    private static func compareOptional<T: Comparable>(_ x: T?, _ y: T?) -> ComparisonResult {
        guard let x = x else { return y == nil ? .orderedSame : .orderedAscending }
        guard let y = y else { return .orderedDescending }
        if x == y { return .orderedSame }
        return x < y ? .orderedAscending : .orderedDescending
    }

    /// The next choice after the current action (click on the middle column).
    public static func cycle(_ row: SyncRow) -> SyncAction {
        let options = choices(for: row)
        let i = options.firstIndex(of: row.action) ?? (options.count - 1)
        return options[(i + 1) % options.count]
    }
}

/// One file operation of a synchronisation, traceable to its comparison row.
public struct SyncOperation: Equatable {
    public enum Kind: Equatable { case copy, delete, makeDirectory }
    public let kind: Kind
    public let row: SyncRow
    public let source: URL?
    public let destination: URL
    public let bytes: Int64
    /// The copy replaces an existing file.
    public let overwrites: Bool
}

public struct SyncPlan: Equatable {
    public var toRight: [SyncOperation] = []
    public var toLeft: [SyncOperation] = []
    public var deletions: [SyncOperation] = []

    public init(rows: [SyncRow], config: SyncConfiguration) {
        for row in rows {
            switch row.action {
            case .none: break
            case .copyToRight, .copyToLeft: addCopyOperation(row: row, config: config, goesRight: row.action == .copyToRight)
            case .deleteRight, .deleteLeft: addDeleteOperation(row: row, deleteRight: row.action == .deleteRight)
            }
        }
    }

    private mutating func addCopyOperation(row: SyncRow, config: SyncConfiguration, goesRight: Bool) {
        guard let src = goesRight ? row.left : row.right else { return }
        let op = Self.makeCopyOperation(row: row, src: src, config: config, goesRight: goesRight)
        if goesRight { toRight.append(op) } else { toLeft.append(op) }
    }

    private static func makeCopyOperation(
        row: SyncRow, src: SyncFileInfo, config: SyncConfiguration, goesRight: Bool
    ) -> SyncOperation {
        let dest = (goesRight ? config.right : config.left).appendingPathComponent(row.path)
        let overwrites = (goesRight ? row.right : row.left) != nil
        return SyncOperation(kind: src.isDirectory ? .makeDirectory : .copy, row: row, source: src.url,
                             destination: dest, bytes: src.isDirectory ? 0 : src.size, overwrites: overwrites)
    }

    private mutating func addDeleteOperation(row: SyncRow, deleteRight: Bool) {
        guard let target = deleteRight ? row.right : row.left else { return }
        deletions.append(SyncOperation(kind: .delete, row: row, source: nil, destination: target.url,
                                       bytes: target.size, overwrites: false))
    }

    public var all: [SyncOperation] { toRight + toLeft + deletions }
    public var isEmpty: Bool { all.isEmpty }

    public static func bytes(_ ops: [SyncOperation]) -> Int64 { ops.reduce(0) { $0.addingSaturated($1.bytes) } }
}

/// What the user allowed in the Synchronize dialog.
public struct SyncRunOptions: Equatable {
    public var leftToRight = true
    public var rightToLeft = true
    public var delete = true
    /// Replace files that exist at the destination (off: such copies are skipped).
    public var overwrite = true
    public var createEmptyDirectories = true
    public init() {}
}

public struct SyncReport: Equatable {
    public var copied = 0
    public var deleted = 0
    public var created = 0
    public var skipped: [String] = []
    public var errors: [String] = []
    public var cancelled = false
}

/// Executes a confirmed plan. Before touching a file it checks that both sides still look as they
/// did when compared; anything changed meanwhile is skipped and reported. Local deletions go to the
/// Trash; on a server there is no Trash, so deletions there are permanent (the dialog says so).
/// Either side may be a connected server: copies then become uploads or downloads.
public enum SyncExecutor {
    public static func run(_ plan: SyncPlan, options: SyncRunOptions,
                           sessions: @escaping SyncSessionLookup = { _ in nil },
                           isCancelled: @escaping () -> Bool = { false },
                           progress: (SyncOperation) -> Void = { _ in },
                           trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        -> SyncReport {
        var report = SyncReport()
        let ops = selectedOperations(from: plan, options: options)
        var touched: [ObjectIdentifier: RemoteSession] = [:]
        defer { for s in touched.values { s.invalidate() } }
        let files = SyncFiles(sessions: sessions)
        executeOperations(ops, options: options, files: files, sessions: sessions,
                          touched: &touched, isCancelled: isCancelled, progress: progress, trash: trash, report: &report)
        return report
    }

    private static func executeOperations(
        _ ops: [SyncOperation], options: SyncRunOptions, files: SyncFiles,
        sessions: SyncSessionLookup, touched: inout [ObjectIdentifier: RemoteSession],
        isCancelled: @escaping () -> Bool, progress: (SyncOperation) -> Void,
        trash: (URL) throws -> Void, report: inout SyncReport
    ) {
        for op in ops {
            if isCancelled() { report.cancelled = true; break }
            progress(op)
            if executeUnchangedOperation(op, options: options, files: files, sessions: sessions,
                                         touched: &touched, isCancelled: isCancelled, trash: trash, report: &report) {
                break
            }
        }
    }

    private static func executeUnchangedOperation(
        _ op: SyncOperation, options: SyncRunOptions, files: SyncFiles,
        sessions: SyncSessionLookup, touched: inout [ObjectIdentifier: RemoteSession],
        isCancelled: @escaping () -> Bool, trash: (URL) throws -> Void, report: inout SyncReport
    ) -> Bool {
        guard files.unchanged(op.row.left) && files.unchanged(op.row.right) else {
            report.skipped.append("\(op.row.path): changed since the comparison")
            return false
        }
        recordTouchedSessions(for: op, sessions: sessions, into: &touched)
        return runSingleOperation(op, options: options, files: files, sessions: sessions,
                                  isCancelled: isCancelled, trash: trash, report: &report)
    }

    private static func recordTouchedSessions(
        for op: SyncOperation, sessions: SyncSessionLookup, into touched: inout [ObjectIdentifier: RemoteSession]
    ) {
        for url in [op.source, op.destination].compactMap({ $0 }) {
            if let s = sessions(url) { touched[ObjectIdentifier(s)] = s }
        }
    }

    private static func selectedOperations(from plan: SyncPlan, options: SyncRunOptions) -> [SyncOperation] {
        var ops: [SyncOperation] = []
        if options.leftToRight { ops += plan.toRight }
        if options.rightToLeft { ops += plan.toLeft }
        if options.delete { ops += plan.deletions }
        return ops
    }

    private static func runSingleOperation(
        _ op: SyncOperation, options: SyncRunOptions, files: SyncFiles,
        sessions: SyncSessionLookup, isCancelled: @escaping () -> Bool,
        trash: (URL) throws -> Void, report: inout SyncReport
    ) -> Bool {
        do {
            try executeOperation(op, options: options, files: files, sessions: sessions,
                                 isCancelled: isCancelled, trash: trash, report: &report)
        } catch FTPError.cancelled {
            report.cancelled = true
            return true
        } catch let e as FTPError {
            report.errors.append("\(op.row.path): \(e.message)")
        } catch {
            report.errors.append("\(op.row.path): \(error.localizedDescription)")
        }
        return false
    }

    private static func executeOperation(
        _ op: SyncOperation,
        options: SyncRunOptions,
        files: SyncFiles,
        sessions: SyncSessionLookup,
        isCancelled: @escaping () -> Bool,
        trash: (URL) throws -> Void,
        report: inout SyncReport
    ) throws {
        switch op.kind {
        case .makeDirectory:
            guard options.createEmptyDirectories else { report.skipped.append("\(op.row.path): empty folder"); return }
            try files.makeDirectory(op.destination)
            report.created += 1
        case .copy:
            try executeCopy(op, options: options, files: files, isCancelled: isCancelled, report: &report)
        case .delete:
            try executeDelete(op, sessions: sessions, trash: trash, report: &report)
        }
    }

    private static func executeCopy(
        _ op: SyncOperation, options: SyncRunOptions, files: SyncFiles,
        isCancelled: @escaping () -> Bool, report: inout SyncReport
    ) throws {
        guard let src = op.source else { return }
        let exists = files.exists(op.destination)
        if let reason = copySkipReason(op: op, exists: exists, options: options) {
            report.skipped.append(reason)
            return
        }
        let info = op.row.action == .copyToRight ? op.row.left : op.row.right
        try files.copy(src, to: op.destination, info: info, replacing: exists, isCancelled: isCancelled)
        report.copied += 1
    }

    private static func copySkipReason(op: SyncOperation, exists: Bool, options: SyncRunOptions) -> String? {
        if !op.overwrites && exists { return "\(op.row.path): appeared at the destination since the comparison" }
        if exists && !options.overwrite { return "\(op.row.path): exists, not overwritten" }
        return nil
    }

    private static func executeDelete(
        _ op: SyncOperation, sessions: SyncSessionLookup,
        trash: (URL) throws -> Void, report: inout SyncReport
    ) throws {
        if let session = sessions(op.destination) {
            let path = RemoteSession.path(of: op.destination)
            if op.row.isDirectory { try session.client.removeDirectory(path) } else { try session.client.deleteFile(path) }
        } else {
            try trash(op.destination)
        }
        report.deleted += 1
    }

}

/// File access for synchronizing, on this Mac or on a connected server.
final class SyncFiles {
    let sessions: SyncSessionLookup
    /// Fresh server listings per folder, read once per run.
    private var listings: [String: [RemoteEntry]] = [:]

    init(sessions: @escaping SyncSessionLookup) { self.sessions = sessions }

    private func remoteEntry(_ url: URL, session: RemoteSession) -> RemoteEntry? {
        let path = RemoteSession.path(of: url)
        let dir = (path as NSString).deletingLastPathComponent
        let key = session.id.uuidString + dir
        if listings[key] == nil { listings[key] = (try? session.client.list(dir.isEmpty ? "/" : dir, cancel: nil)) ?? [] }
        return listings[key]?.first { $0.name == (path as NSString).lastPathComponent }
    }

    func exists(_ url: URL) -> Bool {
        if let s = sessions(url) { return remoteEntry(url, session: s) != nil }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The side still looks as it did when compared.
    func unchanged(_ info: SyncFileInfo?) -> Bool {
        guard let info = info else { return true }
        if let s = sessions(info.url) { return unchangedRemote(info, session: s) }
        return unchangedLocal(info)
    }

    private func unchangedLocal(_ info: SyncFileInfo) -> Bool {
        guard let now = SearchItem.read(info.url) else { return false }
        if info.isDirectory { return now.isDirectory }
        return now.size == info.size && abs(now.modified.timeIntervalSince(info.modified)) < 0.001
    }

    private func unchangedRemote(_ info: SyncFileInfo, session: RemoteSession) -> Bool {
        guard let now = remoteEntry(info.url, session: session) else { return false }
        if info.isDirectory { return now.isDirectory }
        return now.size == info.size && (now.modified ?? .distantPast) == info.modified
    }

    func makeDirectory(_ url: URL) throws {
        if let s = sessions(url) {
            let path = RemoteSession.path(of: url)
            if remoteEntry(url, session: s)?.isDirectory == true { return }
            try makeRemoteParents(path, session: s)
            try s.client.makeDirectory(path)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Creates the folders above a remote path (errors for folders that already exist are ignored).
    private func makeRemoteParents(_ path: String, session: RemoteSession) throws {
        var parent = ""
        for part in path.split(separator: "/").dropLast() {
            parent += "/" + part
            try? session.client.makeDirectory(parent)
        }
    }

    /// Copies a file (keeping its date where the protocol allows), replacing the destination if asked.
    func copy(_ src: URL, to dst: URL, info: SyncFileInfo?, replacing: Bool, isCancelled: @escaping () -> Bool) throws {
        let cancel = CancelFlag()
        let watch = { if isCancelled() { cancel.cancel() } }
        switch (sessions(src), sessions(dst)) {
        case (nil, nil):
            try copyLocalToLocal(src, to: dst, replacing: replacing)
        case let (nil, to?):
            try copyLocalToRemote(src, to: dst, session: to, cancel: cancel, watch: watch)
        case let (from?, nil):
            try copyRemoteToLocal(src, to: dst, session: from, info: info, cancel: cancel, watch: watch)
        case let (from?, to?):
            try copyRemoteToRemote(src, to: dst, from: from, toSession: to, info: info, cancel: cancel, watch: watch)
        }
    }

    private func copyLocalToLocal(_ src: URL, to dst: URL, replacing: Bool) throws {
        let fm = FileManager.default
        if replacing { try fm.removeItem(at: dst) }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: dst)   // keeps the modification date
    }

    private func copyLocalToRemote(_ src: URL, to dst: URL, session: RemoteSession, cancel: CancelFlag, watch: @escaping () -> Void) throws {
        watch()
        try session.client.upload(src, to: RemoteSession.path(of: dst), resume: false, cancel: cancel, progress: { _ in watch() })
        if let date = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            try? session.client.setModificationDate(date, of: RemoteSession.path(of: dst))
        }
    }

    private func copyRemoteToLocal(
        _ src: URL, to dst: URL, session: RemoteSession, info: SyncFileInfo?, cancel: CancelFlag, watch: @escaping () -> Void
    ) throws {
        try session.client.download(RemoteSession.path(of: src), to: dst, expectedSize: info?.size, resume: false,
                                    cancel: cancel, progress: { _ in watch() })
        if !session.profile.isSFTP, let date = info?.modified, date != .distantPast {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dst.path)
        }
    }

    private func copyRemoteToRemote(
        _ src: URL, to dst: URL, from: RemoteSession, toSession: RemoteSession,
        info: SyncFileInfo?, cancel: CancelFlag, watch: @escaping () -> Void
    ) throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("cc-sync-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try from.client.download(RemoteSession.path(of: src), to: temp, expectedSize: info?.size, resume: false,
                                 cancel: cancel, progress: { _ in watch() })
        try toSession.client.upload(temp, to: RemoteSession.path(of: dst), resume: false, cancel: cancel, progress: { _ in watch() })
        if let date = info?.modified, date != .distantPast { try? toSession.client.setModificationDate(date, of: RemoteSession.path(of: dst)) }
    }
}
