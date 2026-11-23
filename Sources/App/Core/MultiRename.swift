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

    /// The new name of each entry, with the problems that stop Start!.
    /// `existing`: names in the folder that are not being renamed (a new name may not take one).
    public static func preview(_ entries: [FileEntry], rules: RenameRules, existing: Set<String>) throws -> [Row] {
        let names = try entries.enumerated().map { i, e in try newName(for: e, index: i, rules: rules) }
        // The Mac's disks usually ignore case: "A.txt" and "a.txt" are one name.
        var counts: [String: Int] = [:]
        for name in names { counts[name.lowercased(), default: 0] += 1 }
        let taken = Set(existing.map { $0.lowercased() })
        let renamed = Set(entries.map { $0.name.lowercased() })
        return zip(entries, names).map { entry, name in
            var problem: String?
            if name.isEmpty || name == "." || name == ".." {
                problem = "empty name"
            } else if name.contains("/") || name.contains("\0") {
                problem = "“/” is not allowed"
            } else if counts[name.lowercased(), default: 0] > 1 {
                problem = "two files would get this name"
            } else if name.lowercased() != entry.name.lowercased(), taken.contains(name.lowercased()), !renamed.contains(name.lowercased()) {
                problem = "a file with this name exists"
            }
            return Row(entry: entry, newName: name, problem: problem)
        }
    }

    /// One entry's new name (folders have no extension).
    public static func newName(for entry: FileEntry, index: Int, rules: RenameRules) throws -> String {
        let isFile = entry.kind == .file
        let ext = isFile ? (entry.name as NSString).pathExtension : ""
        let base = ext.isEmpty ? entry.name : (entry.name as NSString).deletingPathExtension
        let counter = rules.counterStart + index * rules.counterStep
        let values = Values(name: base, ext: ext, counter: counter, digits: rules.counterDigits, date: entry.modified)
        let newBase = expand(rules.nameMask, values)
        let newExt = isFile ? expand(rules.extensionMask, values) : ""
        var result: String
        if !rules.search.isEmpty && !rules.includeExtension {
            result = try replace(in: newBase, rules) + (newExt.isEmpty ? "" : "." + newExt)
        } else {
            result = newExt.isEmpty ? newBase : newBase + "." + newExt
            if !rules.search.isEmpty { result = try replace(in: result, rules) }
        }
        return changeCase(result, rules.letterCase)
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

    private static func value(of token: String, _ v: Values) -> String? {
        let date = v.date ?? Date(timeIntervalSince1970: 0)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        switch token {
        case "N": return v.name
        case "E": return v.ext
        case "C":
            let n = String(abs(v.counter))
            return (v.counter < 0 ? "-" : "") + String(repeating: "0", count: max(0, v.digits - n.count)) + n
        case "YMD": return String(format: "%04d", c.year ?? 0) + two(c.month) + two(c.day)
        case "hms": return two(c.hour) + two(c.minute) + two(c.second)
        case "Y": return String(format: "%04d", c.year ?? 0)
        case "M": return two(c.month)
        case "D": return two(c.day)
        case "h": return two(c.hour)
        case "m": return two(c.minute)
        case "s": return two(c.second)
        default: break
        }
        // [N2-5], [N3-], [N4], [E1-2]: characters, counted from 1.
        guard let kind = token.first, kind == "N" || kind == "E", token.count > 1 else { return nil }
        let source = Array(kind == "N" ? v.name : v.ext)
        let spec = token.dropFirst()
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count <= 2, let from = Int(parts[0]), from >= 1 else { return nil }
        let to: Int
        if parts.count == 1 { to = from } else if parts[1].isEmpty { to = source.count } else if let n = Int(parts[1]) { to = n } else { return nil }
        guard to >= from else { return "" }
        let lower = min(from - 1, source.count), upper = min(to, source.count)
        return String(source[lower..<upper])
    }

    /// Search & replace (plain or regular expression, with $1 for groups).
    static func replace(in text: String, _ rules: RenameRules) throws -> String {
        if rules.regex {
            let re = try NSRegularExpression(pattern: rules.search, options: rules.caseSensitive ? [] : [.caseInsensitive])
            let whole = NSRange(text.startIndex..., in: text)
            if rules.firstOnly {
                guard let m = re.firstMatch(in: text, range: whole), let r = Range(m.range, in: text) else { return text }
                let replacement = re.replacementString(for: m, in: text, offset: 0, template: rules.replace)
                return text.replacingCharacters(in: r, with: replacement)
            }
            return re.stringByReplacingMatches(in: text, range: whole, withTemplate: rules.replace)
        }
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
