import Foundation

/// The Multi-Rename Tool's rules (Total Commander's Ctrl+M): a mask for the name and one for the
/// extension, search & replace, upper/lowercase and a counter.
public struct RenameRules: Equatable {
    public enum Case: String, CaseIterable {
        case unchanged, lower, upper, firstUpper, words

        public var label: String {
            switch self {
            case .unchanged: return "Unchanged"
            case .lower: return "lowercase"
            case .upper: return "UPPERCASE"
            case .firstUpper: return "First letter uppercase"
            case .words: return "Every Word Uppercase"
            }
        }
    }

    /// [N] name, [N2-5] / [N3-] / [N4] characters of it, [E] extension (also [E1-2]), [C] counter,
    /// [YMD] date, [hms] time, [Y] [M] [D] [h] [m] [s] single parts. Anything else is kept as typed.
    public var nameMask = "[N]"
    public var extensionMask = "[E]"
    public var search = ""
    public var replace = ""
    public var caseSensitive = false
    /// Only the first occurrence ("1x").
    public var firstOnly = false
    /// Search & replace also looks at the extension ("[E]").
    public var includeExtension = false
    public var regex = false
    public var letterCase = Case.unchanged
    public var counterStart = 1
    public var counterStep = 1
    /// The counter is padded with zeros to this many digits.
    public var counterDigits = 1

    public init() {}
}

/// Works out new names, checks them, and renames (two steps, so names can be swapped) with Undo.
public enum MultiRename {
    public struct Row: Equatable {
        public let entry: FileEntry
        public let newName: String
        /// Why it can't be renamed (empty name, "/", two files with one name, the name is taken).
        public let problem: String?
        public var changes: Bool { newName != entry.name }
    }

    struct RenameContext {
        let rules: RenameRules
        let searchRegex: NSRegularExpression?
    }

    /// The new name of each entry, with the problems that stop Start!.
    /// `existing`: names in the folder that are not being renamed (a new name may not take one).
    public static func preview(_ entries: [FileEntry], rules: RenameRules, existing: Set<String>) throws -> [Row] {
        let searchRegex = try compileSearchRegex(rules)
        let ctx = RenameContext(rules: rules, searchRegex: searchRegex)
        let names = try entries.enumerated().map { i, e in try newName(for: e, index: i, context: ctx) }
        // The Mac's disks usually ignore case: "A.txt" and "a.txt" are one name.
        var counts: [String: Int] = [:]
        for name in names { counts[name.lowercased(), default: 0] += 1 }
        let taken = Set(existing.map { $0.lowercased() })
        let renamed = Set(entries.map { $0.name.lowercased() })
        return zip(entries, names).map { entry, name in
            Row(entry: entry, newName: name, problem: rowProblem(name: name, entry: entry, counts: counts, taken: taken, renamed: renamed))
        }
    }

    private static func compileSearchRegex(_ rules: RenameRules) throws -> NSRegularExpression? {
        guard rules.regex && !rules.search.isEmpty else { return nil }
        return try NSRegularExpression(pattern: rules.search, options: rules.caseSensitive ? [] : [.caseInsensitive])
    }

    private static func rowProblem(
        name: String, entry: FileEntry,
        counts: [String: Int], taken: Set<String>, renamed: Set<String>
    ) -> String? {
        if let invalid = invalidNameMessage(name) { return invalid }
        let lower = name.lowercased()
        if counts[lower, default: 0] > 1 { return "two files would get this name" }
        if lower != entry.name.lowercased(), taken.contains(lower), !renamed.contains(lower) {
            return "a file with this name exists"
        }
        return nil
    }

    private static func invalidNameMessage(_ name: String) -> String? {
        if name.isEmpty || name == "." || name == ".." { return "empty name" }
        if name.contains("/") || name.contains("\0") { return "“/” is not allowed" }
        return nil
    }

    /// One entry's new name (folders have no extension).
    public static func newName(for entry: FileEntry, index: Int, rules: RenameRules) throws -> String {
        let ctx = RenameContext(rules: rules, searchRegex: try compileSearchRegex(rules))
        return try newName(for: entry, index: index, context: ctx)
    }

