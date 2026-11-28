import Foundation

/// One entry of a remote directory listing.
extension Int64 {
    /// Addition that stops at Int64.max instead of crashing (totals of server-reported sizes).
    public func addingSaturated(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}

public struct RemoteEntry: Equatable {
    public let name: String
    public let isDirectory: Bool
    public let isLink: Bool
    public let size: Int64
    public let modified: Date?
    public let permissions: Int?
    /// How exact `modified` is, in seconds: MLSD gives seconds, LIST minutes (or only the day for old files).
    public var datePrecision: TimeInterval = 1
}

/// Parses FTP directory listings: MLSD (machine-readable) and LIST in Unix and Windows/IIS style.
/// Listing data comes from the server and is untrusted: lines that do not parse are skipped,
/// and names that could escape the directory ("." "..", "/", NUL, control characters) are dropped.
public enum FTPListingParser {
    public static func parse(_ text: String, type: FTPServerType, now: Date = Date()) -> [RemoteEntry] {
        text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .filter { !$0.isEmpty }
            .compactMap { parseLine($0, type: type, now: now) }
            .filter { isSafeName($0.name) }
    }

    private static func parseLine(_ line: String, type: FTPServerType, now: Date) -> RemoteEntry? {
        switch type {
        case .mlsd: return parseMLSD(line)
        case .unixList: return parseUnix(line, now: now)
        case .dosList: return parseDOS(line)
        case .automatic: return parseAutomatic(line, now: now)
        }
    }

    private static func parseAutomatic(_ line: String, now: Date) -> RemoteEntry? {
        parseMLSD(line) ?? parseUnix(line, now: now) ?? parseDOS(line)
    }

    /// Sizes come from the server: negative ones become 0, absurd ones are capped (1 PiB),
    /// so totals over many entries cannot overflow.
    public static let maxSize: Int64 = 1 << 50

    static func size(_ text: Substring?) -> Int64? {
        guard let text = text, let v = Int64(text) else { return nil }
        return Swift.min(Swift.max(v, 0), maxSize)
    }

    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.count <= 1024 else { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0.value < 0x20 || $0.value == 0x7F }
    }

    // "type=file;size=1234;modify=20261121120000;UNIX.mode=0644; index.html"
    static func parseMLSD(_ line: String) -> RemoteEntry? {
        guard let space = line.firstIndex(of: " "), line[..<space].contains("=") else { return nil }
        let name = String(line[line.index(after: space)...])
        let facts = parseMLSDFacts(line[..<space])
        guard let type = facts["type"]?.lowercased(), type != "cdir", type != "pdir" else { return nil }
        let isDir = type == "dir"
        let isLink = type.hasPrefix("os.unix=slink") || type.contains("slink")
        let modified = parseMLSDDate(facts["modify"])
        let perms = facts["unix.mode"].flatMap { Int($0, radix: 8) }
        return RemoteEntry(name: name, isDirectory: isDir, isLink: isLink,
                           size: isDir ? 0 : size(facts["size"].map { Substring($0) }) ?? 0, modified: modified, permissions: perms)
    }

    private static func parseMLSDFacts(_ header: Substring) -> [String: String] {
        var facts: [String: String] = [:]
        for fact in header.split(separator: ";") {
            let kv = fact.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { facts[kv[0].lowercased()] = kv[1] }
        }
        return facts
    }

