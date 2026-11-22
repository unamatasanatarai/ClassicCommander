import Foundation

/// A side-by-side line comparison of two files (as used by Synchronize → View).
public struct TextDiff: Equatable {
    public enum Kind: Equatable {
        case same
        /// Both sides have a line here, but different ones.
        case changed
        /// Only the left file has this line.
        case removed
        /// Only the right file has this line.
        case added
    }

    /// One aligned row: a line from each side (nil where that side has none).
    public struct Row: Equatable {
        public let kind: Kind
        public let left: String?
        public let right: String?
        /// 1-based line numbers in each file.
        public let leftNumber: Int?
        public let rightNumber: Int?
    }

    public let rows: [Row]

    /// Indexes of the first row of each block of differences (for next / previous).
    public let blocks: [Int]

    public var isIdentical: Bool { blocks.isEmpty }

    public init(left: [String], right: [String]) {
        let script = Self.editScript(left, right)
        var rows: [Row] = []
        var i = 0, j = 0
        var pendingRemoved: [Int] = [], pendingAdded: [Int] = []
        func flush() {
            // Pair removed and added lines as "changed", the rest stay removed/added.
            let n = max(pendingRemoved.count, pendingAdded.count)
            for k in 0..<n {
                let l = k < pendingRemoved.count ? pendingRemoved[k] : nil
                let r = k < pendingAdded.count ? pendingAdded[k] : nil
                let kind: Kind = l != nil && r != nil ? .changed : (l != nil ? .removed : .added)
                rows.append(Row(kind: kind, left: l.map { left[$0] }, right: r.map { right[$0] },
                                leftNumber: l.map { $0 + 1 }, rightNumber: r.map { $0 + 1 }))
            }
            pendingRemoved.removeAll()
            pendingAdded.removeAll()
        }
        for op in script {
            switch op {
            case .keep:
                flush()
                rows.append(Row(kind: .same, left: left[i], right: right[j], leftNumber: i + 1, rightNumber: j + 1))
                i += 1; j += 1
            case .delete:
                pendingRemoved.append(i); i += 1
            case .insert:
                pendingAdded.append(j); j += 1
            }
        }
        flush()
        self.rows = rows
        var blocks: [Int] = []
        for (n, row) in rows.enumerated() where row.kind != .same && (n == 0 || rows[n - 1].kind == .same) {
            blocks.append(n)
        }
        self.blocks = blocks
    }

    /// The next block after `row` (wrapping is left to the caller), or nil.
    public func nextBlock(after row: Int) -> Int? { blocks.first { $0 > row } }
    public func previousBlock(before row: Int) -> Int? { blocks.last { $0 < row } }

    // MARK: Myers' O(ND) difference algorithm

    enum Op { case keep, delete, insert }

    static func editScript(_ a: [String], _ b: [String]) -> [Op] {
        // Common prefix and suffix are cheap and make the core much smaller.
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let a2 = Array(a[prefix..<(a.count - suffix)]), b2 = Array(b[prefix..<(b.count - suffix)])
        let core = myers(a2, b2)
        return Array(repeating: .keep, count: prefix) + core + Array(repeating: .keep, count: suffix)
    }

    private static func myers(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return Array(repeating: .insert, count: m) }
        if m == 0 { return Array(repeating: .delete, count: n) }
        // Lines become integers so comparisons are cheap.
        var ids: [String: Int] = [:]
        let ai = a.map { s -> Int in if let v = ids[s] { return v }; let v = ids.count; ids[s] = v; return v }
        let bi = b.map { s -> Int in if let v = ids[s] { return v }; let v = ids.count; ids[s] = v; return v }
        let max = n + m
        let offset = max
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        var found = false
        for d in 0...max {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n && y < m && ai[x] == bi[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { found = true; break }
                k += 2
            }
            if found { break }
        }
        // Walk back through the trace to recover the script.
        var ops: [Op] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) { prevK = k + 1 } else { prevK = k - 1 }
            let prevX = v[offset + prevK], prevY = prevX - prevK
            while x > prevX && y > prevY { ops.append(.keep); x -= 1; y -= 1 }
            if d > 0 {
                if x == prevX { ops.append(.insert); y -= 1 } else { ops.append(.delete); x -= 1 }
            }
        }
        return ops.reversed()
    }
}

/// What to show for a pair of files: text lines, or a note for binary / identical / too large.
public enum FileComparison {
    case text(TextDiff)
    /// Not text: whether the bytes are equal and where they first differ.
    case binary(identical: Bool, firstDifference: Int64?)

    /// Files larger than this are compared byte by byte only.
    public static let textLimit = 8 * 1024 * 1024

    public static func compare(_ left: URL, _ right: URL) throws -> FileComparison {
        let a = try Data(contentsOf: left, options: .mappedIfSafe)
        let b = try Data(contentsOf: right, options: .mappedIfSafe)
        if a.count <= textLimit, b.count <= textLimit, let l = lines(a), let r = lines(b) {
            return .text(TextDiff(left: l, right: r))
        }
        if a == b { return .binary(identical: true, firstDifference: nil) }
        return .binary(identical: false, firstDifference: Int64(firstDifference(a, b)))
    }

    /// The offset of the first byte that differs (the shorter length if one is a prefix of the other).
    static func firstDifference(_ a: Data, _ b: Data) -> Int {
        let common = min(a.count, b.count)
        let x = [UInt8](a.prefix(common)), y = [UInt8](b.prefix(common))
        for i in 0..<common where x[i] != y[i] { return i }
        return common
    }

    /// Text lines (UTF-8, else Latin-1), or nil for binary data (NUL bytes).
    static func lines(_ data: Data) -> [String]? {
        if data.prefix(8192).contains(0) { return nil }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
