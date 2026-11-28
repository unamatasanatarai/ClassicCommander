import Foundation

/// Lister (F3 / "3") content handling, independent of the UI: what a file looks like as text,
/// as fixed-width binary and as hex, and which view suits it.
public enum ListerMode: Int, CaseIterable {
    case text = 1, binary, hex, preview

    public var title: String {
        switch self {
        case .text: return "Text"
        case .binary: return "Binary"
        case .hex: return "Hex"
        case .preview: return "Preview"
        }
    }
}

/// Encodings offered in Lister's Encoding menu. `.auto` detects per file.
public enum ListerEncoding: String, CaseIterable {
    case auto, utf8, utf16LE, utf16BE, ansi, ascii

    private static let fixedTitles: [ListerEncoding: String] = [
        .auto: "Auto",
        .utf8: "UTF-8",
        .utf16LE: "UTF-16 LE",
        .utf16BE: "UTF-16 BE",
        .ascii: "ASCII (DOS)",
    ]

    public var title: String {
        Self.fixedTitles[self] ?? "ANSI (\(ContentCharset.ansiName))"
    }

    private static let fixedEncodings: [ListerEncoding: String.Encoding] = [
        .utf8: .utf8,
        .utf16LE: .utf16LittleEndian,
        .utf16BE: .utf16BigEndian,
    ]

    var stringEncoding: String.Encoding? {
        if let fixed = Self.fixedEncodings[self] { return fixed }
        if self == .ansi { return ContentCharset.ansi.stringEncoding }
        if self == .ascii { return ContentCharset.ascii.stringEncoding }
        return nil
    }
}

public enum ListerContent {
    /// Text and binary views show at most this much of a file (hex reads lazily, any size).
    public static let textLimit = 8 * 1024 * 1024

