import Foundation

public protocol DirectoryListing {
    /// Returns the directory's entries, unsorted and without the ".." link.
    func entries(in directory: URL) throws -> [FileEntry]
}

/// Reads real directories from disk. Dotfiles are hidden, as Finder and the classic commanders do.
public struct FileSystemLister: DirectoryListing {
    public var showHidden: Bool

    public init(showHidden: Bool = false) {
        self.showHidden = showHidden
    }

    public func entries(in directory: URL) throws -> [FileEntry] {
        // Not `.skipsHiddenFiles`: that also hides flagged system folders like /usr and /bin,
        // which a file commander must show. Only dotfiles are hidden.
        // A path ending in a symlink to a folder (e.g. ~/bin -> …/configs/bin) is listed through
        // its real path: listing such a link fails with "Not a directory".
        // Entries keep the panel's own path, so ".." leads back where the user came from.
        //
        // One lstat per entry gives type, size, date and permissions (stat only for symlinks); URLs
        // are built with an explicit isDirectory, which avoids another stat per name.
        let real = Self.realPath(of: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: real.path)
        let base = real.path.hasSuffix("/") ? real.path : real.path + "/"
        var result: [FileEntry] = []
        result.reserveCapacity(names.count)
        var st = stat()
        for name in names {
            if !showHidden && name.hasPrefix(".") { continue }
            let full = base + name
            guard lstat(full, &st) == 0 else { continue }
            let isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
            var isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
            if isSymlink {
                // A link to a directory (e.g. /tmp, /etc) must be enterable like one: stat() follows the link.
                var target = stat()
                isDirectory = stat(full, &target) == 0 && (target.st_mode & S_IFMT) == S_IFDIR
            }
            let mtime = st.st_mtimespec
            result.append(FileEntry(
                name: name,
                url: directory.appendingPathComponent(name, isDirectory: isDirectory),
                kind: isDirectory ? .directory : .file,
                size: isDirectory ? nil : Int64(st.st_size),
                modified: Date(timeIntervalSince1970: TimeInterval(mtime.tv_sec) + TimeInterval(mtime.tv_nsec) / 1e9),
                isSymlink: isSymlink,
                permissions: Int(st.st_mode & 0o777)
            ))
        }
        return result
    }
}

extension FileSystemLister {
    /// The directory with every symlink resolved (realpath(3)); the input when that fails.
    static func realPath(of url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}

public enum SortColumn: Equatable, CaseIterable {
    case name, ext, size, date
    /// The order the file system lists them in (folders still first), Total Commander's "Unsorted".
    case unsorted
}

public struct SortOrder: Equatable {
    public var column: SortColumn
    public var ascending: Bool

    public init(column: SortColumn = .name, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

public enum EntrySorting {
    /// ".." first, then directories, then files. Within each group entries follow the sort column
    /// (directories have no size or extension, so those sorts fall back to name), and a descending
    /// sort reverses each group, as Total Commander does.
    public static func sorted(_ entries: [FileEntry], by order: SortOrder = SortOrder()) -> [FileEntry] {
        if order.column == .unsorted {
            // Keep the listing order within each group; "reverse" reverses it.
            let indexed = entries.enumerated().sorted { x, y in
                let rx = rank(x.element.kind), ry = rank(y.element.kind)
                if rx != ry { return rx < ry }
                return order.ascending ? x.offset < y.offset : x.offset > y.offset
            }
            return indexed.map(\.element)
        }
        // Sort indices over precomputed keys: names bridged to NSString once (not on every comparison),
        // extensions computed once, and the entries themselves moved only once at the end.
        let names = entries.map { $0.name as NSString }
        let exts: [NSString] = order.column == .ext ? entries.map { $0.displayExtension as NSString } : []
        let ranks = entries.map { rank($0.kind) }
        let isFile = entries.map { $0.kind == .file }
        let sizes: [Int64] = order.column == .size ? entries.map { $0.size ?? 0 } : []
        let dates: [Date] = order.column == .date ? entries.map { $0.modified ?? .distantPast } : []
        func byName(_ i: Int, _ j: Int) -> ComparisonResult { names[i].localizedStandardCompare(names[j] as String) }
        let sortedIndices = entries.indices.sorted { i, j in
            if ranks[i] != ranks[j] { return ranks[i] < ranks[j] }
            let column = isFile[i] ? order.column : .name
            var result: ComparisonResult
            switch column {
            case .name, .unsorted: result = byName(i, j)
            case .ext: result = exts[i].localizedStandardCompare(exts[j] as String)
            case .size: result = compareValues(sizes[i], sizes[j])
            case .date: result = compareValues(dates[i], dates[j])
            }
            // The (costly) localized name comparison only breaks ties.
            if result == .orderedSame && column != .name && column != .unsorted { result = byName(i, j) }
            return order.ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return sortedIndices.map { entries[$0] }
    }

    private static func compareValues<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    private static func rank(_ kind: FileEntry.Kind) -> Int {
        switch kind {
        case .parent: return 0
        case .directory: return 1
        case .file: return 2
        }
    }
}
