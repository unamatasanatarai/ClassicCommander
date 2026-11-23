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
        switch row.action {
        case .copyToRight: return copyRight
        case .copyToLeft: return copyLeft
        case .deleteRight, .deleteLeft: return copyRight || copyLeft
        case .none: return row.state == .identical ? equal : different
        }
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
        for case let url as URL in walker {
            if isCancelled() { break }
            let path = url.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let item = sameRoot ? SearchItem.read(url, stat: st)
                : SearchItem.read(root.appendingPathComponent(relative, isDirectory: (st.st_mode & S_IFMT) == S_IFDIR), stat: st)
            let top = String(relative.split(separator: "/").first ?? "")
            if let only = config.onlyNames, !only.contains(top) {
                // Only call skipDescendants on folders: on a file it would skip the last folder seen instead.
                if item.isDirectory { walker.skipDescendants() }
                continue
            }
            let info = SyncFileInfo(url: item.url, size: item.size,
                                    modified: item.modified, isDirectory: item.isDirectory)
            if item.isDirectory {
                if !config.subdirectories { walker.skipDescendants() }
                result.directories[relative] = info
            } else if names.matches(item.name) {
                result.files[relative] = info
                var parent = (relative as NSString).deletingLastPathComponent
                while !parent.isEmpty {
                    result.nonEmpty.insert(parent)
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
        }
        errors += walkErrors
        return result
    }

    /// A folder on a server, read listing by listing (links are reported, not followed).
    static func scanRemote(_ root: URL, session: RemoteSession, config: SyncConfiguration, names: NameMatcher,
                           errors: inout [String], isCancelled: () -> Bool) -> Scanned {
        var result = Scanned()
        let base = RemoteSession.path(of: root)
        var queue = [""]
        var next = 0
        var count = 0
        while next < queue.count {
            let relativeDir = queue[next]
            next += 1
            if isCancelled() { break }
            if relativeDir.split(separator: "/").count > RemoteSession.maxDepth || count > RemoteSession.maxEntries {
                errors.append("\(session.addressLabel)\(base): \(RemoteSession.tooLarge.message) Stopped reading there.")
                break
            }
            let dir = relativeDir.isEmpty ? base : (base == "/" ? "/" : base + "/") + relativeDir
            let listing: [RemoteEntry]
            do { listing = try session.fetch(dir, useCache: false, store: false) } catch {
                errors.append("\(session.addressLabel)\(dir): \((error as? FTPError)?.message ?? error.localizedDescription)")
                continue
            }
            count += listing.count
            for entry in listing {
                let relative = relativeDir.isEmpty ? entry.name : relativeDir + "/" + entry.name
                let top = String(relative.split(separator: "/").first ?? "")
                if let only = config.onlyNames, !only.contains(top) { continue }
                if entry.isLink {
                    errors.append("\(session.addressLabel)\(dir)/\(entry.name): a link on the server, not compared")
                    continue
                }
                let path = (dir == "/" ? "" : dir) + "/" + entry.name
                let info = SyncFileInfo(url: session.url(for: path), size: entry.size,
                                        modified: entry.modified ?? .distantPast, isDirectory: entry.isDirectory,
                                        datePrecision: entry.datePrecision)
                if entry.isDirectory {
                    result.directories[relative] = info
                    if config.subdirectories { queue.append(relative) }
                } else if names.matches(entry.name) {
                    result.files[relative] = info
                    var parent = (relative as NSString).deletingLastPathComponent
                    while !parent.isEmpty {
                        result.nonEmpty.insert(parent)
                        parent = (parent as NSString).deletingLastPathComponent
                    }
                }
            }
        }
        return result
    }

    // MARK: Comparing (read-only)

    public static func compare(_ config: SyncConfiguration, sessions: SyncSessionLookup = { _ in nil },
                               isCancelled: () -> Bool = { false },
                               progress: (String) -> Void = { _ in }) throws -> SyncComparison {
        let names = try NameMatcher(pattern: config.mask.isEmpty ? "*.*" : config.mask, regex: false)
        var fm: ObjCBool = false
        for (side, url) in [("Left", config.left), ("Right", config.right)] {
            if url.isRemoteLocation {
                guard let session = sessions(url) else {
                    throw SearchValidationError(message: "\(side): the server connection is closed. Connect again.")
                }
                let path = RemoteSession.path(of: url)
                do { _ = try session.fetch(path, useCache: false) } catch {
                    throw SearchValidationError(message: "\(side) folder “\(session.addressLabel)\(path)” cannot be read: \((error as? FTPError)?.message ?? error.localizedDescription)")
                }
            } else {
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &fm), fm.boolValue else {
                    throw SearchValidationError(message: "\(side) folder “\(url.path)” does not exist.")
                }
            }
        }
        // Same folder, or one inside the other (only possible on the same Mac or the same connection).
        let l = config.left.isRemoteLocation ? config.left.normalizedLocation.absoluteString : FileSystemLister.realPath(of: config.left).path
        let r = config.right.isRemoteLocation ? config.right.normalizedLocation.absoluteString : FileSystemLister.realPath(of: config.right).path
        if l == r { throw SearchValidationError(message: "Left and right are the same folder.") }
        if l.hasPrefix(r.hasSuffix("/") ? r : r + "/") || r.hasPrefix(l.hasSuffix("/") ? l : l + "/") {
            throw SearchValidationError(message: "One folder is inside the other; choose two separate folders.")
        }

        var result = SyncComparison()
        func read(_ url: URL) -> Scanned {
            if let session = sessions(url) {
                progress("Reading \(session.addressLabel)\(RemoteSession.path(of: url))")
                return scanRemote(url, session: session, config: config, names: names, errors: &result.errors, isCancelled: isCancelled)
            }
            progress("Reading \(url.path)")
            return scan(url, config: config, names: names, errors: &result.errors, isCancelled: isCancelled)
        }
        let left = read(config.left)
        let right = read(config.right)
        var contentConfig = config
        if config.byContent && (config.left.isRemoteLocation || config.right.isRemoteLocation) {
            // Comparing content would mean downloading every file pair.
            contentConfig.byContent = false
            result.errors.append("“by content” is not available for server folders: files were compared by size and date.")
        }

        var rows: [SyncRow] = []
        for path in Set(left.files.keys).union(right.files.keys) {
            if isCancelled() { break }
            let a = left.files[path], b = right.files[path]
            let (state, action) = decide(a, b, config: contentConfig, errors: &result.errors)
            rows.append(SyncRow(path: path, left: a, right: b, state: state, action: action, recommended: action))
        }
        if config.emptyDirectories {
            // Folders that would otherwise not appear: empty ones, or ones present on one side only.
            for path in Set(left.directories.keys).union(right.directories.keys) {
                let a = left.directories[path], b = right.directories[path]
                let emptyL = a != nil && !left.nonEmpty.contains(path), emptyR = b != nil && !right.nonEmpty.contains(path)
                if a != nil && b != nil { continue }
                guard emptyL || emptyR else { continue }
                let (state, action) = decide(a, b, config: config, errors: &result.errors)
                rows.append(SyncRow(path: path, left: a, right: b, state: state, action: action, recommended: action))
            }
        }
        result.rows = rows.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        result.cancelled = isCancelled()
        return result
    }

    /// The state of a pair and the recommended action (the ActionPlanner).
    static func decide(_ a: SyncFileInfo?, _ b: SyncFileInfo?, config: SyncConfiguration,
                       errors: inout [String]) -> (SyncState, SyncAction) {
        switch (a, b) {
        case (nil, nil):
            return (.identical, .none)
        case (_?, nil):
            return (.leftOnly, .copyToRight)
        case (nil, _?):
            return (.rightOnly, config.asymmetric ? .deleteRight : .copyToLeft)
        case let (a?, b?):
            if a.isDirectory || b.isDirectory { return (.identical, .none) }
            let sameSize = a.size == b.size
            let dateDelta = a.modified.timeIntervalSince(b.modified)
            // Server listings may only give minutes (or days): dates within that step count as equal.
            let tolerance = max(dateTolerance, a.datePrecision, b.datePrecision)
            let sameDate = abs(dateDelta) < max(tolerance, dateTolerance + 0.001)
            var same: Bool
            if config.byContent && sameSize {
                same = DuplicateFinder.identical(a.url, b.url)
                if !same && !FileManager.default.isReadableFile(atPath: a.url.path) {
                    errors.append("\(a.url.path): could not be read")
                }
            } else {
                same = sameSize && (config.ignoreDate || sameDate)
            }
            if same { return (.identical, .none) }
            if config.asymmetric { return (dateDelta < -tolerance ? .rightNewer : .leftNewer, .copyToRight) }
            if config.ignoreDate || sameDate { return (.different, .none) }
            return dateDelta > 0 ? (.leftNewer, .copyToRight) : (.rightNewer, .copyToLeft)
        }
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
        func compare(_ a: SyncRow, _ b: SyncRow) -> ComparisonResult {
            func num<T: Comparable>(_ x: T?, _ y: T?) -> ComparisonResult {
                switch (x, y) {
                case let (x?, y?): return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
                case (nil, nil): return .orderedSame
                case (nil, _): return .orderedAscending      // missing on that side sorts first
                case (_, nil): return .orderedDescending
                }
            }
            switch key {
            case .leftName, .rightName: return a.path.localizedStandardCompare(b.path)
            case .leftSize: return num(a.left?.size, b.left?.size)
            case .rightSize: return num(a.right?.size, b.right?.size)
            case .leftDate: return num(a.left?.modified, b.left?.modified)
            case .rightDate: return num(a.right?.modified, b.right?.modified)
            case .action: return (a.action.symbol + a.symbol).compare(b.action.symbol + b.symbol)
            }
        }
        return indexes.sorted { i, j in
            let r = compare(rows[i], rows[j])
            if r == .orderedSame { return rows[i].path.localizedStandardCompare(rows[j].path) == .orderedAscending }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
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
            case .none:
                break
            case .copyToRight, .copyToLeft:
                let goesRight = row.action == .copyToRight
                guard let src = goesRight ? row.left : row.right else { continue }
                let dest = (goesRight ? config.right : config.left).appendingPathComponent(row.path)
                let op = SyncOperation(kind: src.isDirectory ? .makeDirectory : .copy, row: row, source: src.url,
                                       destination: dest, bytes: src.isDirectory ? 0 : src.size,
                                       overwrites: (goesRight ? row.right : row.left) != nil)
                if goesRight { toRight.append(op) } else { toLeft.append(op) }
            case .deleteRight, .deleteLeft:
                guard let target = row.action == .deleteRight ? row.right : row.left else { continue }
                deletions.append(SyncOperation(kind: .delete, row: row, source: nil, destination: target.url,
                                               bytes: target.size, overwrites: false))
            }
        }
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
        var ops: [SyncOperation] = []
        if options.leftToRight { ops += plan.toRight }
        if options.rightToLeft { ops += plan.toLeft }
        if options.delete { ops += plan.deletions }
        var touched: [ObjectIdentifier: RemoteSession] = [:]
        defer { for s in touched.values { s.invalidate() } }
        let files = SyncFiles(sessions: sessions)

        for op in ops {
            if isCancelled() { report.cancelled = true; break }
            progress(op)
            guard files.unchanged(op.row.left) && files.unchanged(op.row.right) else {
                report.skipped.append("\(op.row.path): changed since the comparison")
                continue
            }
            for url in [op.source, op.destination].compactMap({ $0 }) {
                if let s = sessions(url) { touched[ObjectIdentifier(s)] = s }
            }
            do {
                switch op.kind {
                case .makeDirectory:
                    guard options.createEmptyDirectories else { report.skipped.append("\(op.row.path): empty folder"); continue }
                    try files.makeDirectory(op.destination)
                    report.created += 1
                case .copy:
                    guard let src = op.source else { continue }
                    let exists = files.exists(op.destination)
                    if !op.overwrites && exists {
                        report.skipped.append("\(op.row.path): appeared at the destination since the comparison")
                        continue
                    }
                    if exists && !options.overwrite { report.skipped.append("\(op.row.path): exists, not overwritten"); continue }
                    let info = op.row.action == .copyToRight ? op.row.left : op.row.right
                    try files.copy(src, to: op.destination, info: info, replacing: exists, isCancelled: isCancelled)
                    report.copied += 1
                case .delete:
                    if let session = sessions(op.destination) {
                        let path = RemoteSession.path(of: op.destination)
                        if op.row.isDirectory { try session.client.removeDirectory(path) } else { try session.client.deleteFile(path) }
                    } else {
                        try trash(op.destination)
                    }
                    report.deleted += 1
                }
            } catch FTPError.cancelled {
                report.cancelled = true
                break
            } catch let e as FTPError {
                report.errors.append("\(op.row.path): \(e.message)")
            } catch {
                report.errors.append("\(op.row.path): \(error.localizedDescription)")
            }
        }
        return report
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
        if let s = sessions(info.url) {
            guard let now = remoteEntry(info.url, session: s) else { return false }
            if info.isDirectory { return now.isDirectory }
            return now.size == info.size && (now.modified ?? .distantPast) == info.modified
        }
        guard let now = SearchItem.read(info.url) else { return false }
        if info.isDirectory { return now.isDirectory }
        return now.size == info.size && abs(now.modified.timeIntervalSince(info.modified)) < 0.001
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
        let fm = FileManager.default
        let cancel = CancelFlag()
        let watch = { if isCancelled() { cancel.cancel() } }
        switch (sessions(src), sessions(dst)) {
        case (nil, nil):
            if replacing { try fm.removeItem(at: dst) }
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)   // keeps the modification date
        case let (nil, to?):
            watch()
            try to.client.upload(src, to: RemoteSession.path(of: dst), resume: false, cancel: cancel, progress: { _ in watch() })
            if let date = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                try? to.client.setModificationDate(date, of: RemoteSession.path(of: dst))
            }
        case let (from?, nil):
            try from.client.download(RemoteSession.path(of: src), to: dst, expectedSize: info?.size, resume: false,
                                     cancel: cancel, progress: { _ in watch() })
            if !from.profile.isSFTP, let date = info?.modified, date != .distantPast {
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: dst.path)
            }
        case let (from?, to?):
            let temp = fm.temporaryDirectory.appendingPathComponent("cc-sync-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temp) }
            try from.client.download(RemoteSession.path(of: src), to: temp, expectedSize: info?.size, resume: false,
                                     cancel: cancel, progress: { _ in watch() })
            try to.client.upload(temp, to: RemoteSession.path(of: dst), resume: false, cancel: cancel, progress: { _ in watch() })
            if let date = info?.modified, date != .distantPast { try? to.client.setModificationDate(date, of: RemoteSession.path(of: dst)) }
        }
    }
}