    /// File types that open in Preview (Quick Look) rather than as text.
    static let previewExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "webp", "ico", "icns", "svg",
        "pdf", "mp3", "m4a", "wav", "aiff", "mp4", "mov", "m4v", "avi",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "rtfd",
    ]

    /// The view a file opens in: Preview for media and documents, Hex for binary data, else Text.
    public static func defaultMode(for url: URL, sample: Data) -> ListerMode {
        if previewExtensions.contains(url.pathExtension.lowercased()) { return .preview }
        return isBinary(sample) ? .hex : .text
    }

    /// True for data that is not text: NUL bytes (unless it looks like UTF-16), or many control characters.
    public static func isBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        guard !sample.isEmpty else { return false }
        if detectUTF16(sample) != nil { return false }
        if sample.contains(0) { return true }
        return hasHighControlRatio(sample)
    }

    private static func hasHighControlRatio(_ sample: Data.SubSequence) -> Bool {
        let controls = sample.filter { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D && $0 != 0x0C && $0 != 0x1B }
        return Double(controls.count) / Double(sample.count) > 0.1
    }

    /// UTF-16 by byte-order mark, or by a NUL in every other byte of mostly-ASCII text.
    static func detectUTF16(_ data: Data) -> String.Encoding? {
        let bytes = [UInt8](data.prefix(4096))
        if let bom = detectUTF16BOM(bytes) { return bom }
        return detectUTF16ByZeros(bytes)
    }

    private static func detectUTF16ByZeros(_ bytes: [UInt8]) -> String.Encoding? {
        guard bytes.count >= 8 else { return nil }
        let (evenZeros, oddZeros) = countZeroBytes(bytes)
        let half = bytes.count / 2
        if oddZeros > half * 8 / 10 && evenZeros < half / 10 { return .utf16LittleEndian }
        if evenZeros > half * 8 / 10 && oddZeros < half / 10 { return .utf16BigEndian }
        return nil
    }

    private static func detectUTF16BOM(_ bytes: [UInt8]) -> String.Encoding? {
        guard bytes.count >= 2 else { return nil }
        switch (bytes[0], bytes[1]) {
        case (0xFF, 0xFE): return .utf16LittleEndian
        case (0xFE, 0xFF): return .utf16BigEndian
        default: return nil
        }
    }

    private static func countZeroBytes(_ bytes: [UInt8]) -> (even: Int, odd: Int) {
        var even = 0, odd = 0
        for (i, b) in bytes.enumerated() where b == 0 {
            if i % 2 == 0 { even += 1 } else { odd += 1 }
        }
        return (even, odd)
    }

    /// Auto detection: BOM / UTF-16 pattern, then valid UTF-8, else the user's Windows code page.
    /// `cut` says the data stops at the read limit, so a character broken at the very end is forgiven.
    public static func detectEncoding(_ data: Data, cut: Bool = false) -> ListerEncoding {
        if let u16 = detectUTF16(data) { return u16 == .utf16LittleEndian ? .utf16LE : .utf16BE }
        let checked = cut ? trimIncompleteUTF8(data) : data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) || String(data: checked, encoding: .utf8) != nil {
            return .utf8
        }
        return .ansi
    }

    /// Cuts a UTF-8 sequence broken by the read limit, so a cut-off last character is not "invalid".
    static func trimIncompleteUTF8(_ data: Data) -> Data {
        let bytes = [UInt8](data.suffix(4))
        // Walk back over continuation bytes to the last lead byte and check its sequence is complete.
        var i = bytes.count - 1
        while i >= 0 && bytes[i] & 0xC0 == 0x80 { i -= 1 }
        guard i >= 0 else { return data }
        let needed = utf8SequenceLength(bytes[i])
        let have = bytes.count - i
        return have < needed ? data.prefix(data.count - have) : data
    }

    private static func utf8SequenceLength(_ lead: UInt8) -> Int {
        if lead >= 0xF0 { return 4 }
        if lead >= 0xE0 { return 3 }
        if lead >= 0xC0 { return 2 }
        return 1
    }

    /// The text of `data` in an encoding (auto-detected when `.auto`). Never fails: bad bytes become U+FFFD.
    public static func text(_ data: Data, encoding: ListerEncoding, cut: Bool = false) -> (String, ListerEncoding) {
        let chosen = encoding == .auto ? detectEncoding(data, cut: cut) : encoding
        guard let enc = chosen.stringEncoding else { return ("", chosen) }
        let body = stripBOM(data, encoding: chosen)
        return (ContentMatcher.decoder(for: enc)(body), chosen)
    }

    private static let boms: [ListerEncoding: [UInt8]] = [
        .utf8: [0xEF, 0xBB, 0xBF],
        .utf16LE: [0xFF, 0xFE],
        .utf16BE: [0xFE, 0xFF],
    ]

    private static func stripBOM(_ data: Data, encoding: ListerEncoding) -> Data {
        if let bom = boms[encoding], data.starts(with: bom) {
            return Data(data.dropFirst(bom.count))
        }
        return data
    }

    /// Fixed-width "binary" view: every byte as a character, control bytes as "·", lines of `width`.
    public static func binaryText(_ data: Data, width: Int = 80) -> String {
        var out = ""
        out.reserveCapacity(data.count + data.count / width + 1)
        var column = 0
        for b in data {
            out.unicodeScalars.append(b >= 0x20 && b < 0x7F ? Unicode.Scalar(b) : "·")
            column += 1
            if column == width {
                out.append("\n")
                column = 0
            }
        }
        return out
    }

    /// One hex line: "00000010  48 65 6C 6C 6F 20 57 6F  72 6C 64 0A              Hello World."
    public static func hexLine(_ bytes: [UInt8], offset: Int64) -> String {
        var hex = ""
        for i in 0..<16 {
            if i == 8 { hex += " " }
            hex += i < bytes.count ? String(format: "%02X ", bytes[i]) : "   "
        }
        let ascii = String(bytes.map { $0 >= 0x20 && $0 < 0x7F ? Character(Unicode.Scalar($0)) : "." })
        return String(format: "%08llX  ", offset) + hex + " " + ascii
    }
}

/// Reads a file's bytes on demand for the hex view, so files of any size open instantly.
public final class HexReader {
    public let url: URL
    public let size: Int64
    private let handle: FileHandle
    private var cacheStart: Int64 = -1
    private var cache = Data()

    public init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    deinit { try? handle.close() }

    public var lineCount: Int { Int((size + 15) / 16) }

    /// The bytes of hex line `index` (16 bytes, fewer at the end).
    public func bytes(forLine index: Int) -> [UInt8] {
        let offset = Int64(index) * 16
        guard offset < size else { return [] }
        // Read 64 KB blocks and serve lines from them.
        let block: Int64 = 64 * 1024
        let start = offset / block * block
        if start != cacheStart {
            try? handle.seek(toOffset: UInt64(start))
            cache = (try? handle.read(upToCount: Int(block))).flatMap { $0 } ?? Data()
            cacheStart = start
        }
        let from = Int(offset - start)
        guard from < cache.count else { return [] }
        return [UInt8](cache[cache.startIndex + from ..< cache.startIndex + min(from + 16, cache.count)])
    }

    public func line(_ index: Int) -> String {
        ListerContent.hexLine(bytes(forLine: index), offset: Int64(index) * 16)
    }
}
