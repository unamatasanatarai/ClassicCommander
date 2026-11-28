import Foundation

/// A Total Commander style file mask, used by "+" (select) and "-" (deselect):
///   "*.txt"            files ending in .txt (case-insensitive)
///   "*.jpg;*.png"      several masks, separated by ";" or spaces
///   "*.*" or "*"       everything
///   "src*/"            a trailing "/" makes the mask match folders instead of files
/// `*` matches any run of characters, `?` exactly one.
public struct FileMask: Equatable {
    private struct Pattern: Equatable {
        let patternString: String
        let regex: NSRegularExpression?
        let forFolders: Bool

        static func == (lhs: Pattern, rhs: Pattern) -> Bool {
            lhs.patternString == rhs.patternString && lhs.forFolders == rhs.forFolders
        }
    }

    private let patterns: [Pattern]

    public init(_ text: String) {
        patterns = text
            .split(whereSeparator: { $0 == ";" || $0 == " " })
            .compactMap { $0.isEmpty ? nil : Self.compilePattern(String($0)) }
    }

    private static func compilePattern(_ raw: String) -> Pattern {
        var mask = raw
        let forFolders = mask.hasSuffix("/")
        if forFolders { mask.removeLast() }
        if mask == "*.*" || mask.isEmpty { mask = "*" }   // "*.*" also matches names without a dot
        let regex = "^" + wildcardToRegex(mask) + "$"
        let re = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive])
        return Pattern(patternString: regex, regex: re, forFolders: forFolders)
    }

    private static func wildcardToRegex(_ mask: String) -> String {
        mask.map { ch in
            switch ch {
            case "*": return ".*"
            case "?": return "."
            default: return NSRegularExpression.escapedPattern(for: String(ch))
            }
        }.joined()
    }

    public var isEmpty: Bool { patterns.isEmpty }

    public func matches(_ entry: FileEntry) -> Bool {
        guard entry.kind != .parent else { return false }
        let isFolder = entry.kind == .directory
        let name = entry.name
        let utf16Count = name.utf16.count
        guard utf16Count > 0 else { return false }
        let range = NSRange(location: 0, length: utf16Count)

        return patterns.contains { p in
            guard p.forFolders == isFolder else { return false }
            if let re = p.regex {
                return re.firstMatch(in: name, options: [], range: range) != nil
            }
            return false
        }
    }
}
