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
        for op in script {
            switch op {
            case .keep:
                Self.flushPending(&pendingRemoved, &pendingAdded, left: left, right: right, into: &rows)
                rows.append(Row(kind: .same, left: left[i], right: right[j], leftNumber: i + 1, rightNumber: j + 1))
                i += 1; j += 1
            case .delete:
                pendingRemoved.append(i); i += 1
            case .insert:
                pendingAdded.append(j); j += 1
            }
        }
        Self.flushPending(&pendingRemoved, &pendingAdded, left: left, right: right, into: &rows)
        self.rows = rows
        self.blocks = Self.diffBlocks(in: rows)
    }

    private static func flushPending(
        _ pendingRemoved: inout [Int], _ pendingAdded: inout [Int],
        left: [String], right: [String], into rows: inout [Row]
    ) {
        // Pair removed and added lines as "changed", the rest stay removed/added.
        let n = max(pendingRemoved.count, pendingAdded.count)
        for k in 0..<n {
            let l = k < pendingRemoved.count ? pendingRemoved[k] : nil
            let r = k < pendingAdded.count ? pendingAdded[k] : nil
            rows.append(Row(kind: rowKind(left: l, right: r), left: l.map { left[$0] }, right: r.map { right[$0] },
                            leftNumber: l.map { $0 + 1 }, rightNumber: r.map { $0 + 1 }))
        }
        pendingRemoved.removeAll()
        pendingAdded.removeAll()
    }

    private static func rowKind(left: Int?, right: Int?) -> Kind {
        left != nil && right != nil ? .changed : (left != nil ? .removed : .added)
    }

    private static func diffBlocks(in rows: [Row]) -> [Int] {
        var blocks: [Int] = []
        for (n, row) in rows.enumerated() where row.kind != .same && (n == 0 || rows[n - 1].kind == .same) {
            blocks.append(n)
        }
        return blocks
    }

    /// The next block after `row` (wrapping is left to the caller), or nil.
    public func nextBlock(after row: Int) -> Int? { blocks.first { $0 > row } }
    public func previousBlock(before row: Int) -> Int? { blocks.last { $0 < row } }

    // MARK: Myers' O(ND) difference algorithm

    enum Op { case keep, delete, insert }

    static func editScript(_ a: [String], _ b: [String]) -> [Op] {
        // Common prefix and suffix are cheap and make the core much smaller.
        let (prefix, suffix) = commonAffixCounts(a, b)
        let a2 = Array(a[prefix..<(a.count - suffix)]), b2 = Array(b[prefix..<(b.count - suffix)])
        let core = myers(a2, b2)
        return Array(repeating: .keep, count: prefix) + core + Array(repeating: .keep, count: suffix)
    }

    private static func commonAffixCounts(_ a: [String], _ b: [String]) -> (prefix: Int, suffix: Int) {
        let prefix = commonPrefixCount(a, b)
        let suffix = commonSuffixCount(a, b, prefix: prefix)
        return (prefix, suffix)
    }

    private static func commonPrefixCount(_ a: [String], _ b: [String]) -> Int {
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        return prefix
    }

    private static func commonSuffixCount(_ a: [String], _ b: [String], prefix: Int) -> Int {
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return suffix
    }

    /// Edit steps searched exactly; beyond this the files are mostly different and the remaining
    /// middle is shown as one changed block (memory stays O(budget²), not O(D·(N+M))).
    static let editBudget = 2500

    private static func myers(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return Array(repeating: .insert, count: m) }
        if m == 0 { return Array(repeating: .delete, count: n) }
        let (ai, bi) = internLines(a, b)
        let maxD = min(n + m, editBudget)
        guard let trace = findTrace(ai, bi, n: n, m: m, maxD: maxD) else {
            return Array(repeating: .delete, count: n) + Array(repeating: .insert, count: m)
        }
        return backtrackMyers(trace: trace, n: n, m: m)
    }

    private static func findTrace(_ ai: [Int], _ bi: [Int], n: Int, m: Int, maxD: Int) -> [[Int]]? {
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        // trace[d] holds the diagonals -d…d of V as they were before step d (all that backtracking reads).
        var trace: [[Int]] = []
        for d in 0...maxD {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            if stepTrace(d: d, v: &v, offset: offset, ai: ai, bi: bi, n: n, m: m) {
                return trace
            }
        }
        return nil
    }

    private static func stepTrace(
        d: Int, v: inout [Int], offset: Int,
        ai: [Int], bi: [Int], n: Int, m: Int
    ) -> Bool {
        var k = -d
        while k <= d {
            if stepSnake(k: k, d: d, v: &v, offset: offset, ai: ai, bi: bi, n: n, m: m) { return true }
            k += 2
        }
        return false
    }

    private static func stepSnake(
        k: Int, d: Int, v: inout [Int], offset: Int,
        ai: [Int], bi: [Int], n: Int, m: Int
    ) -> Bool {
        var x = initialSnakeX(k: k, d: d, v: v, offset: offset)
        var y = x - k
        advanceSnake(x: &x, y: &y, ai: ai, bi: bi, n: n, m: m)
        v[offset + k] = x
        return x >= n && y >= m
    }

    private static func initialSnakeX(k: Int, d: Int, v: [Int], offset: Int) -> Int {
        let takeDown = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
        return takeDown ? v[offset + k + 1] : v[offset + k - 1] + 1
    }

    private static func advanceSnake(x: inout Int, y: inout Int, ai: [Int], bi: [Int], n: Int, m: Int) {
        while x < n && y < m && ai[x] == bi[y] { x += 1; y += 1 }
    }

    private static func internLines(_ a: [String], _ b: [String]) -> ([Int], [Int]) {
        var ids: [String: Int] = [:]
        func id(for s: String) -> Int {
            if let v = ids[s] { return v }
            let v = ids.count
            ids[s] = v
            return v
        }
        return (a.map(id), b.map(id))
    }

    private static func backtrackMyers(trace: [[Int]], n: Int, m: Int) -> [Op] {
        var ops: [Op] = []
        ops.reserveCapacity(n + m)
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            backtrackStep(d: d, saved: trace[d], x: &x, y: &y, ops: &ops)
        }
        return ops.reversed()
    }

    private static func backtrackStep(d: Int, saved: [Int], x: inout Int, y: inout Int, ops: inout [Op]) {
        let k = x - y
        let prevK = previousK(k: k, d: d, saved: saved)
        let prevX = d == 0 ? 0 : saved[prevK + d], prevY = prevX - prevK
        while x > prevX && y > prevY { ops.append(.keep); x -= 1; y -= 1 }
        if d > 0 {
            if x == prevX { ops.append(.insert); y -= 1 } else { ops.append(.delete); x -= 1 }
        }
    }

    private static func previousK(k: Int, d: Int, saved: [Int]) -> Int {
        (k == -d || (k != d && saved[k - 1 + d] < saved[k + 1 + d])) ? k + 1 : k - 1
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
        let sizeA = try fileSize(left), sizeB = try fileSize(right)
        if let textDiff = try textDiffIfSmall(left, right, sizeA: sizeA, sizeB: sizeB) { return textDiff }
        let first = try firstDifference(left, right)
        if first == nil && sizeA == sizeB { return .binary(identical: true, firstDifference: nil) }
        return .binary(identical: false, firstDifference: first ?? min(sizeA, sizeB))
    }

    private static func textDiffIfSmall(_ left: URL, _ right: URL, sizeA: Int64, sizeB: Int64) throws -> FileComparison? {
        // Only files small enough for a text diff are read whole.
        guard sizeA <= textLimit, sizeB <= textLimit else { return nil }
        let a = try Data(contentsOf: left), b = try Data(contentsOf: right)
        guard let l = lines(a), let r = lines(b) else { return nil }
        return .text(TextDiff(left: l, right: r))
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        if url.path == "/dev/null" { return 0 }
        return ((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// The offset of the first differing byte within the common length (nil: no difference there).
    /// Reads both files in 1 MB chunks, so memory stays small whatever their size.
    static func firstDifference(_ left: URL, _ right: URL) throws -> Int64? {
        let ha = try FileHandle(forReadingFrom: left), hb = try FileHandle(forReadingFrom: right)
        defer { try? ha.close(); try? hb.close() }
        var offset: Int64 = 0
        while let step = try readAndCompareChunk(ha, hb, offset: offset) {
            if let found = step.diff { return found }
            offset = step.nextOffset
        }
        return nil
    }

    private static func readAndCompareChunk(_ ha: FileHandle, _ hb: FileHandle, offset: Int64) throws -> (diff: Int64?, nextOffset: Int64)? {
        let (a, b) = try readChunkPair(ha, hb)
        let common = min(a.count, b.count)
        if common == 0 { return nil }
        if let i = firstDifferingByte(a, b, count: common) { return (offset + Int64(i), offset) }
        return a.count != b.count ? nil : (nil, offset + Int64(common))
    }

    private static func readChunkPair(_ ha: FileHandle, _ hb: FileHandle) throws -> (Data, Data) {
        let chunk = 1 << 20
        return try autoreleasepool { (try ha.read(upToCount: chunk) ?? Data(), try hb.read(upToCount: chunk) ?? Data()) }
    }

    private static func firstDifferingByte(_ a: Data, _ b: Data, count: Int) -> Int? {
        a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                guard memcmp(pa.baseAddress!, pb.baseAddress!, count) != 0 else { return nil }
                let x = pa.bindMemory(to: UInt8.self), y = pb.bindMemory(to: UInt8.self)
                var i = 0
                while x[i] == y[i] { i += 1 }
                return i
            }
        }
    }

    /// Text lines (UTF-8, else Latin-1), or nil for binary data (NUL bytes).
    static func lines(_ data: Data) -> [String]? {
        guard let text = decodeTextLinesString(data) else { return nil }
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func decodeTextLinesString(_ data: Data) -> String? {
        if data.prefix(8192).contains(0) { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
