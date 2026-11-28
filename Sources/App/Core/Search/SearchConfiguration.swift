import Foundation

// Find Files (⌥7): the dialog's settings, independent of the UI. Every filter keeps its values
// while switched off (`enabled == false`), so toggling a checkbox or switching tabs loses nothing.

public struct FileSearchConfiguration: Codable, Equatable {
    public var general = GeneralSearchConfiguration()
    public var advanced = AdvancedSearchConfiguration()
    public init() {}
}

public enum SubdirectoryDepth: Codable, Equatable {
    /// Recursive, no limit.
    case all
    /// Only the items directly inside each starting folder.
    case currentOnly
    /// The starting folder plus this many levels of subfolders.
    case limited(Int)
}

public struct GeneralSearchConfiguration: Codable, Equatable {
    /// Wildcard masks ("*.txt;*.doc | temp*") or, with `useRegex`, a regular expression.
    public var filenamePattern = "*"
    /// Starting folders as typed, separated by ";" in the field.
    public var searchPaths: [String] = []
    public var useRegex = false
    public var depth: SubdirectoryDepth = .all
    public var selectedItemsOnly = false
    public var content = ContentSearchConfiguration()
    public init() {}
}

/// The charset checkboxes of Total Commander's "Find text". Several can be ticked; a file
/// matches when the text is found in any of them.
public enum ContentCharset: String, Codable, CaseIterable {
    /// The Windows code page of the user's language (Windows-1250 for Polish, Czech …).
    case ansi
    /// The DOS code page of the user's language (CP852 for Central Europe, CP437 otherwise).
    case ascii
    /// Unicode UTF-16 little endian (Windows' "Unicode").
    case utf16
    case utf8
    /// Text inside Office Open XML / OpenDocument files (docx, xlsx, pptx, odt, ods, odp).
    case officeXML

    public var label: String {
        switch self {
        case .ansi: return "ANSI charset (\(Self.ansiName))"
        case .ascii: return "ASCII charset (DOS, \(Self.dosName))"
        case .utf16: return "Unicode UTF16"
        case .utf8: return "UTF8"
        case .officeXML: return "Office xml (docx, xlsx, odt…)"
        }
    }

    static var language: String { Locale.current.languageCode ?? "en" }

    private static let languageCodePages: [String: UInt32] = [
        "pl": 1250, "cs": 1250, "sk": 1250, "hu": 1250, "sl": 1250, "hr": 1250, "ro": 1250, "sq": 1250, "bs": 1250,
        "ru": 1251, "uk": 1251, "bg": 1251, "sr": 1251, "be": 1251, "mk": 1251,
        "el": 1253,
        "tr": 1254,
    ]

    static var ansiCodePage: UInt32 { languageCodePages[language] ?? 1252 }

    static var ansiName: String { "Windows-\(ansiCodePage)" }

    static var dosName: String {
        switch ansiCodePage {
        case 1250: return "CP852"
        case 1251: return "CP866"
        default: return "CP437"
        }
    }

    private static let ansiEncodings: [UInt32: String.Encoding] = [
        1250: .windowsCP1250,
        1251: .windowsCP1251,
        1253: .windowsCP1253,
        1254: .windowsCP1254,
    ]

    private static let dosEncodings: [String: CFStringEncodings] = [
        "CP852": .dosLatin2,
        "CP866": .dosRussian,
    ]

    private static let fixedStringEncodings: [ContentCharset: String.Encoding] = [
        .utf16: .utf16LittleEndian,
        .utf8: .utf8,
    ]

    /// The String.Encoding used to decode bytes; nil for Office xml, which is unpacked instead.
    public var stringEncoding: String.Encoding? {
        if let fixed = Self.fixedStringEncodings[self] { return fixed }
        if self == .ansi { return Self.ansiEncodings[Self.ansiCodePage] ?? .windowsCP1252 }
        if self == .ascii {
            let cfEncoding = Self.dosEncodings[Self.dosName] ?? .dosLatinUS
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding.rawValue)))
        }
        return nil
    }
}

public struct ContentSearchConfiguration: Codable, Equatable {
    public var enabled = false
    public var expression = ""
    public var caseSensitive = false
    public var wholeWordsOnly = false
    public var useRegex = false
    /// The expression is hex bytes ("4D 5A 90"); binary files are searched only in this mode.
    public var hexadecimal = false
    /// Find files that do NOT contain the expression.
    public var invertMatch = false
    /// Mac files are mostly UTF-8, so UTF8 is ticked by default next to Total Commander's ANSI.
    public var charsets: [ContentCharset] = [.ansi, .utf8]
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        enabled = opt(.enabled, false)
        expression = opt(.expression, "")
        caseSensitive = opt(.caseSensitive, false)
        wholeWordsOnly = opt(.wholeWordsOnly, false)
        useRegex = opt(.useRegex, false)
        hexadecimal = opt(.hexadecimal, false)
        invertMatch = opt(.invertMatch, false)
        charsets = opt(.charsets, [.ansi, .utf8])
    }
}