    private static func parseMLSDDate(_ value: String?) -> Date? {
        guard let m = value else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: String(m.prefix(14)))
    }

    // "-rw-r--r--   1 owner group     8192 Nov 21 12:00 index.html"
    // "drwxr-xr-x   2 owner group     4096 Mar  3  2025 assets"
    // "lrwxrwxrwx   1 owner group        7 Nov 21 12:00 current -> release"
    static func parseUnix(_ line: String, now: Date) -> RemoteEntry? {
        guard let kind = line.first, "-dlbcps".contains(kind) else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 9, fields[0].count >= 10 else { return nil }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let mi = fields.indices.dropFirst(2).first(where: { months.contains(fields[$0].lowercased()) && $0 + 2 < fields.count }),
              let month = months.firstIndex(of: fields[mi].lowercased()) else { return nil }
        return buildUnixEntry(kind: kind, fields: fields, line: line, mi: mi, month: month + 1, now: now)
    }

    private static func buildUnixEntry(
        kind: Character, fields: [Substring], line: String, mi: Int, month: Int, now: Date
    ) -> RemoteEntry? {
        guard let day = Int(fields[mi + 1]),
              let size = size(fields[mi - 1]),
              let nameStart = rangeAfterField(line, fieldIndex: mi + 2) else { return nil }
        let (modified, precision) = parseUnixDate(month: month, day: day, yearOrTime: fields[mi + 2], now: now)
        var name = String(line[nameStart...])
        let isLink = kind == "l"
        if isLink, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        return RemoteEntry(name: name, isDirectory: kind == "d", isLink: isLink, size: kind == "d" ? 0 : size,
                           modified: modified, permissions: permissionBits(String(fields[0])), datePrecision: precision)
    }

    private static func parseUnixDate(month: Int, day: Int, yearOrTime: Substring, now: Date) -> (Date?, TimeInterval) {
        var comps = DateComponents()
        comps.month = month
        comps.day = day
        let utc = Calendar(identifier: .gregorian)
        let hasTime = yearOrTime.contains(":")
        if hasTime {
            let hm = yearOrTime.split(separator: ":")
            comps.hour = Int(hm[0]); comps.minute = hm.count > 1 ? Int(hm[1]) : 0
            let year = utc.component(.year, from: now)
            comps.year = year
            if let d = utc.date(from: comps), d > now.addingTimeInterval(86_400) { comps.year = year - 1 }
        } else {
            comps.year = Int(yearOrTime)
        }
        return (utc.date(from: comps), hasTime ? 60 : 86_400)
    }

    // "11-21-26  12:00PM       <DIR>          assets"
    // "11-21-2026  09:15AM             8192 index.html"
    static func parseDOS(_ line: String) -> RemoteEntry? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4, let modified = parseDOSDate(fields[0], fields[1]),
              let nameStart = rangeAfterField(line, fieldIndex: 2),
              let (isDir, fileSize) = dosKindAndSize(fields[2]) else { return nil }
        return RemoteEntry(name: String(line[nameStart...]), isDirectory: isDir, isLink: false,
                           size: fileSize, modified: modified, permissions: nil, datePrecision: 60)
    }

    private static func dosKindAndSize(_ field: Substring) -> (Bool, Int64)? {
        if field.uppercased() == "<DIR>" { return (true, 0) }
        return size(field).map { (false, $0) }
    }

    private static func parseDOSDate(_ dateField: Substring, _ timeField: Substring) -> Date? {
        let dateParts = dateField.split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3, let (hour, minute) = parseDOSTime(timeField) else { return nil }
        var year = dateParts[2]
        if year < 100 { year += year < 70 ? 2000 : 1900 }
        let comps = DateComponents(year: year, month: dateParts[0], day: dateParts[1], hour: hour, minute: minute)
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    private static func parseDOSTime(_ timeField: Substring) -> (Int, Int)? {
        let time = timeField.uppercased()
        guard time.hasSuffix("AM") || time.hasSuffix("PM") || time.contains(":") else { return nil }
        let hm = dosHourMinuteParts(time)
        guard hm.count == 2 else { return nil }
        return (adjustedDOSHour(hm[0], suffix: time), hm[1])
    }

    private static func dosHourMinuteParts(_ time: String) -> [Int] {
        time.dropLast(time.hasSuffix("M") ? 2 : 0).split(separator: ":").compactMap { Int($0) }
    }

    private static func adjustedDOSHour(_ rawHour: Int, suffix time: String) -> Int {
        if time.hasSuffix("PM") { return (rawHour % 12) + 12 }
        if time.hasSuffix("AM") { return rawHour % 12 }
        return rawHour
    }

    /// Where the text after field number `fieldIndex` (0-based, space separated) begins.
    private static func rangeAfterField(_ line: String, fieldIndex: Int) -> String.Index? {
        var index = line.startIndex
        for _ in 0...fieldIndex {
            guard let start = line[index...].firstIndex(where: { $0 != " " }) else { return nil }
            if let space = line[start...].firstIndex(of: " ") {
                index = space
            } else {
                return nil
            }
        }
        return line[index...].firstIndex(where: { $0 != " " })
    }

    static func permissionBits(_ s: String) -> Int? {
        let chars = Array(s.dropFirst().prefix(9))
        guard chars.count == 9 else { return nil }
        var bits = 0
        for (i, c) in chars.enumerated() where c != "-" { bits |= 1 << (8 - i) }
        return bits
    }
}
