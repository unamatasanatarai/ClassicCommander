import AppKit

/// What every ClassicCommander window shares: titles that start with the app name (so window
/// managers such as yabai can match them, see docs/yabai.md), and the colour scheme of the main window.
enum AppWindows {
    /// Between the app name and a window's own name: "ClassicCommander - Find Files".
    static let separator = " - "

    /// The main window's title; every other window starts with it and `separator`.
    static var appTitle: String { AppConfig.appName }

    /// "ClassicCommander - <name>".
    static func title(_ name: String) -> String { appTitle + separator + name }

    /// The window colour of the current theme (Options → Color, "Window / status bars").
    private(set) static var chrome: NSColor = Theme.standard.chrome.nsColor

    /// Light or dark controls, whichever reads on the theme's window colour (the panels draw their own colours).
    static func appearance(for theme: Theme) -> NSAppearance? {
        NSAppearance(named: theme.chrome.luminance > 0.4 ? .aqua : .darkAqua)
    }

    /// Makes every window, dialog, menu and alert follow `theme`, now and when opened later.
    static func apply(_ theme: Theme) {
        chrome = theme.chrome.nsColor
        NSApp.appearance = appearance(for: theme)
        styleButtonsWhenShown()
        for window in NSApp.windows where window.title.hasPrefix(appTitle) {
            style(window)
        }
    }

    /// The commander window; other windows open centred on it.
    static weak var mainWindow: NSWindow?

    /// Centres a window that is about to open on the main window, moved (and shrunk) as needed
    /// to fit on that screen. Windows already on screen stay where they are.
    static func place(_ window: NSWindow) {
        guard !window.isVisible else { return }
        styleButtons(in: window)
        let main = mainWindow?.isVisible == true ? mainWindow : nil
        let screen = (main?.screen ?? NSScreen.main)?.visibleFrame
        guard let anchor = main?.frame ?? screen else { return }
        window.setFrame(centered(window.frame, on: anchor, within: screen), display: false)
    }

    /// `frame` centred on `anchor`, then kept inside `screen` (when given).
    static func centered(_ frame: NSRect, on anchor: NSRect, within screen: NSRect?) -> NSRect {
        var f = frame
        f.origin = NSPoint(x: (anchor.midX - f.width / 2).rounded(), y: (anchor.midY - f.height / 2).rounded())
        guard let s = screen else { return f }
        f.size = NSSize(width: min(f.width, s.width), height: min(f.height, s.height))
        f.origin.x = min(max(f.origin.x, s.minX), s.maxX - f.width)
        f.origin.y = min(max(f.origin.y, s.minY), s.maxY - f.height)
        return f
    }

    /// Gives a window the theme's window colour.
    static func style(_ window: NSWindow) {
        window.backgroundColor = chrome
    }

    // MARK: Buttons

    private static var keyObserver: NSObjectProtocol?

    /// Every window's buttons get the one button style (`styleButtons`) when the window becomes key,
    /// so windows built anywhere, and buttons added after they were built, all look the same.
    static func styleButtonsWhenShown() {
        guard keyObserver == nil else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                             queue: .main) { note in
            if let window = note.object as? NSWindow { styleButtons(in: window) }
        }
    }

    static func styleButtons(in window: NSWindow) {
        if let root = window.contentView?.superview ?? window.contentView { styleButtons(in: root) }
    }

    /// One look for every push button (as in Connect to FTP server): rounded, regular size, the
    /// regular system font. Buttons in the same stack, or the same grid column, are as wide as the
    /// widest of them. Checkboxes, radio buttons, pop-ups and borderless buttons are left alone;
    /// hidden views and the pages of tab views are included. Running it again changes nothing.
    static func styleButtons(in root: NSView) {
        var groups: [ObjectIdentifier: [NSButton]] = [:]
        var order: [ObjectIdentifier] = []
        func visit(_ view: NSView) {
            if let button = view as? NSButton, isPushButton(button) {
                stylePushButton(button)
                if let key = groupKey(of: button) {
                    if groups[key] == nil { order.append(key) }
                    groups[key, default: []].append(button)
                }
            }
            view.subviews.forEach(visit)
            if let tabs = view as? NSTabView {
                for item in tabs.tabViewItems { if let page = item.view, page.superview == nil { visit(page) } }
            }
        }
        visit(root)
        for key in order { equalizeWidths(groups[key] ?? []) }
    }

    /// Push buttons are bordered: checkboxes and radio buttons are not (pop-ups are NSButtons too).
    static func isPushButton(_ button: NSButton) -> Bool {
        button.isBordered && !(button is NSPopUpButton)
    }

    static func stylePushButton(_ button: NSButton) {
        if button.bezelStyle != .regularSquare && button.bezelStyle != .recessed {
            button.bezelStyle = .rounded
        }
        button.controlSize = .regular
        // Titles drawn in their own colours (Synchronize's arrows) keep them.
        let title = button.attributedTitle
        let colour = title.length > 0 ? title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
        let coloured = colour.map { $0 != .controlTextColor } ?? false
        if !coloured { button.font = .systemFont(ofSize: NSFont.systemFontSize) }
    }

    /// Buttons side by side: the arranged views of one stack, or one column of a grid.
    static func groupKey(of button: NSButton) -> ObjectIdentifier? {
        if let stack = button.superview as? NSStackView, stack.arrangedSubviews.contains(button) {
            return ObjectIdentifier(stack)
        }
        if let grid = button.superview as? NSGridView, let column = grid.cell(for: button)?.column {
            return ObjectIdentifier(column)
        }
        return nil
    }

    static let equalWidthID = "AppWindows.equalWidth"

    /// At least as wide as the widest button of the group (below required: fixed widths win).
    static func equalizeWidths(_ buttons: [NSButton]) {
        let titled = buttons.filter { !$0.title.isEmpty }
        guard titled.count > 1 else { return }
        let width = titled.map(\.intrinsicContentSize.width).max() ?? 0
        for button in titled {
            if let old = button.constraints.first(where: { $0.identifier == equalWidthID }) {
                old.constant = width
                continue
            }
            let c = button.widthAnchor.constraint(greaterThanOrEqualToConstant: width)
            c.priority = NSLayoutConstraint.Priority(999)
            c.identifier = equalWidthID
            c.isActive = true
        }
    }

    // MARK: - Tab Navigation & Key View Order

    /// Sets a closed-loop tab key view navigation sequence for `views` in `window`.
    static func setTabOrder(_ views: [NSView], in window: NSWindow) {
        let validViews = views.filter { !$0.isHidden }
        guard !validViews.isEmpty else { return }
        window.autorecalculatesKeyViewLoop = false
        for i in 0..<(validViews.count - 1) {
            validViews[i].nextKeyView = validViews[i + 1]
        }
        validViews.last?.nextKeyView = validViews.first
        if window.initialFirstResponder == nil || window.initialFirstResponder === window.contentView {
            window.initialFirstResponder = validViews.first
        }
    }
}
