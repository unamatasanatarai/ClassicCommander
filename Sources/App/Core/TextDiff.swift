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
            var k = -d
            while k <= d {
                let takeDown = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
                var x = takeDown ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n && y < m && ai[x] == bi[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { return trace }
                k += 2
            }
        }
        return nil
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
            let saved = trace[d]
            func value(_ k: Int) -> Int { saved[k + d] }
            let k = x - y
            let prevK = (k == -d || (k != d && value(k - 1) < value(k + 1))) ? k + 1 : k - 1
            let prevX = d == 0 ? 0 : value(prevK), prevY = prevX - prevK
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
        let sizeA = try fileSize(left), sizeB = try fileSize(right)
        // Only files small enough for a text diff are read whole.
        if sizeA <= textLimit, sizeB <= textLimit {
            let a = try Data(contentsOf: left), b = try Data(contentsOf: right)
            if let l = lines(a), let r = lines(b) { return .text(TextDiff(left: l, right: r)) }
        }
        let first = try firstDifference(left, right)
        if first == nil && sizeA == sizeB { return .binary(identical: true, firstDifference: nil) }
        return .binary(identical: false, firstDifference: first ?? min(sizeA, sizeB))
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
        let chunk = 1 << 20
        while true {
            let (a, b) = try autoreleasepool { (try ha.read(upToCount: chunk) ?? Data(), try hb.read(upToCount: chunk) ?? Data()) }
            let common = min(a.count, b.count)
            if common == 0 { return nil }
            let differs: Int? = a.withUnsafeBytes { pa in
                b.withUnsafeBytes { pb in
                    guard memcmp(pa.baseAddress!, pb.baseAddress!, common) != 0 else { return nil }
                    let x = pa.bindMemory(to: UInt8.self), y = pb.bindMemory(to: UInt8.self)
                    var i = 0
                    while x[i] == y[i] { i += 1 }
                    return i
                }
            }
            if let i = differs { return offset + Int64(i) }
            offset += Int64(common)
            if a.count != b.count { return nil }
        }
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
