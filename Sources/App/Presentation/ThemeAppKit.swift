import AppKit
import UniformTypeIdentifiers

extension RGBColor {
    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    /// Converts any colour (e.g. from a colour well, possibly in another colour space) to sRGB.
    public init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.black
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(red: byte(c.redComponent), green: byte(c.greenComponent), blue: byte(c.blueComponent))
    }
}

/// A theme turned into ready-to-use NSColors, rebuilt only when the theme changes.
struct Palette {
    let text, directoryText, background, background2: NSColor
    let cursorBackground, cursorText: NSColor
    let activePathBackground, activePathText, inactivePathBackground, inactivePathText: NSColor
    let activeTabBackground, activeTabText: NSColor
    let headerBackground, headerText, chrome, chromeText, lines, markText: NSColor
    /// Marked text on the cursor bar: the mark colour, adjusted until it is readable on the bar.
    let markOnCursorText: NSColor
    /// Bevel shades derived from the window colour, for frames and buttons (never the panel line colour).
    let chromeLight, chromeShadow: NSColor
    /// Header gets a soft top-to-bottom gradient like the reference's column buttons.
    let headerGradient: NSGradient

    init(_ t: Theme) {
        text = t.text.nsColor
        directoryText = t.directoryText.nsColor
        background = t.background.nsColor
        background2 = t.background2.nsColor
        cursorBackground = t.cursorBackground.nsColor
        cursorText = t.cursorText.nsColor
        activePathBackground = t.activePathBackground.nsColor
        activePathText = t.activePathText.nsColor
        inactivePathBackground = t.inactivePathBackground.nsColor
        inactivePathText = t.inactivePathText.nsColor
        activeTabBackground = t.activeTabBackground.nsColor
        activeTabText = t.activeTabText.nsColor
        headerBackground = t.headerBackground.nsColor
        headerText = t.headerText.nsColor
        chrome = t.chrome.nsColor
        chromeText = t.chromeText.nsColor
        lines = t.lines.nsColor
        markText = t.markText.nsColor
        chromeLight = chrome.blended(withFraction: 0.6, of: .white) ?? chrome
        chromeShadow = chrome.blended(withFraction: 0.35, of: .black) ?? chrome
        markOnCursorText = t.markOnCursorText.nsColor
        let bottom = headerBackground.blended(withFraction: 0.12, of: .black) ?? headerBackground
        headerGradient = NSGradient(starting: headerBackground, ending: bottom) ?? NSGradient(colors: [headerBackground])!
    }
}

enum PanelFont {
    static let regular = NSFont.systemFont(ofSize: 13)
    /// Digits of equal width so sizes and dates line up in their columns.
    static let digits = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    /// Marked entries under the cursor bar are drawn bold, so the mark always shows.
    static let bold = NSFont.boldSystemFont(ofSize: 13)
    static let boldSmall = NSFont.boldSystemFont(ofSize: 12)
    static let boldDigits = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
}

/// System file icons, cached: per extension for files, per path for folders and bundles
/// (so special folders and apps get their own icons).
final class IconProvider {
    static let shared = IconProvider()

    private var byExtension: [String: NSImage] = [:]
    private let byPath = NSCache<NSString, NSImage>()
    private var parentIcons: [String: NSImage] = [:]

    init() {
        byPath.countLimit = 2000
    }

    func icon(for entry: FileEntry, tint: NSColor) -> NSImage {
        if entry.kind == .parent { return parentIcon(tint: tint) }
        return entry.kind == .directory ? directoryIcon(for: entry.url) : fileIcon(for: entry.name)
    }

    private func directoryIcon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = byPath.object(forKey: key) { return cached }
        let exists = FileManager.default.fileExists(atPath: url.path)
        let image = exists ? NSWorkspace.shared.icon(forFile: url.path) : NSWorkspace.shared.icon(for: .folder)
        byPath.setObject(image, forKey: key)
        return image
    }

    private func fileIcon(for name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if let cached = byExtension[ext] { return cached }
        let image = resolveFileIcon(forExtension: ext)
        byExtension[ext] = image
        return image
    }

    private func resolveFileIcon(forExtension ext: String) -> NSImage {
        let type = ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }

    /// The up-arrow shown on the ".." row, drawn in the row's text colour.
    private func parentIcon(tint: NSColor) -> NSImage {
        let key = RGBColor(tint).hex
        if let cached = parentIcons[key] { return cached }
        let symbol = NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "Parent folder")
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            symbol.draw(in: rect.insetBy(dx: 1, dy: 1))
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        parentIcons[key] = image
        return image
    }
}
