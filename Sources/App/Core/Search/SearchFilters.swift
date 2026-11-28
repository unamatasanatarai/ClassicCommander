import Foundation

/// One file or folder seen by the search: everything the filters need, read with a single lstat.
public struct SearchItem: Equatable {
    /// The path as the user sees it (under the starting folder they typed, even if that is a link).
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date
    public let mode: UInt16
    public let flags: UInt32
    public let ownerID: UInt32

    public init(url: URL, name: String, isDirectory: Bool, size: Int64, modified: Date,
                mode: UInt16 = 0o644, flags: UInt32 = 0, ownerID: UInt32 = 501) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.mode = mode
        self.flags = flags
        self.ownerID = ownerID
    }

    /// Reads an item from disk without following a final symlink. nil if it vanished.
    /// Reads `statPath`, then names it `relative` under `root` — the URL is built knowing whether it is a
    /// folder, which saves a second stat per entry (URL.appendingPathComponent(_:) stats to decide).
    public static func read(relative: String, under root: URL, statPath: String) -> SearchItem? {
        var st = stat()
        guard lstat(statPath, &st) == 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        return read(root.appendingPathComponent(relative, isDirectory: isDir), stat: st)
    }

    static func read(_ url: URL, stat st: stat) -> SearchItem {
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return SearchItem(url: url, name: url.lastPathComponent, isDirectory: isDir,
                          size: isDir ? 0 : Int64(st.st_size), modified: mtime,
                          mode: UInt16(st.st_mode), flags: st.st_flags, ownerID: st.st_uid)
    }

    public static func read(_ url: URL, statPath: String? = nil) -> SearchItem? {
        var st = stat()
        guard lstat(statPath ?? url.path, &st) == 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return SearchItem(url: url, name: url.lastPathComponent, isDirectory: isDir,
                          size: isDir ? 0 : Int64(st.st_size), modified: mtime,
                          mode: UInt16(st.st_mode), flags: st.st_flags, ownerID: st.st_uid)
    }

    public func has(_ attribute: FileAttribute) -> Bool {
        switch attribute {
        case .archive: return flags & UInt32(SF_ARCHIVED) != 0
        case .hidden: return name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0
        case .system:
            return ownerID == 0 || flags & UInt32(SF_RESTRICTED | SF_IMMUTABLE | SF_NOUNLINK) != 0
        case .readOnly: return mode & UInt16(S_IWUSR) == 0 || flags & UInt32(UF_IMMUTABLE) != 0
        case .directory: return isDirectory
        case .compressed: return flags & UInt32(UF_COMPRESSED) != 0
        case .encrypted: return false
        }
    }
}

/// A named, composable test on a search item. The search ANDs every active predicate.
public struct SearchPredicate {
    public let name: String
    public let test: (SearchItem) -> Bool

    public init(_ name: String, _ test: @escaping (SearchItem) -> Bool) {
        self.name = name
        self.test = test
    }

    public static func all(_ predicates: [SearchPredicate]) -> SearchPredicate {
        SearchPredicate(predicates.map(\.name).joined(separator: " AND ")) { item in
            predicates.allSatisfy { $0.test(item) }
        }
    }
}

/// Filename matching for Find Files. Wildcard mode (Total Commander rules):
///   "*.txt;*.doc"   several masks;  "report"  no wildcard means "name contains report";
///   "*.log | old*"  masks after "|" exclude.  Case-insensitive, Unicode-normalised.
/// Regex mode uses the whole text as one case-insensitive regular expression.
public struct NameMatcher {
    private let include: [NSRegularExpression]
    private let exclude: [NSRegularExpression]
    /// "*" / "*.*" with nothing excluded: every name matches, no regular expression needed.
    private var matchesEverything = false

