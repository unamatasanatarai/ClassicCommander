import AppKit

/// The button bar under the panels: "3 View | 5 Copy | 6 Move | 7 NewFolder | 8 Delete".
/// Each button shows the first key bound to its action, so it follows Options → Shortcuts.
public final class FunctionKeyBar: NSView {
    public static let actions: [CommandAction] = [.view, .copy, .move, .newFolder, .delete]
    public static let height: CGFloat = 24

    public var theme: Theme = .standard { didSet { needsDisplay = true } }
    /// The buttons shown (the standard ones, plus "FTP Disconnect" while connected).
    public var shownActions: [CommandAction] = FunctionKeyBar.actions { didSet { needsDisplay = true } }
    public var keys: KeyBindings = .standard { didSet { needsDisplay = true } }
    public var onAction: ((CommandAction) -> Void)?
    private var pressed: Int?

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public func title(for action: CommandAction) -> String {
        guard let key = keys.keys(for: action).first else { return action.buttonTitle }
        return "\(key.displayName) \(action.buttonTitle)"
    }

    private func buttonRect(_ index: Int) -> NSRect {
        let count = CGFloat(shownActions.count)
        let width = floor(bounds.width / count)
        let x = CGFloat(index) * width
        let w = index == shownActions.count - 1 ? bounds.width - x : width
        return NSRect(x: x, y: 0, width: w, height: bounds.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let chrome = theme.chrome.nsColor
        chrome.setFill()
        bounds.fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.chromeText.nsColor, .paragraphStyle: style,
        ]
        for (i, action) in shownActions.enumerated() {
            let rect = buttonRect(i).insetBy(dx: 2, dy: 2)
            // Classic raised button in the window grey; pressed buttons look sunken.
            let light = chrome.blended(withFraction: 0.6, of: .white) ?? chrome
            let shadow = chrome.blended(withFraction: 0.35, of: .black) ?? chrome
            let isDown = pressed == i
            (isDown ? shadow : light).setFill()
            rect.fill()
            (isDown ? light : shadow).setFill()
            NSRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width - 1, height: rect.height - 1).fill()
            chrome.setFill()
            rect.insetBy(dx: 1, dy: 1).fill()
            let font = NSFont.systemFont(ofSize: 13)
            let h = ceil(font.ascender - font.descender)
            let textRect = NSRect(x: rect.minX + 4, y: rect.minY + floor((rect.height - h) / 2), width: rect.width - 8, height: h)
            (title(for: action) as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return shownActions.indices.first { buttonRect($0).contains(p) }
    }

    public override func mouseDown(with event: NSEvent) {
        pressed = index(at: event)
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; needsDisplay = true }
        guard let i = index(at: event), i == pressed else { return }
        onAction?(shownActions[i])
    }
}
