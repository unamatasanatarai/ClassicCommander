import AppKit

/// The tabs above a panel: click switches, middle-click closes, double-click on the empty part
/// opens a new tab. Drawn in the theme's colours, the active tab like the active path bar.
final class TabBarView: NSView {
    static let height: CGFloat = 22

    var tabs = PanelTabs(folder: URL(fileURLWithPath: "/")) { didSet { needsDisplay = true } }
    var theme: Theme = .standard { didSet { needsDisplay = true } }
    /// The panel next to it is the active one (its active tab is drawn highlighted then).
    var isActive = false { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where each tab is drawn.
    var tabRects: [NSRect] {
        var x: CGFloat = 2
        return tabs.tabs.map { tab in
            let width = min(180, max(60, ceil((tab.title as NSString).size(withAttributes: [.font: PanelFont.regular]).width) + 20))
            defer { x += width + 2 }
            return NSRect(x: x, y: 2, width: width, height: bounds.height - 2)
        }
    }

    func tab(at point: NSPoint) -> Int? { tabRects.firstIndex { $0.contains(point) } }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette(theme)
        palette.chrome.setFill()
        bounds.fill()
        for (i, rect) in tabRects.enumerated() {
            let active = i == tabs.active
            let background = active ? (isActive ? palette.activePathBackground : palette.chromeLight) : palette.chrome
            background.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            palette.chromeShadow.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
            let color = active && isActive ? palette.activePathText : palette.chromeText
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingMiddle
            let title = EntryFormatter.visible(tabs.tabs[i].title) as NSString
            let font = active ? PanelFont.bold : PanelFont.regular
            let textHeight = ceil(font.ascender - font.descender)
            title.draw(in: NSRect(x: rect.minX + 6, y: rect.midY - textHeight / 2, width: rect.width - 12, height: textHeight),
                       withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let i = tab(at: point) {
            onSelect?(i)
        } else if event.clickCount == 2 {
            onNew?()
        }
    }

    /// Middle-click closes the tab under the mouse.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        middleClick(at: convert(event.locationInWindow, from: nil))
    }

    func middleClick(at point: NSPoint) {
        if let i = tab(at: point) { onClose?(i) }
    }
}
