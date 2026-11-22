import Foundation

/// Text for the panel columns, drive bar and status line, in Total Commander's format.
/// Numbers follow the locale (e.g. "15.965" and "88,4 k" in German, "15,965" and "88.4 k" in English).
public struct EntryFormatter {
    public static let shared = EntryFormatter(locale: .current)

    private let sizeFormatter: NumberFormatter
    private let compactFormatter: NumberFormatter
    private let dateFormatter: DateFormatter
    private let shortDateFormatter: DateFormatter

    public init(locale: Locale, timeZone: TimeZone = .current) {
        sizeFormatter = NumberFormatter()
        sizeFormatter.locale = locale
        sizeFormatter.numberStyle = .decimal
        sizeFormatter.usesGroupingSeparator = true
        sizeFormatter.maximumFractionDigits = 0

        compactFormatter = NumberFormatter()
        compactFormatter.locale = locale
        compactFormatter.numberStyle = .decimal
        compactFormatter.minimumFractionDigits = 1
        compactFormatter.maximumFractionDigits = 1

        dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "dd.MM.yy HH:mm"

        shortDateFormatter = DateFormatter()
        shortDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        shortDateFormatter.timeZone = timeZone
        shortDateFormatter.dateFormat = "dd.MM.yy"
    }

    /// Files show the name without extension (it has its own column); folders show the full name,
    /// optionally in square brackets ("[media]", "[..]").
    public func name(_ entry: FileEntry, folderBrackets: Bool = false) -> String {
        if entry.kind == .file { return entry.baseName }
        return folderBrackets ? "[\(entry.name)]" : entry.name
    }

    /// Bytes for files; "<DIR>" for folders unless their total size has been calculated.
    public func size(_ entry: FileEntry, folderSize: Int64? = nil) -> String {
        switch entry.kind {
        case .parent: return "<DIR>"
        case .directory: return folderSize.map(grouped) ?? "<DIR>"
        case .file: return entry.size.map(grouped) ?? ""
        }
    }

    /// "17.04.08 19:48", or "17.04.08" when the column is too narrow for the time.
    public func date(_ entry: FileEntry, includeTime: Bool = true) -> String {
        entry.modified.map { (includeTime ? dateFormatter : shortDateFormatter).string(from: $0) } ?? ""
    }

    /// Unix permissions in octal, the way Total Commander shows them for Unix file systems ("-644").
    /// The ".." row shows "----".
    public func attributes(_ entry: FileEntry) -> String {
        guard entry.kind != .parent, let p = entry.permissions else { return "----" }
        return "-" + String(p & 0o777, radix: 8)
    }

    public func grouped(_ value: Int64) -> String {
        sizeFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "0 b", "812 b", "88,4 k", "1,2 M", "76,5 G".
    public func compact(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) b" }
        let units = ["k", "M", "G", "T"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let number = compactFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
        return "\(number) \(units[unit])"
    }

    /// Status line, e.g. "15,6 k / 88,4 k in 1 / 11 files, 0 / 2 dir(s)": selected / total.
    public func summary<C: Collection>(_ entries: C,
                                       selected: (files: Int, dirs: Int, bytes: Int64) = (0, 0, 0)) -> String
        where C.Element == FileEntry {
        var files = 0, dirs = 0
        var bytes: Int64 = 0
        for e in entries {
            switch e.kind {
            case .file: files += 1; bytes += e.size ?? 0
            case .directory: dirs += 1
            case .parent: break
            }
        }
        var text = "\(compact(selected.bytes)) / \(compact(bytes)) in \(selected.files) / \(files) files"
        if dirs > 0 { text += ", \(selected.dirs) / \(dirs) dir(s)" }
        return text
    }

    /// Drive bar, e.g. "[Macintosh HD]  76,5 G of 117,1 G free".
    public func volume(_ info: VolumeInfo) -> String {
        "[\(info.name)]  \(compact(info.available)) of \(compact(info.total)) free"
    }

    /// The path bar, e.g. "/Users/me/*.*".
    public static func header(for directory: URL) -> String {
        let path = directory.path
        return (path.hasSuffix("/") ? path : path + "/") + "*.*"
    }
}

/// Name and capacity of the volume a directory lives on.
public struct VolumeInfo: Equatable {
    public let name: String
    public let available: Int64
    public let total: Int64

    public init(name: String, available: Int64, total: Int64) {
        self.name = name
        self.available = available
        self.total = total
    }

    public static func read(for directory: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
        ]
        guard let v = try? directory.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else {
            return nil
        }
        let available = v.volumeAvailableCapacityForImportantUsage ?? v.volumeAvailableCapacity.map(Int64.init) ?? 0
        return VolumeInfo(name: v.volumeLocalizedName ?? "", available: available, total: Int64(total))
    }
}
