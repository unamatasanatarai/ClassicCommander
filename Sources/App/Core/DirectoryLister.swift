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

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]

    public func entries(in directory: URL) throws -> [FileEntry] {
        let fm = FileManager.default
        // Not `.skipsHiddenFiles`: that also hides flagged system folders like /usr and /bin,
        // which a file commander must show. Only dotfiles are hidden.
        // A path ending in a symlink to a folder (e.g. ~/bin -> …/configs/bin) is listed through
        // its real path: contentsOfDirectory(at:) refuses such a link with "Not a directory".
        // Entries keep the panel's own path, so ".." leads back where the user came from.
        let real = Self.realPath(of: directory)
        let urls = try fm.contentsOfDirectory(at: real, includingPropertiesForKeys: Self.keys)
        return urls.compactMap { realURL -> FileEntry? in
            let name = realURL.lastPathComponent
            let url = directory.appendingPathComponent(name)
            if !showHidden && name.hasPrefix(".") { return nil }
            let values = try? realURL.resourceValues(forKeys: Set(Self.keys))
            let isSymlink = values?.isSymbolicLink ?? false
            var isDirectory = values?.isDirectory ?? false
            if isSymlink {
                // A link to a directory (e.g. /tmp, /etc) must be enterable like one. stat() follows
                // the link; URL.resolvingSymlinksInPath() would strip "/private" and land on the link again.
                var target = stat()
                isDirectory = stat(realURL.path, &target) == 0 && (target.st_mode & S_IFMT) == S_IFDIR
            }
            var st = stat()
            let perms: Int? = lstat(realURL.path, &st) == 0 ? Int(st.st_mode & 0o777) : nil
            return FileEntry(
                name: name,
                url: url,
                kind: isDirectory ? .directory : .file,
                size: isDirectory ? nil : values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate,
                isSymlink: isSymlink,
                permissions: perms
            )
        }
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
        entries.sorted { a, b in
            let ra = rank(a.kind), rb = rank(b.kind)
            if ra != rb { return ra < rb }
            let result = compare(a, b, column: a.kind == .file ? order.column : .name)
            return order.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compare(_ a: FileEntry, _ b: FileEntry, column: SortColumn) -> ComparisonResult {
        let byName = a.name.localizedStandardCompare(b.name)
        let primary: ComparisonResult
        switch column {
        case .name:
            return byName
        case .ext:
            primary = a.displayExtension.localizedStandardCompare(b.displayExtension)
        case .size:
            primary = compareValues(a.size ?? 0, b.size ?? 0)
        case .date:
            primary = compareValues(a.modified ?? .distantPast, b.modified ?? .distantPast)
        }
        return primary == .orderedSame ? byName : primary
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
