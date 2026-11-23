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
            if a.kind != b.kind {
                // A file on one side, a folder on the other.
                result.left.insert(name)
                result.right.insert(name)
                continue
            }
            guard a.kind == .file else { continue }
            let sizeDiffers = (a.size ?? 0) != (b.size ?? 0)
            switch criterion {
            case .size:
                if sizeDiffers {
                    result.left.insert(name)
                    result.right.insert(name)
                }
            case .date:
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
        return result
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
        var lines: [String] = []
        if detailed { lines.append([usePaths ? "Path" : "Name", "Size", "Date", "Attributes"].joined(separator: "\t")) }
        for e in entries {
            let name = usePaths ? path(e) : e.name
            guard detailed else { lines.append(name); continue }
            let size: String
            if e.kind == .directory {
                size = folderSize(e).map(String.init) ?? "<DIR>"
            } else {
                size = e.size.map(String.init) ?? ""
            }
            let date = e.modified.map(dateFormatter.string(from:)) ?? ""
            let attributes = e.permissions.map { (e.kind == .directory ? "d" : "-") + String($0, radix: 8) } ?? ""
            lines.append([name, size, date, attributes].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// Year first, so spreadsheets read it as a date and it sorts as text.
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
