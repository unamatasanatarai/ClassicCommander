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
    case accent

    private static let labels: [ThemeSlot: String] = [
        .text: "Text",
        .directoryText: "Folder text",
        .background: "Background",
        .background2: "Background 2 (alternate rows)",
        .cursorBackground: "Cursor",
        .cursorText: "Cursor text",
        .activePathBackground: "Active path bar",
        .activePathText: "Active path text",
        .inactivePathBackground: "Inactive path bar",
        .inactivePathText: "Inactive path text",
        .activeTabBackground: "Active tab",
        .activeTabText: "Active tab text",
        .headerBackground: "Column headers",
        .headerText: "Column header text",
        .chrome: "Window / status bars",
        .chromeText: "Status bar text",
        .lines: "Lines and borders",
        .markText: "Marked (selected) text",
        .markOnCursorText: "Marked text on cursor",
        .accent: "Accent (buttons, inputs)",
    ]

    public var label: String { Self.labels[self] ?? rawValue }
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
    public var accent: RGBColor

    private static let slotKeyPaths: [ThemeSlot: WritableKeyPath<Theme, RGBColor>] = [
        .text: \.text,
        .directoryText: \.directoryText,
        .background: \.background,
        .background2: \.background2,
        .cursorBackground: \.cursorBackground,
        .cursorText: \.cursorText,
        .activePathBackground: \.activePathBackground,
        .activePathText: \.activePathText,
        .inactivePathBackground: \.inactivePathBackground,
        .inactivePathText: \.inactivePathText,
        .activeTabBackground: \.activeTabBackground,
        .activeTabText: \.activeTabText,
        .headerBackground: \.headerBackground,
        .headerText: \.headerText,
        .chrome: \.chrome,
        .chromeText: \.chromeText,
        .lines: \.lines,
        .markText: \.markText,
        .markOnCursorText: \.markOnCursorText,
        .accent: \.accent,
    ]

    public subscript(slot: ThemeSlot) -> RGBColor {
        get { self[keyPath: Self.slotKeyPaths[slot]!] }
        set { self[keyPath: Self.slotKeyPaths[slot]!] = newValue }
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
                     markOnCursorText: colors[.markOnCursorText].flatMap(RGBColor.init(hex:)) ?? c(.markText).readable(on: c(.cursorBackground)),
                     accent: colors[.accent].flatMap(RGBColor.init(hex:)) ?? RGBColor(hex: "#0A63E0")!)
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