    static func newName(for entry: FileEntry, index: Int, context: RenameContext) throws -> String {
        let rules = context.rules
        let isFile = entry.kind == .file
        let ext = isFile ? (entry.name as NSString).pathExtension : ""
        let base = ext.isEmpty ? entry.name : (entry.name as NSString).deletingPathExtension
        let counter = rules.counterStart + index * rules.counterStep
        let values = Values(name: base, ext: ext, counter: counter, digits: rules.counterDigits, date: entry.modified)
        let newBase = expand(rules.nameMask, values)
        let newExt = isFile ? expand(rules.extensionMask, values) : ""
        let result = try applySearchAndReplace(base: newBase, ext: newExt, context: context)
        return changeCase(result, rules.letterCase)
    }

    private static func applySearchAndReplace(base: String, ext: String, context: RenameContext) throws -> String {
        let rules = context.rules
        if !rules.search.isEmpty && !rules.includeExtension {
            return joinName(try replace(in: base, context), ext: ext)
        }
        let combined = joinName(base, ext: ext)
        return rules.search.isEmpty ? combined : try replace(in: combined, context)
    }

    private static func joinName(_ base: String, ext: String) -> String {
        ext.isEmpty ? base : base + "." + ext
    }

    struct Values {
        let name: String
        let ext: String
        let counter: Int
        let digits: Int
        let date: Date?
    }

    /// Fills in the [placeholders] of a mask.
    static func expand(_ mask: String, _ v: Values) -> String {
        var out = ""
        var rest = Substring(mask)
        while let open = rest.firstIndex(of: "[") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "]") else { break }
            let token = String(rest[rest.index(after: open)..<close])
            out += value(of: token, v) ?? "[\(token)]"
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    private static func dateParts(for v: Values) -> (year: String, month: String, day: String, hour: String, minute: String, second: String) {
        let date = v.date ?? Date(timeIntervalSince1970: 0)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        return (String(format: "%04d", c.year ?? 0), two(c.month), two(c.day), two(c.hour), two(c.minute), two(c.second))
    }

    private static let fixedTokens: [String: (Values) -> String] = [
        "N": { $0.name },
        "E": { $0.ext },
        "C": { v in
            let n = String(abs(v.counter))
            return (v.counter < 0 ? "-" : "") + String(repeating: "0", count: max(0, v.digits - n.count)) + n
        },
        "YMD": { let dp = dateParts(for: $0); return dp.year + dp.month + dp.day },
        "hms": { let dp = dateParts(for: $0); return dp.hour + dp.minute + dp.second },
        "Y": { dateParts(for: $0).year },
        "M": { dateParts(for: $0).month },
        "D": { dateParts(for: $0).day },
        "h": { dateParts(for: $0).hour },
        "m": { dateParts(for: $0).minute },
        "s": { dateParts(for: $0).second },
    ]

    private static func value(of token: String, _ v: Values) -> String? {
        if let resolver = fixedTokens[token] { return resolver(v) }
        return sliceToken(token, v)
    }

    /// [N2-5], [N3-], [N4], [E1-2]: characters, counted from 1.
    private static func sliceToken(_ token: String, _ v: Values) -> String? {
        guard let kind = token.first, kind == "N" || kind == "E", token.count > 1 else { return nil }
        let source = Array(kind == "N" ? v.name : v.ext)
        let parts = token.dropFirst().split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count <= 2, let from = Int(parts[0]), from >= 1,
              let to = parseSliceEnd(parts, defaultEnd: source.count, from: from) else { return nil }
        guard to >= from else { return "" }
        let lower = min(from - 1, source.count), upper = min(to, source.count)
        return String(source[lower..<upper])
    }

    private static func parseSliceEnd(_ parts: [Substring], defaultEnd: Int, from: Int) -> Int? {
        if parts.count == 1 { return from }
        if parts[1].isEmpty { return defaultEnd }
        return Int(parts[1])
    }

    /// Search & replace (plain or regular expression, with $1 for groups).
    static func replace(in text: String, _ context: RenameContext) throws -> String {
        let rules = context.rules
        if rules.regex {
            return replaceRegex(in: text, rules: rules, cached: context.searchRegex)
        }
        return replacePlain(in: text, rules: rules)
    }

