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
        if let range = text.range(of: word) {
            let position = text.distance(from: text.startIndex, to: range.lowerBound)
            let atWordStart = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter
            return 1000 - position + (atWordStart ? 200 : 0)
        }
        // Letters in order: reward consecutive letters and letters that start words.
        let chars = Array(text)
        var score = 0, i = 0, lastHit = -2
        for q in word {
            while i < chars.count && chars[i] != q { i += 1 }
            guard i < chars.count else { return nil }
            if i == lastHit + 1 { score += 15 }
            if i == 0 || !chars[i - 1].isLetter { score += 25 }
            score += 5
            lastHit = i
            i += 1
        }
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