public enum AgeUnit: String, Codable, CaseIterable {
    case days, weeks, months, years
    public var label: String { "\(rawValue.dropLast())(s)" }
    var component: Calendar.Component {
        switch self {
        case .days: return .day
        case .weeks: return .weekOfYear
        case .months: return .month
        case .years: return .year
        }
    }
}

public struct AgeFilter: Codable, Equatable {
    public var enabled = false
    public var value = 1
    public var unit: AgeUnit = .days
    public init(enabled: Bool = false, value: Int = 1, unit: AgeUnit = .days) {
        self.enabled = enabled
        self.value = value
        self.unit = unit
    }
}

public enum ComparisonOperator: String, Codable, CaseIterable {
    case equal = "=", notEqual = "<>", less = "<", greater = ">", lessOrEqual = "<=", greaterOrEqual = ">="

    private static let comparators: [ComparisonOperator: (Int64, Int64) -> Bool] = [
        .equal: (==),
        .notEqual: (!=),
        .less: (<),
        .greater: (>),
        .lessOrEqual: (<=),
        .greaterOrEqual: (>=),
    ]

    func compare(_ a: Int64, _ b: Int64) -> Bool {
        Self.comparators[self]?(a, b) ?? false
    }
}

public enum SizeUnit: String, Codable, CaseIterable {
    case bytes, kilobytes, megabytes, gigabytes
    public var label: String {
        switch self {
        case .bytes: return "bytes"
        case .kilobytes: return "kbytes"
        case .megabytes: return "Mbytes"
        case .gigabytes: return "Gbytes"
        }
    }
    public var multiplier: Double {
        switch self {
        case .bytes: return 1
        case .kilobytes: return 1024
        case .megabytes: return 1024 * 1024
        case .gigabytes: return 1024 * 1024 * 1024
        }
    }
}

public struct SizeFilter: Codable, Equatable {
    public var enabled = false
    public var comparison: ComparisonOperator = .greater
    /// As typed; may have decimals ("1.5" MB).
    public var value: Double = 1
    public var unit: SizeUnit = .kilobytes
    public init(enabled: Bool = false, comparison: ComparisonOperator = .greater, value: Double = 1, unit: SizeUnit = .kilobytes) {
        self.enabled = enabled
        self.comparison = comparison
        self.value = value
        self.unit = unit
    }
    /// The threshold in bytes; all comparisons are made in bytes.
    public var bytes: Int64 { Int64((value * unit.multiplier).rounded()) }
}

/// File attributes as Total Commander names them, mapped onto what macOS has.
public enum FileAttribute: String, Codable, CaseIterable {
    case archive, hidden, system, readOnly, directory, compressed, encrypted

    private static let labels: [FileAttribute: String] = [
        .archive: "Archive",
        .hidden: "Hidden",
        .system: "System",
        .readOnly: "Read only",
        .directory: "Directory",
        .compressed: "Compressed",
        .encrypted: "Encrypted",
    ]

    private static let meanings: [FileAttribute: String] = [
        .archive: "The \"archived\" file flag (SF_ARCHIVED).",
        .hidden: "Name starts with a dot, or the hidden flag is set (chflags hidden).",
        .system: "Owned by root, or protected by the system (restricted/immutable flags).",
        .readOnly: "The owner may not write it, or it is locked (chflags uchg).",
        .directory: "A folder.",
        .compressed: "Stored compressed by the file system (UF_COMPRESSED).",
        .encrypted: "Not available on macOS: encryption is per volume (FileVault), not per file.",
    ]

    public var label: String { Self.labels[self] ?? "" }

    /// What the attribute means on macOS (shown as a tooltip).
    public var macMeaning: String { Self.meanings[self] ?? "" }

    /// Encrypted has no per-file meaning on macOS and cannot be used.
    public var isAvailable: Bool { self != .encrypted }
}

/// Three-state attribute choice: ignore it, require it, or exclude it.
public enum TriState: String, Codable, Equatable {
    case ignored, required, excluded
}

public struct DuplicateSearchConfiguration: Codable, Equatable {
    public var enabled = false
    public var sameName = true
    public var sameSize = true
    public var sameContents = false
    public init(enabled: Bool = false, sameName: Bool = true, sameSize: Bool = true, sameContents: Bool = false) {
        self.enabled = enabled
        self.sameName = sameName
        self.sameSize = sameSize
        self.sameContents = sameContents
    }
}

public struct AdvancedSearchConfiguration: Codable, Equatable {
    public var dateBetweenEnabled = false
    public var dateFrom: Date?
    public var dateTo: Date?
    public var notOlderThan = AgeFilter()
    public var olderThan = AgeFilter()
    public var fileSize = SizeFilter()
    public var attributesEnabled = false
    public var attributes: [FileAttribute: TriState] = [:]
    public var duplicates = DuplicateSearchConfiguration()
    public init() {}

    public func state(of attribute: FileAttribute) -> TriState {
        attributes[attribute] ?? .ignored
    }
}

public struct SearchValidationError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

extension FileSearchConfiguration {
    /// Splits the "Search in" text into folders: ";"-separated, "~" expanded, empty parts dropped.
    public static func parsePaths(_ text: String) -> [String] {
        text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
