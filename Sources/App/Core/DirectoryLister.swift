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
        if ZipArchive.split(directory) != nil {
            return try ZipArchive.entries(in: directory)
        }
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
        for name in names where showHidden || !name.hasPrefix(".") {
            if let entry = Self.makeEntry(name: name, fullPath: base + name, directory: directory) {
                result.append(entry)
            }
        }
        return result
    }

    private static func makeEntry(name: String, fullPath: String, directory: URL) -> FileEntry? {
        var st = stat()
        guard lstat(fullPath, &st) == 0 else { return nil }
        let isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
        let isDirectory = resolvesToDirectory(fullPath: fullPath, stat: st, isSymlink: isSymlink)
        let mtime = st.st_mtimespec
        return FileEntry(
            name: name,
            url: directory.appendingPathComponent(name, isDirectory: isDirectory),
            kind: isDirectory ? .directory : .file,
            size: isDirectory ? nil : Int64(st.st_size),
            modified: Date(timeIntervalSince1970: TimeInterval(mtime.tv_sec) + TimeInterval(mtime.tv_nsec) / 1e9),
            isSymlink: isSymlink,
            permissions: Int(st.st_mode & 0o777)
        )
    }

    private static func resolvesToDirectory(fullPath: String, stat st: stat, isSymlink: Bool) -> Bool {
        guard isSymlink else { return (st.st_mode & S_IFMT) == S_IFDIR }
        // A link to a directory (e.g. /tmp, /etc) must be enterable like one: stat() follows the link.
        var target = stat()
        return stat(fullPath, &target) == 0 && (target.st_mode & S_IFMT) == S_IFDIR
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
            return sortedUnsorted(entries, ascending: order.ascending)
        }
        let keys = SortKeys(entries: entries, column: order.column)
        let sortedIndices = entries.indices.sorted { compareEntries($0, $1, keys: keys, order: order) }
        return sortedIndices.map { entries[$0] }
    }

    private struct SortKeys {
        let names: [NSString]
        let exts: [NSString]
        let ranks: [Int]
        let isFile: [Bool]
        let sizes: [Int64]
        let dates: [Date]

        init(entries: [FileEntry], column: SortColumn) {
            names = entries.map { $0.name as NSString }
            exts = column == .ext ? entries.map { $0.displayExtension as NSString } : []
            ranks = entries.map { EntrySorting.rank($0.kind) }
            isFile = entries.map { $0.kind == .file }
            sizes = column == .size ? entries.map { $0.size ?? 0 } : []
            dates = column == .date ? entries.map { $0.modified ?? .distantPast } : []
        }
    }

    private static func compareEntries(_ i: Int, _ j: Int, keys: SortKeys, order: SortOrder) -> Bool {
        if keys.ranks[i] != keys.ranks[j] { return keys.ranks[i] < keys.ranks[j] }
        let column = keys.isFile[i] ? order.column : .name
        var result = compareColumn(column, i: i, j: j, exts: keys.exts, sizes: keys.sizes, dates: keys.dates, names: keys.names)
        // The (costly) localized name comparison only breaks ties.
        if result == .orderedSame && column != .name {
            result = keys.names[i].localizedStandardCompare(keys.names[j] as String)
        }
        return order.ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private static func compareColumn(
        _ column: SortColumn, i: Int, j: Int,
        exts: [NSString], sizes: [Int64], dates: [Date], names: [NSString]
    ) -> ComparisonResult {
        switch column {
        case .name, .unsorted: return names[i].localizedStandardCompare(names[j] as String)
        case .ext: return exts[i].localizedStandardCompare(exts[j] as String)
        case .size: return compareValues(sizes[i], sizes[j])
        case .date: return compareValues(dates[i], dates[j])
        }
    }

    private static func sortedUnsorted(_ entries: [FileEntry], ascending: Bool) -> [FileEntry] {
        let indexed = entries.enumerated().sorted { x, y in
            let rx = rank(x.element.kind), ry = rank(y.element.kind)
            if rx != ry { return rx < ry }
            return ascending ? x.offset < y.offset : x.offset > y.offset
        }
        return indexed.map(\.element)
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
