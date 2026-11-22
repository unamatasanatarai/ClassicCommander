import Foundation

/// One entry of a remote directory listing.
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
        let lines = text.components(separatedBy: CharacterSet(charactersIn: "\r\n")).filter { !$0.isEmpty }
        return lines.compactMap { line -> RemoteEntry? in
            switch type {
            case .mlsd: return parseMLSD(line)
            case .unixList: return parseUnix(line, now: now)
            case .dosList: return parseDOS(line)
            case .automatic: return parseMLSD(line) ?? parseUnix(line, now: now) ?? parseDOS(line)
            }
        }
        .filter { isSafeName($0.name) }
    }

    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.count <= 1024 else { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0.value < 0x20 || $0.value == 0x7F }
    }

    // "type=file;size=1234;modify=20261121120000;UNIX.mode=0644; index.html"
    static func parseMLSD(_ line: String) -> RemoteEntry? {
        guard let space = line.firstIndex(of: " "), line[..<space].contains("=") else { return nil }
        let name = String(line[line.index(after: space)...])
        var facts: [String: String] = [:]
        for fact in line[..<space].split(separator: ";") {
            let kv = fact.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { facts[kv[0].lowercased()] = kv[1] }
        }
        guard let type = facts["type"]?.lowercased() else { return nil }
        if type == "cdir" || type == "pdir" { return nil }
        let isDir = type == "dir"
        let isLink = type.hasPrefix("os.unix=slink") || type.contains("slink")
        var modified: Date?
        if let m = facts["modify"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMddHHmmss"
            modified = f.date(from: String(m.prefix(14)))
        }
        let perms = facts["unix.mode"].flatMap { Int($0, radix: 8) }
        return RemoteEntry(name: name, isDirectory: isDir, isLink: isLink,
                           size: isDir ? 0 : Int64(facts["size"] ?? "") ?? 0, modified: modified, permissions: perms)
    }

    // "-rw-r--r--   1 owner group     8192 Nov 21 12:00 index.html"
    // "drwxr-xr-x   2 owner group     4096 Mar  3  2025 assets"
    // "lrwxrwxrwx   1 owner group        7 Nov 21 12:00 current -> release"
    static func parseUnix(_ line: String, now: Date) -> RemoteEntry? {
        let first = line.first
        guard let kind = first, "-dlbcps".contains(kind) else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 9, fields[0].count >= 10 else { return nil }
        // Find the month: the size is the number just before it (owner/group may be missing).
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let mi = fields.indices.dropFirst(2).first(where: { months.contains(fields[$0].lowercased()) && $0 + 2 < fields.count }),
              let month = months.firstIndex(of: fields[mi].lowercased()),
              let day = Int(fields[mi + 1]),
              let size = Int64(fields[mi - 1]) else { return nil }
        let yearOrTime = fields[mi + 2]
        var comps = DateComponents()
        comps.month = month + 1
        comps.day = day
        let utc = Calendar(identifier: .gregorian)
        if yearOrTime.contains(":") {
            let hm = yearOrTime.split(separator: ":")
            comps.hour = Int(hm[0]); comps.minute = hm.count > 1 ? Int(hm[1]) : 0
            // No year: the most recent such date not in the future.
            let year = utc.component(.year, from: now)
            comps.year = year
            if let d = utc.date(from: comps), d > now.addingTimeInterval(86_400) { comps.year = year - 1 }
        } else {
            comps.year = Int(yearOrTime)
        }
        // The name is everything after the date/time field, keeping its own spaces.
        guard let nameStart = rangeAfterField(line, fieldIndex: mi + 2) else { return nil }
        var name = String(line[nameStart...])
        let isLink = kind == "l"
        if isLink, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        let perms = permissionBits(String(fields[0]))
        return RemoteEntry(name: name, isDirectory: kind == "d", isLink: isLink, size: kind == "d" ? 0 : size,
                           modified: utc.date(from: comps), permissions: perms,
                           datePrecision: yearOrTime.contains(":") ? 60 : 86_400)
    }

    // "11-21-26  12:00PM       <DIR>          assets"
    // "11-21-2026  09:15AM             8192 index.html"
    static func parseDOS(_ line: String) -> RemoteEntry? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4 else { return nil }
        let dateParts = fields[0].split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else { return nil }
        let time = fields[1].uppercased()
        guard time.hasSuffix("AM") || time.hasSuffix("PM") || time.contains(":") else { return nil }
        let hm = time.dropLast(time.hasSuffix("M") ? 2 : 0).split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { return nil }
        var hour = hm[0] % 12
        if time.hasSuffix("PM") { hour += 12 }
        if !time.hasSuffix("AM") && !time.hasSuffix("PM") { hour = hm[0] }
        var year = dateParts[2]
        if year < 100 { year += year < 70 ? 2000 : 1900 }
        let comps = DateComponents(year: year, month: dateParts[0], day: dateParts[1], hour: hour, minute: hm[1])
        let isDir = fields[2].uppercased() == "<DIR>"
        guard isDir || Int64(fields[2]) != nil, let nameStart = rangeAfterField(line, fieldIndex: 2) else { return nil }
        return RemoteEntry(name: String(line[nameStart...]), isDirectory: isDir, isLink: false,
                           size: isDir ? 0 : Int64(fields[2]) ?? 0,
                           modified: Calendar(identifier: .gregorian).date(from: comps), permissions: nil,
                           datePrecision: 60)
    }

    /// Where the text after field number `fieldIndex` (0-based, space separated) begins.
    private static func rangeAfterField(_ line: String, fieldIndex: Int) -> String.Index? {
        var index = line.startIndex
        var field = -1
        var inField = false
        while index < line.endIndex {
            let isSpace = line[index] == " "
            if !isSpace && !inField {
                field += 1
                inField = true
                if field == fieldIndex + 1 { return index }
            } else if isSpace {
                inField = false
            }
            index = line.index(after: index)
        }
        return nil
    }

    static func permissionBits(_ s: String) -> Int? {
        let chars = Array(s.dropFirst().prefix(9))
        guard chars.count == 9 else { return nil }
        var bits = 0
        for (i, c) in chars.enumerated() where c != "-" { bits |= 1 << (8 - i) }
        return bits
    }
}
