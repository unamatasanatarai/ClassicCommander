import Foundation

/// An sRGB colour stored as "#RRGGBB", so themes are readable in defaults and diff-able.
public struct RGBColor: Equatable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Accepts "#RRGGBB" or "RRGGBB".
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: UInt8(v >> 16 & 0xFF), green: UInt8(v >> 8 & 0xFF), blue: UInt8(v & 0xFF))
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// WCAG relative luminance, 0 (black) … 1 (white).
    public var luminance: Double {
        func channel(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// This colour, darkened (on light backgrounds) or lightened (on dark ones) just enough to reach
    /// `minimum` contrast against `background`, keeping its hue.
    public func readable(on background: RGBColor, minimum: Double = 3) -> RGBColor {
        let target: Double = background.luminance > 0.5 ? 0 : 255
        var step = 0.0
        var color = self
        while color.contrast(with: background) < minimum && step < 1 {
            step += 0.05
            func mix(_ v: UInt8) -> UInt8 { UInt8((Double(v) * (1 - step) + target * step).rounded()) }
            color = RGBColor(red: mix(red), green: mix(green), blue: mix(blue))
        }
        return color
    }

    /// WCAG contrast ratio between two colours, 1 … 21.
    public func contrast(with other: RGBColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = RGBColor(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad colour \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

/// Every colour the panels use. Each one is editable on the Options → Color page.
public enum ThemeSlot: String, CaseIterable {
    case text, directoryText, background, background2
    case cursorBackground, cursorText
    case activePathBackground, activePathText, inactivePathBackground, inactivePathText
    case activeTabBackground, activeTabText
    case headerBackground, headerText
    case chrome, chromeText, lines
    case markText, markOnCursorText

    public var label: String {
        switch self {
        case .text: return "Text"
        case .directoryText: return "Folder text"
        case .background: return "Background"
        case .background2: return "Background 2 (alternate rows)"
        case .cursorBackground: return "Cursor"
        case .cursorText: return "Cursor text"
        case .activePathBackground: return "Active path bar"
        case .activePathText: return "Active path text"
        case .inactivePathBackground: return "Inactive path bar"
        case .inactivePathText: return "Inactive path text"
        case .activeTabBackground: return "Active tab"
        case .activeTabText: return "Active tab text"
        case .headerBackground: return "Column headers"
        case .headerText: return "Column header text"
        case .chrome: return "Window / status bars"
        case .chromeText: return "Status bar text"
        case .lines: return "Lines and borders"
        case .markText: return "Marked (selected) text"
        case .markOnCursorText: return "Marked text on cursor"
        }
    }
}

public struct Theme: Equatable {
    public var text: RGBColor
    public var directoryText: RGBColor
    public var background: RGBColor
    public var background2: RGBColor
    public var cursorBackground: RGBColor
    public var cursorText: RGBColor
    public var activePathBackground: RGBColor
    public var activePathText: RGBColor
    public var inactivePathBackground: RGBColor
    public var inactivePathText: RGBColor
    public var activeTabBackground: RGBColor
    public var activeTabText: RGBColor
    public var headerBackground: RGBColor
    public var headerText: RGBColor
    public var chrome: RGBColor
    public var chromeText: RGBColor
    public var lines: RGBColor
    public var markText: RGBColor
    public var markOnCursorText: RGBColor

    public subscript(slot: ThemeSlot) -> RGBColor {
        get {
            switch slot {
            case .text: return text
            case .directoryText: return directoryText
            case .background: return background
            case .background2: return background2
            case .cursorBackground: return cursorBackground
            case .cursorText: return cursorText
            case .activePathBackground: return activePathBackground
            case .activePathText: return activePathText
            case .inactivePathBackground: return inactivePathBackground
            case .inactivePathText: return inactivePathText
            case .activeTabBackground: return activeTabBackground
            case .activeTabText: return activeTabText
            case .headerBackground: return headerBackground
            case .headerText: return headerText
            case .chrome: return chrome
            case .chromeText: return chromeText
            case .lines: return lines
            case .markText: return markText
            case .markOnCursorText: return markOnCursorText
            }
        }
        set {
            switch slot {
            case .text: text = newValue
            case .directoryText: directoryText = newValue
            case .background: background = newValue
            case .background2: background2 = newValue
            case .cursorBackground: cursorBackground = newValue
            case .cursorText: cursorText = newValue
            case .activePathBackground: activePathBackground = newValue
            case .activePathText: activePathText = newValue
            case .inactivePathBackground: inactivePathBackground = newValue
            case .inactivePathText: inactivePathText = newValue
            case .activeTabBackground: activeTabBackground = newValue
            case .activeTabText: activeTabText = newValue
            case .headerBackground: headerBackground = newValue
            case .headerText: headerText = newValue
            case .chrome: chrome = newValue
            case .chromeText: chromeText = newValue
            case .lines: lines = newValue
            case .markText: markText = newValue
            case .markOnCursorText: markOnCursorText = newValue
            }
        }
    }

    /// Builds a theme from "#RRGGBB" strings; used for the built-in presets.
    static func make(_ colors: [ThemeSlot: String]) -> Theme {
        func c(_ slot: ThemeSlot) -> RGBColor { RGBColor(hex: colors[slot]!)! }
        return Theme(text: c(.text), directoryText: c(.directoryText), background: c(.background),
                     background2: c(.background2), cursorBackground: c(.cursorBackground),
                     cursorText: c(.cursorText), activePathBackground: c(.activePathBackground),
                     activePathText: c(.activePathText), inactivePathBackground: c(.inactivePathBackground),
                     inactivePathText: c(.inactivePathText),
                     activeTabBackground: c(.activeTabBackground), activeTabText: c(.activeTabText),
                     headerBackground: c(.headerBackground),
                     headerText: c(.headerText), chrome: c(.chrome), chromeText: c(.chromeText),
                     lines: c(.lines), markText: c(.markText),
                     markOnCursorText: colors[.markOnCursorText].flatMap(RGBColor.init(hex:)) ?? c(.markText).readable(on: c(.cursorBackground)))
    }

    /// Total Commander's default look: white panels, grey chrome, light cursor bar with navy text.
    public static let totalCommander = make([
        .text: "#000000", .directoryText: "#000000",
        .background: "#FFFFFF", .background2: "#FFFFFF",
        .cursorBackground: "#D6D7DC", .cursorText: "#071C95",
        .activePathBackground: "#C8C8C8", .activePathText: "#000000",
        .inactivePathBackground: "#FFFFFF", .inactivePathText: "#A8A8A8",
        .activeTabBackground: "#FFFFFF", .activeTabText: "#000000",
        .headerBackground: "#EEF0F3", .headerText: "#000000",
        .chrome: "#E4E4EA", .chromeText: "#000000", .lines: "#AAABBC",
        .markText: "#FF0000", .markOnCursorText: "#FF0000",
    ])

    /// Blue panels with white text and a white cursor bar. The default theme
    /// (a copy is kept in docs/themes/classic-blue.json, importable in Options).
    public static let classicBlue = make([
        .text: "#FFFFFF", .directoryText: "#FFFFFF",
        .background: "#0000A8", .background2: "#0000A8",
        .cursorBackground: "#FFFFFF", .cursorText: "#000000",
        .activePathBackground: "#00A8A8", .activePathText: "#000000",
        .inactivePathBackground: "#0000A8", .inactivePathText: "#FFFFFF",
        .activeTabBackground: "#FFFFFF", .activeTabText: "#000000",
        // Total Commander keeps the Windows header control: light grey, black text, whatever the panel colours.
        .headerBackground: "#F4F4F4", .headerText: "#000000",
        .chrome: "#D4D0C8", .chromeText: "#000000", .lines: "#55FFFF",
        .markText: "#FFFF55",
    ])

    /// The earlier default: Classic Blue with a cyan cursor bar.
    public static let classicBlueCyan: Theme = {
        var t = classicBlue
        t.cursorBackground = RGBColor(hex: "#00A8A8")!
        return t
    }()

    public static let standard: Theme = .classicBlue
}

/// Stored as {"text": "#FFFFFF", ...}. Colours missing from saved data (e.g. slots added in a
/// later version) take the default theme's value, so an upgrade never throws away a custom theme.
extension Theme: Codable {
    struct SlotKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SlotKey.self)
        var theme = Theme.standard
        for slot in ThemeSlot.allCases {
            if let color = try container.decodeIfPresent(RGBColor.self, forKey: SlotKey(stringValue: slot.rawValue)) {
                theme[slot] = color
            }
        }
        self = theme
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SlotKey.self)
        for slot in ThemeSlot.allCases {
            try container.encode(self[slot], forKey: SlotKey(stringValue: slot.rawValue))
        }
    }
}

extension Theme {
    public static let presets: [(name: String, theme: Theme)] = [
        ("Classic Blue", .classicBlue),
        ("Classic Blue (cyan cursor)", .classicBlueCyan),
        ("Total Commander", .totalCommander),
    ]
}
