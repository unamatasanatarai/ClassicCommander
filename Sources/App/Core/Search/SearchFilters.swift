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

    private static let attributeChecks: [FileAttribute: (SearchItem) -> Bool] = [
        .archive: { $0.flags & UInt32(SF_ARCHIVED) != 0 },
        .hidden: { $0.name.hasPrefix(".") || $0.flags & UInt32(UF_HIDDEN) != 0 },
        .system: { $0.ownerID == 0 || $0.flags & UInt32(SF_RESTRICTED | SF_IMMUTABLE | SF_NOUNLINK) != 0 },
        .readOnly: { $0.mode & UInt16(S_IWUSR) == 0 || $0.flags & UInt32(UF_IMMUTABLE) != 0 },
        .directory: { $0.isDirectory },
        .compressed: { $0.flags & UInt32(UF_COMPRESSED) != 0 },
        .encrypted: { _ in false },
    ]

    public func has(_ attribute: FileAttribute) -> Bool {
        Self.attributeChecks[attribute]?(self) ?? false
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
            include = [try Self.compileRegex(pattern)]
            exclude = []
            return
        }
        (include, exclude, matchesEverything) = Self.parseWildcardMasks(pattern)
    }

    private static func parseWildcardMasks(_ pattern: String) -> ([NSRegularExpression], [NSRegularExpression], Bool) {
        let halves = pattern.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let inc = compileMasks(halves[0])
        let include = inc.isEmpty ? compileMasks("*") : inc
        let exclude = halves.count > 1 ? compileMasks(halves[1]) : []
        return (include, exclude, matchesAllFiles(includeText: halves[0], exclude: exclude))
    }

    private static func matchesAllFiles(includeText: String, exclude: [NSRegularExpression]) -> Bool {
        guard exclude.isEmpty else { return false }
        let includeTexts = includeText.split(whereSeparator: { $0 == ";" || $0 == " " }).map(String.init)
        return includeTexts.isEmpty || includeTexts.contains { $0 == "*" || $0 == "*.*" }
    }

    private static func compileRegex(_ pattern: String) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            let looksLikeMask = pattern.hasPrefix("*") || pattern.contains("*.")
            throw SearchValidationError(message: looksLikeMask
                ? "“\(pattern)” is a wildcard mask, but RegEx is ticked. Untick RegEx to search with wildcards."
                : "“Search for” is not a valid regular expression.")
        }
    }

    private static func compileMasks(_ text: String) -> [NSRegularExpression] {
        text.split(whereSeparator: { $0 == ";" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
            .map(compileSingleMask)
    }

    private static func compileSingleMask(_ raw: String) -> NSRegularExpression {
        var mask = normalize(raw)
        if mask == "*.*" { mask = "*" }
        if !mask.contains("*") && !mask.contains("?") { mask = "*\(mask)*" }
        let expr = "^" + wildcardBody(for: mask) + "$"
        return try! NSRegularExpression(pattern: expr, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func wildcardBody(for mask: String) -> String {
        mask.map { ch in
            switch ch {
            case "*": return ".*"
            case "?": return "."
            default: return NSRegularExpression.escapedPattern(for: String(ch))
            }
        }.joined()
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
        let names = try NameMatcher(pattern: config.general.filenamePattern, regex: config.general.useRegex)
        var result = [SearchPredicate("name") { names.matches($0.name) }]
        result += try datePredicates(for: config.advanced, now: now, calendar: calendar)
        result += try optionalPredicates(for: config)
        return result
    }

    private static func optionalPredicates(for config: FileSearchConfiguration) throws -> [SearchPredicate] {
        var result = attributePredicates(for: config.advanced)
        result += try [sizePredicate(for: config.advanced.fileSize),
                       duplicatePredicate(for: config.advanced.duplicates)].compactMap { $0 }
        result += contentPredicates(for: config.general.content)
        return result
    }

    private static func contentPredicates(for content: ContentSearchConfiguration) -> [SearchPredicate] {
        // Text is searched in files only.
        content.enabled ? [SearchPredicate("files only (content)") { !$0.isDirectory }] : []
    }

    private static func sizePredicate(for filter: SizeFilter) throws -> SearchPredicate? {
        guard filter.enabled else { return nil }
        guard filter.value >= 0, filter.value.isFinite else {
            throw SearchValidationError(message: "“File size” must be a number of 0 or more.")
        }
        let bytes = filter.bytes
        // Folders have no size of their own, so a size filter finds files only.
        return SearchPredicate("size \(filter.comparison.rawValue) \(bytes)") {
            !$0.isDirectory && filter.comparison.compare($0.size, bytes)
        }
    }

    private static func duplicatePredicate(for d: DuplicateSearchConfiguration) throws -> SearchPredicate? {
        guard d.enabled else { return nil }
        guard d.sameName || d.sameSize || d.sameContents else {
            throw SearchValidationError(message: "For duplicates, tick at least one of same name, size or contents.")
        }
        // Duplicates are files, never folders.
        return SearchPredicate("files only (duplicates)") { !$0.isDirectory }
    }

    private static func datePredicates(for advanced: AdvancedSearchConfiguration, now: Date, calendar: Calendar) throws -> [SearchPredicate] {
        var result: [SearchPredicate] = []
        if let between = try dateBetweenPredicate(for: advanced, calendar: calendar) {
            result.append(between)
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

    private static func dateBetweenPredicate(for advanced: AdvancedSearchConfiguration, calendar: Calendar) throws -> SearchPredicate? {
        guard advanced.dateBetweenEnabled else { return nil }
        let range = try dayRange(from: advanced.dateFrom, to: advanced.dateTo, calendar: calendar)
        // Inclusive of both whole days.
        return SearchPredicate("date between") { range.contains($0.modified) }
    }

    private static func dayRange(from: Date?, to: Date?, calendar: Calendar) throws -> Range<Date> {
        guard let from = from, let to = to else {
            throw SearchValidationError(message: "Enter both dates for “Date between”.")
        }
        let start = calendar.startOfDay(for: from)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!
        guard start < end else {
            throw SearchValidationError(message: "“Date between”: the first date is after the second.")
        }
        return start..<end
    }

    private static func attributePredicates(for advanced: AdvancedSearchConfiguration) -> [SearchPredicate] {
        guard advanced.attributesEnabled else { return [] }
        return FileAttribute.allCases.filter(\.isAvailable).compactMap { attributePredicate(for: advanced, attribute: $0) }
    }

    private static func attributePredicate(for advanced: AdvancedSearchConfiguration, attribute: FileAttribute) -> SearchPredicate? {
        switch advanced.state(of: attribute) {
        case .ignored: return nil
        case .required: return SearchPredicate("+\(attribute.rawValue)") { $0.has(attribute) }
        case .excluded: return SearchPredicate("-\(attribute.rawValue)") { !$0.has(attribute) }
        }
    }

    private static func ageLimit(_ age: AgeFilter, _ label: String, now: Date, calendar: Calendar) throws -> Date {
        guard age.value >= 0 else { throw SearchValidationError(message: "“\(label)” must be 0 or more.") }
        return calendar.date(byAdding: age.unit.component, value: -age.value, to: now) ?? now
    }
}
