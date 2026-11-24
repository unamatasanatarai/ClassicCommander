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
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { raw in
                var mask = raw
                let forFolders = mask.hasSuffix("/")
                if forFolders { mask.removeLast() }
                if mask == "*.*" || mask.isEmpty { mask = "*" }   // "*.*" also matches names without a dot
                var regex = "^"
                for ch in mask {
                    switch ch {
                    case "*": regex += ".*"
                    case "?": regex += "."
                    default: regex += NSRegularExpression.escapedPattern(for: String(ch))
                    }
                }
                regex += "$"
                let re = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive])
                return Pattern(patternString: regex, regex: re, forFolders: forFolders)
            }
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
