import Foundation

/// Select → Compare Directories: marks, in both panels, what differs between the two folders
/// (names, then sizes or dates; subfolders aren't looked into).
public enum PanelComparison {
    public enum Criterion: Equatable {
        /// Marks the newer of two files with the same name (both when only the size differs).
        case date
        /// Marks both files when their sizes differ.
        case size
    }

    public struct Result: Equatable {
        public var left: Set<String>
        public var right: Set<String>
        public var isIdentical: Bool { left.isEmpty && right.isEmpty }
    }

    /// Entries only on one side are marked on that side. Folders are compared by name only.
    /// `tolerance`: dates closer than this count as equal (servers often list whole minutes).
    public static func compare(left: [FileEntry], right: [FileEntry], by criterion: Criterion,
                               tolerance: TimeInterval = 2) -> Result {
        var l: [String: FileEntry] = [:], r: [String: FileEntry] = [:]
        for e in left where e.kind != .parent { l[e.name] = e }
        for e in right where e.kind != .parent { r[e.name] = e }
        var result = Result(left: Set(l.keys).subtracting(r.keys), right: Set(r.keys).subtracting(l.keys))
        for (name, a) in l {
            guard let b = r[name] else { continue }
            comparePair(name: name, a: a, b: b, criterion: criterion, tolerance: tolerance, into: &result)
        }
        return result
    }

    private static func comparePair(
        name: String,
        a: FileEntry,
        b: FileEntry,
        criterion: Criterion,
        tolerance: TimeInterval,
        into result: inout Result
    ) {
        if a.kind != b.kind {
            // A file on one side, a folder on the other.
            insertBoth(name, into: &result)
            return
        }
        guard a.kind == .file else { return }
        if criterion == .date {
            compareByDate(name: name, a: a, b: b, tolerance: tolerance, sizeDiffers: sizesDiffer(a, b), into: &result)
        } else if sizesDiffer(a, b) {
            insertBoth(name, into: &result)
        }
    }

    private static func sizesDiffer(_ a: FileEntry, _ b: FileEntry) -> Bool {
        (a.size ?? 0) != (b.size ?? 0)
    }

    private static func insertBoth(_ name: String, into result: inout Result) {
        result.left.insert(name)
        result.right.insert(name)
    }

    private static func compareByDate(
        name: String, a: FileEntry, b: FileEntry, tolerance: TimeInterval, sizeDiffers: Bool, into result: inout Result
    ) {
        let gap = (a.modified ?? .distantPast).timeIntervalSince(b.modified ?? .distantPast)
        if gap > tolerance {
            result.left.insert(name)
        } else if gap < -tolerance {
            result.right.insert(name)
        } else if sizeDiffers {
            result.left.insert(name)
            result.right.insert(name)
        }
    }
}

/// Select → Copy … to Clipboard: names, full paths, or either as a table with the details.
public enum SelectionClipboard {
    public enum Format: Equatable {
        case names, paths, namesWithDetails, pathsWithDetails
    }

    /// One line per entry; the detail formats are tab-separated (they paste as a table into
    /// spreadsheets) with a header line. `path` gives an entry's full path (a server address for
    /// remote panels); `folderSize` a calculated folder size, if any.
    public static func text(_ entries: [FileEntry], format: Format, path: (FileEntry) -> String,
                            folderSize: (FileEntry) -> Int64? = { _ in nil }) -> String {
        let usePaths = format == .paths || format == .pathsWithDetails
        let detailed = format == .namesWithDetails || format == .pathsWithDetails
        var lines: [String] = detailed ? [headerLine(usePaths: usePaths)] : []
        for e in entries {
            lines.append(rowLine(e, usePaths: usePaths, detailed: detailed, path: path, folderSize: folderSize))
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func headerLine(usePaths: Bool) -> String {
        [usePaths ? "Path" : "Name", "Size", "Date", "Attributes"].joined(separator: "\t")
    }

    private static func rowLine(
        _ entry: FileEntry,
        usePaths: Bool,
        detailed: Bool,
        path: (FileEntry) -> String,
        folderSize: (FileEntry) -> Int64?
    ) -> String {
        let name = usePaths ? path(entry) : entry.name
        return detailed ? formatDetailedRow(entry, name: name, folderSize: folderSize) : name
    }

    private static func formatDetailedRow(_ e: FileEntry, name: String, folderSize: (FileEntry) -> Int64?) -> String {
        let size = formattedSize(for: e, folderSize: folderSize)
        let date = e.modified.map(dateFormatter.string(from:)) ?? ""
        let attributes = formattedAttributes(for: e)
        return [name, size, date, attributes].joined(separator: "\t")
    }

    private static func formattedSize(for entry: FileEntry, folderSize: (FileEntry) -> Int64?) -> String {
        if entry.kind == .directory { return folderSize(entry).map(String.init) ?? "<DIR>" }
        return entry.size.map(String.init) ?? ""
    }

    private static func formattedAttributes(for entry: FileEntry) -> String {
        entry.permissions.map { (entry.kind == .directory ? "d" : "-") + String($0, radix: 8) } ?? ""
    }

    /// Year first, so spreadsheets read it as a date and it sorts as text.
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
