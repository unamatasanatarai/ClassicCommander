import Foundation

/// Fuzzy filtering for lists like Options → Shortcuts.
///   "copy"  substring matches rank highest (earlier = better);
///   "nwfl"  letters in order also match ("New folder"), ranked by how close together they are
///           and whether they start words;
///   "copy f5"  every space-separated word must match.
/// Case and accents are ignored.
public enum FuzzyMatch {
    /// A score (higher is better) when `query` matches `text`, or nil.
    public static func score(_ query: String, in text: String) -> Int? {
        let words = fold(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return 0 }
        let haystack = fold(text)
        var total = 0
        for word in words {
            guard let s = wordScore(word, in: haystack) else { return nil }
            total += s
        }
        return total
    }

    /// Letters that are not "base letter + accent" in Unicode, so folding leaves them alone.
    private static let extraFolds: [Character: String] = ["ł": "l", "đ": "d", "ø": "o", "æ": "ae", "œ": "oe", "ß": "ss", "ı": "i"]

    static func fold(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.flatMap { extraFolds[$0].map(Array.init) ?? [$0] })
    }

    private static func wordScore(_ word: String, in text: String) -> Int? {
        if let score = substringScore(word, in: text) { return score }
        return subsequenceScore(word, in: text)
    }

    private static func substringScore(_ word: String, in text: String) -> Int? {
        guard let range = text.range(of: word) else { return nil }
        let position = text.distance(from: text.startIndex, to: range.lowerBound)
        let atWordStart = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter
        return 1000 - position + (atWordStart ? 200 : 0)
    }

    private static func subsequenceScore(_ word: String, in text: String) -> Int? {
        // Letters in order: reward consecutive letters and letters that start words.
        let chars = Array(text)
        var score = 0, i = 0, lastHit = -2
        for q in word {
            guard let hit = nextMatchIndex(of: q, in: chars, from: i) else { return nil }
            score += hitScore(at: hit, lastHit: lastHit, in: chars)
            lastHit = hit
            i = hit + 1
        }
        return score
    }

    private static func nextMatchIndex(of target: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count && chars[i] != target { i += 1 }
        return i < chars.count ? i : nil
    }

    private static func hitScore(at index: Int, lastHit: Int, in chars: [Character]) -> Int {
        var score = 5
        if index == lastHit + 1 { score += 15 }
        if index == 0 || !chars[index - 1].isLetter { score += 25 }
        return score
    }

    /// The items whose text matches, best first; an empty query keeps everything in order.
    public static func filter<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.enumerated()
            .compactMap { pair in score(query, in: text(pair.element)).map { (pair.offset, pair.element, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }
}
