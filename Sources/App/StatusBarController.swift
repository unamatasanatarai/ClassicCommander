import Cocoa

public final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu!

    /// Callback invoked when user selects "Open Window"
    public var onOpenWindow: (() -> Void)?

    /// Callback invoked when user selects "Quit"
    public var onQuitRequested: (() -> Void)?

    /// The menu bar icon: the app's floppy disk as a monochrome template image (macOS tints it
    /// for light and dark menu bars). Body with the bevelled corner, the metal shutter and the
    /// label are cut out of a solid shape.
    public static let floppyIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let r = rect.insetBy(dx: 1.5, dy: 1.5)
            let bevel: CGFloat = 3
            let body = NSBezierPath()
            body.move(to: NSPoint(x: r.minX + 1.5, y: r.minY))
            body.line(to: NSPoint(x: r.maxX - 1.5, y: r.minY))
            body.curve(to: NSPoint(x: r.maxX, y: r.minY + 1.5), controlPoint1: NSPoint(x: r.maxX - 0.5, y: r.minY),
                       controlPoint2: NSPoint(x: r.maxX, y: r.minY + 0.5))
            body.line(to: NSPoint(x: r.maxX, y: r.maxY - bevel))
            body.line(to: NSPoint(x: r.maxX - bevel, y: r.maxY))
            body.line(to: NSPoint(x: r.minX + 1.5, y: r.maxY))
            body.curve(to: NSPoint(x: r.minX, y: r.maxY - 1.5), controlPoint1: NSPoint(x: r.minX + 0.5, y: r.maxY),
                       controlPoint2: NSPoint(x: r.minX, y: r.maxY - 0.5))
            body.line(to: NSPoint(x: r.minX, y: r.minY + 1.5))
            body.curve(to: NSPoint(x: r.minX + 1.5, y: r.minY), controlPoint1: NSPoint(x: r.minX, y: r.minY + 0.5),
                       controlPoint2: NSPoint(x: r.minX + 0.5, y: r.minY))
            body.close()
            NSColor.black.setFill()
            body.fill()

            ctx.saveGState()
            ctx.setBlendMode(.clear)
            // Shutter window (top centre) and label (bottom) are holes in the body.
            NSBezierPath(rect: NSRect(x: r.midX - 0.5, y: r.maxY - 4.5, width: 2.5, height: 3.5)).fill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + 2.5, y: r.minY + 1.5, width: r.width - 5, height: r.height * 0.45),
                         xRadius: 1, yRadius: 1).fill()
            ctx.restoreGState()
            // Two label lines, like the app icon.
            NSColor.black.setFill()
            for i in 0..<2 {
                NSRect(x: r.minX + 4, y: r.minY + 3 + CGFloat(i) * 2.5, width: r.width - 8, height: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static var badgeIcon: NSImage { floppyIcon }

    public override init() {
        super.init()
        setupStatusItem()
        setupMenu()
    }

    public var currentMenu: NSMenu {
        return menu
    }

    public var currentStatusItem: NSStatusItem? {
        return statusItem
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.toolTip = "\(AppConfig.appName) — Running"
            button.image = Self.badgeIcon
        }
        self.statusItem = item
    }

    public func updateIcon() {
        // Template image is automatically tinted by WindowServer; no dynamic redrawing needed.
        statusItem?.button?.image = Self.badgeIcon
    }

    public static func renderBadgeIcon(isDark: Bool) -> NSImage {
        // Maintained for backward compatibility
        return badgeIcon
    }

    public func setupMenu() {
        menu = NSMenu()

        let appItem = NSMenuItem(
            title: "\(AppConfig.appName) v\(AppConfig.version)",
            action: nil,
            keyEquivalent: ""
        )
        appItem.isEnabled = false
        menu.addItem(appItem)

        menu.addItem(NSMenuItem.separator())

        if onOpenWindow != nil {
            let openWindowItem = NSMenuItem(
                title: "Open Window",
                action: #selector(openWindowAction),
                keyEquivalent: "o"
            )
            openWindowItem.target = self
            menu.addItem(openWindowItem)
            menu.addItem(NSMenuItem.separator())
        }

        let quitItem = NSMenuItem(
            title: "Quit \(AppConfig.appName)",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    public func refreshMenu() {
        setupMenu()
    }

    public func cleanup() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func openWindowAction() {
        onOpenWindow?()
    }

    @objc private func quitAction() {
        if let onQuit = onQuitRequested {
            onQuit()
        } else {
            cleanup()
            Modal.terminate()   // NSApp.terminate ends the process
        }
    }
}