    private static func replaceRegex(in text: String, rules: RenameRules, cached: NSRegularExpression?) -> String {
        guard let re = compiledRegex(for: rules, cached: cached) else { return text }
        let whole = NSRange(text.startIndex..., in: text)
        if rules.firstOnly { return replaceFirstRegexMatch(in: text, whole: whole, regex: re, template: rules.replace) }
        return re.stringByReplacingMatches(in: text, range: whole, withTemplate: rules.replace)
    }

    private static func replaceFirstRegexMatch(
        in text: String, whole: NSRange, regex: NSRegularExpression, template: String
    ) -> String {
        guard let m = regex.firstMatch(in: text, range: whole), let r = Range(m.range, in: text) else { return text }
        let replacement = regex.replacementString(for: m, in: text, offset: 0, template: template)
        return text.replacingCharacters(in: r, with: replacement)
    }

    private static func compiledRegex(for rules: RenameRules, cached: NSRegularExpression?) -> NSRegularExpression? {
        cached ?? (try? NSRegularExpression(pattern: rules.search, options: rules.caseSensitive ? [] : [.caseInsensitive]))
    }

    private static func replacePlain(in text: String, rules: RenameRules) -> String {
        let options: String.CompareOptions = rules.caseSensitive ? [] : [.caseInsensitive]
        if rules.firstOnly {
            guard let r = text.range(of: rules.search, options: options) else { return text }
            return text.replacingCharacters(in: r, with: rules.replace)
        }
        return text.replacingOccurrences(of: rules.search, with: rules.replace, options: options)
    }

    static func changeCase(_ name: String, _ mode: RenameRules.Case) -> String {
        switch mode {
        case .unchanged: return name
        case .lower: return name.lowercased()
        case .upper: return name.uppercased()
        case .firstUpper: return name.prefix(1).uppercased() + name.dropFirst().lowercased()
        case .words: return name.capitalized
        }
    }

    /// A rename that was done: from → to (Undo goes the other way).
    public typealias Move = (from: URL, to: URL)

    /// Renames every changed row: first to temporary names, then to the new ones, so swapping
    /// names (a→b, b→a) works. A failure in the first step puts everything back. Returns what was
    /// renamed (for Undo) and the problems.
    public static func apply(_ rows: [Row], rename: (URL, URL) throws -> Void) -> (done: [Move], errors: [String]) {
        let moves = rows.filter(\.changes).map { ($0.entry.url, $0.entry.url.deletingLastPathComponent().appendingPathComponent($0.newName)) }
        return run(moves, rename: rename)
    }

    /// Undo: the renames of `done`, reversed.
    public static func undo(_ done: [Move], rename: (URL, URL) throws -> Void) -> (done: [Move], errors: [String]) {
        run(done.map { ($0.to, $0.from) }, rename: rename)
    }

    static func run(_ moves: [Move], rename: (URL, URL) throws -> Void) -> (done: [Move], errors: [String]) {
        var temps: [(URL, URL, URL)] = []
        for (from, to) in moves {
            let temp = from.deletingLastPathComponent().appendingPathComponent(".cc-rename-\(UUID().uuidString)")
            do {
                try rename(from, temp)
                temps.append((from, temp, to))
            } catch {
                // Put back what was moved aside, and stop.
                for (original, t, _) in temps.reversed() { try? rename(t, original) }
                return ([], ["\(from.lastPathComponent): \(error.localizedDescription)"])
            }
        }
        return finishMoves(temps, rename: rename)
    }

    private static func finishMoves(_ temps: [(URL, URL, URL)], rename: (URL, URL) throws -> Void) -> (done: [Move], errors: [String]) {
        var done: [Move] = [], errors: [String] = [], failed: [(URL, URL)] = []
        for (original, temp, to) in temps {
            do {
                try rename(temp, to)
                done.append((original, to))
            } catch {
                failed.append((original, temp))
                errors.append("\(original.lastPathComponent) → \(to.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // Failed ones go back to their old names once the others are done (a swap may have taken
        // the old name: then the file keeps its temporary name, which is reported).
        for (original, temp) in failed {
            do { try rename(temp, original) } catch {
                errors.append("\(original.lastPathComponent) is now named “\(temp.lastPathComponent)” (its old name is taken)")
            }
        }
        return (done, errors)
    }
}