    public init(pattern: String, regex: Bool) throws {
        if regex {
            do {
                include = [try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])]
            } catch {
                let looksLikeMask = pattern.hasPrefix("*") || pattern.contains("*.")
                throw SearchValidationError(message: looksLikeMask
                    ? "“\(pattern)” is a wildcard mask, but RegEx is ticked. Untick RegEx to search with wildcards."
                    : "“Search for” is not a valid regular expression.")
            }
            exclude = []
            return
        }
        let halves = pattern.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let inc = Self.compileMasks(halves[0])
        include = inc.isEmpty ? Self.compileMasks("*") : inc
        exclude = halves.count > 1 ? Self.compileMasks(halves[1]) : []
        let includeTexts = halves[0].split(whereSeparator: { $0 == ";" || $0 == " " }).map(String.init)
        matchesEverything = exclude.isEmpty && (includeTexts.isEmpty || includeTexts.contains { $0 == "*" || $0 == "*.*" })
    }

    private static func compileMasks(_ text: String) -> [NSRegularExpression] {
        text.split(whereSeparator: { $0 == ";" || $0 == " " }).map(String.init).filter { !$0.isEmpty }.map { raw in
            var mask = normalize(raw)
            if mask == "*.*" { mask = "*" }
            if !mask.contains("*") && !mask.contains("?") { mask = "*\(mask)*" }
            var expr = "^"
            for ch in mask {
                switch ch {
                case "*": expr += ".*"
                case "?": expr += "."
                default: expr += NSRegularExpression.escapedPattern(for: String(ch))
                }
            }
            return try! NSRegularExpression(pattern: expr + "$", options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }

    /// File names come from disk in either Unicode form (e.g. "ó" as one or two code points).
    static func normalize(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    public func matches(_ name: String) -> Bool {
        if matchesEverything { return true }
        let n = Self.normalize(name)
        let range = NSRange(n.startIndex..., in: n)
        func hit(_ r: NSRegularExpression) -> Bool { r.firstMatch(in: n, range: range) != nil }
        return include.contains(where: hit) && !exclude.contains(where: hit)
    }
}

/// Turns the dialog settings into predicates, after checking them.
public enum SearchQueryBuilder {
    public static func predicates(for config: FileSearchConfiguration, now: Date = Date(),
                                  calendar: Calendar = .current) throws -> [SearchPredicate] {
        var result: [SearchPredicate] = []
        let general = config.general
        let advanced = config.advanced

        let names = try NameMatcher(pattern: general.filenamePattern, regex: general.useRegex)
        result.append(SearchPredicate("name") { names.matches($0.name) })
        result += try datePredicates(for: advanced, now: now, calendar: calendar)
        if advanced.fileSize.enabled {
            let filter = advanced.fileSize
            guard filter.value >= 0, filter.value.isFinite else {
                throw SearchValidationError(message: "“File size” must be a number of 0 or more.")
            }
            let bytes = filter.bytes
            // Folders have no size of their own, so a size filter finds files only.
            result.append(SearchPredicate("size \(filter.comparison.rawValue) \(bytes)") {
                !$0.isDirectory && filter.comparison.compare($0.size, bytes)
            })
        }
        result += attributePredicates(for: advanced)
        if advanced.duplicates.enabled {
            let d = advanced.duplicates
            guard d.sameName || d.sameSize || d.sameContents else {
                throw SearchValidationError(message: "For duplicates, tick at least one of same name, size or contents.")
            }
            // Duplicates are files, never folders.
            result.append(SearchPredicate("files only (duplicates)") { !$0.isDirectory })
        }
        if general.content.enabled {
            // Text is searched in files only.
            result.append(SearchPredicate("files only (content)") { !$0.isDirectory })
        }
        return result
    }

    private static func datePredicates(for advanced: AdvancedSearchConfiguration, now: Date, calendar: Calendar) throws -> [SearchPredicate] {
        var result: [SearchPredicate] = []
        if advanced.dateBetweenEnabled {
            guard let from = advanced.dateFrom, let to = advanced.dateTo else {
                throw SearchValidationError(message: "Enter both dates for “Date between”.")
            }
            let start = calendar.startOfDay(for: from)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!
            guard start < end else {
                throw SearchValidationError(message: "“Date between”: the first date is after the second.")
            }
            // Inclusive of both whole days.
            result.append(SearchPredicate("date between") { $0.modified >= start && $0.modified < end })
        }
        if advanced.notOlderThan.enabled {
            let limit = try ageLimit(advanced.notOlderThan, "Not older than", now: now, calendar: calendar)
            result.append(SearchPredicate("not older than") { $0.modified >= limit })
        }
        if advanced.olderThan.enabled {
            let limit = try ageLimit(advanced.olderThan, "Older than", now: now, calendar: calendar)
            result.append(SearchPredicate("older than") { $0.modified < limit })
        }
        return result
    }

    private static func attributePredicates(for advanced: AdvancedSearchConfiguration) -> [SearchPredicate] {
        guard advanced.attributesEnabled else { return [] }
        var result: [SearchPredicate] = []
        for attribute in FileAttribute.allCases where attribute.isAvailable {
            switch advanced.state(of: attribute) {
            case .ignored: continue
            case .required: result.append(SearchPredicate("+\(attribute.rawValue)") { $0.has(attribute) })
            case .excluded: result.append(SearchPredicate("-\(attribute.rawValue)") { !$0.has(attribute) })
            }
        }
        return result
    }

    private static func ageLimit(_ age: AgeFilter, _ label: String, now: Date, calendar: Calendar) throws -> Date {
        guard age.value >= 0 else { throw SearchValidationError(message: "“\(label)” must be 0 or more.") }
        return calendar.date(byAdding: age.unit.component, value: -age.value, to: now) ?? now
    }
}
