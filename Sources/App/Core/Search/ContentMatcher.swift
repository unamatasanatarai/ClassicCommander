import Foundation

/// "Find text" for Find Files. Files are read in chunks (never whole); each chunk is searched
/// together with the tail of the previous one, so matches across chunk borders are found.
///   - Text mode tries every ticked charset; invalid bytes become U+FFFD instead of failing.
///     A file with a NUL byte near the start is binary: it is searched only as UTF-16 (if ticked)
///     or skipped. Office documents (docx, xlsx, pptx, odt, ods, odp) are unpacked and their
///     text searched when "Office xml" is ticked.
///   - Hex mode searches raw bytes ("4D 5A 90" or "4d5a90") in any file.
public struct ContentMatcher {
    public enum Outcome: Equatable {
        case contains, lacks
        /// Not searched (binary file in text mode).
        case skipped
    }

    private struct Decoder {
        let charset: ContentCharset
        let decode: (Data) -> String
    }

    private enum Mode {
        case text(NSRegularExpression, decoders: [Decoder], office: Bool)
        case bytes(Data)
    }

    private let mode: Mode
    let chunkSize: Int
    /// Bytes carried over from the previous chunk; bounds the longest match that can span a border.
    let overlap: Int

    static let officeExtensions: Set<String> = ["docx", "xlsx", "pptx", "docm", "xlsm", "odt", "ods", "odp"]

    public init(_ config: ContentSearchConfiguration, chunkSize: Int = 1 << 20) throws {
        guard !config.expression.isEmpty else {
            throw SearchValidationError(message: "Enter the text to find, or untick “Find text”.")
        }
        if config.hexadecimal {
            guard let bytes = Self.parseHex(config.expression) else {
                throw SearchValidationError(message: "Hex text must be pairs of hex digits, e.g. 4D 5A 90.")
            }
            mode = .bytes(bytes)
            overlap = bytes.count - 1
        } else {
            guard !config.charsets.isEmpty else {
                throw SearchValidationError(message: "Tick at least one charset for “Find text”.")
            }
            var pattern = config.useRegex ? config.expression : NSRegularExpression.escapedPattern(for: config.expression)
            if config.wholeWordsOnly {
                pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])"
            }
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern, options: config.caseSensitive ? [] : [.caseInsensitive])
            } catch {
                throw SearchValidationError(message: "“Find text” is not a valid regular expression (untick RegEx (2) to search for it literally).")
            }
            let decoders = config.charsets.compactMap { cs in
                cs.stringEncoding.map { Decoder(charset: cs, decode: Self.decoder(for: $0)) }
            }
            let longest = config.charsets.compactMap { $0.stringEncoding }
                .map { config.expression.data(using: $0)?.count ?? config.expression.utf8.count * 4 }.max() ?? 16
            // Literal text needs only its own length; a regex gets a generous 64 KB window. Kept even for UTF-16.
            var carry = config.useRegex ? 64 * 1024 : max(longest * 2, 16)
            carry += carry % 2
            overlap = carry
            mode = .text(regex, decoders: decoders, office: config.charsets.contains(.officeXML))
        }
        var size = max(chunkSize, overlap + 16)
        size += size % 2
        self.chunkSize = size
    }

    /// Searches one file. Throws when it cannot be read.
    public func search(_ url: URL, isCancelled: () -> Bool = { false }) throws -> Outcome {
        if case let .text(regex, _, office) = mode, Self.officeExtensions.contains(url.pathExtension.lowercased()) {
            // Office files are zip archives: search their text when asked, otherwise they are binary.
            guard office else { return .skipped }
            let text = try Self.officeText(url)
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil ? .contains : .lacks
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var activeDecoders: [Decoder] = []
        var carry = Data()
        var first = true
        while true {
            if isCancelled() { return .lacks }
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { return .lacks }
            if first {
                first = false
                guard let decoders = initialDecoders(for: chunk) else { return .skipped }
                activeDecoders = decoders
            }
            let window = carry + chunk
            if matchesWindow(window, decoders: activeDecoders) { return .contains }
            let keep = min(overlap, window.count)
            var start = window.count - keep
            if start % 2 != 0 { start -= 1 }   // keep UTF-16 code units aligned
            carry = window.subdata(in: window.startIndex.advanced(by: max(0, start))..<window.endIndex)
        }
    }

    private func initialDecoders(for firstChunk: Data) -> [Decoder]? {
        guard case let .text(_, decoders, _) = mode else { return [] }
        guard firstChunk.prefix(8192).contains(0) else { return decoders }
        // Binary-looking: only UTF-16 text legitimately contains NUL bytes.
        let utf16Only = decoders.filter { $0.charset == .utf16 }
        return utf16Only.isEmpty ? nil : utf16Only
    }

    private func matchesWindow(_ window: Data, decoders: [Decoder]) -> Bool {
        switch mode {
        case .bytes(let needle):
            return window.range(of: needle) != nil
        case let .text(regex, _, _):
            return decoders.contains {
                let text = $0.decode(window)
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
    }

    /// The visible text of an Office/OpenDocument file: its XML parts unpacked with unzip, tags removed.
    static func officeText(_ url: URL) throws -> String {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", url.path, "*.xml"]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        let xml = String(decoding: data, as: UTF8.self)
        var text = xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
    }

    static func parseHex(_ text: String) -> Data? {
        let digits = text.filter { !$0.isWhitespace }
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        var data = Data()
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Decoders that never fail: bad sequences turn into U+FFFD.
    static func decoder(for encoding: String.Encoding) -> (Data) -> String {
        switch encoding {
        case .utf8:
            return { String(decoding: $0, as: UTF8.self) }
        case .utf16LittleEndian, .utf16BigEndian:
            let little = encoding == .utf16LittleEndian
            return { data in
                var units: [UInt16] = []
                units.reserveCapacity(data.count / 2)
                var i = data.startIndex
                while i + 1 < data.endIndex {
                    let a = UInt16(data[i]), b = UInt16(data[i + 1])
                    units.append(little ? (a | b << 8) : (a << 8 | b))
                    i += 2
                }
                return String(decoding: units, as: UTF16.self)
            }
        default:
            // Single-byte charsets: a 256-entry table, so undefined bytes cannot make decoding fail.
            let table: [Character] = (0...255).map { b in
                String(data: Data([UInt8(b)]), encoding: encoding).flatMap(\.first) ?? "\u{FFFD}"
            }
            return { data in String(data.map { table[Int($0)] }) }
        }
    }
}
