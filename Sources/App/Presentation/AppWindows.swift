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
        // Use macOS Blue (4) for native system focus rings/controls app-wide.
        UserDefaults.standard.set(4, forKey: "AppleAccentColor")
        chrome = theme.chrome.nsColor
        accent = theme.accent.nsColor
        NSApp.appearance = appearance(for: theme)
        styleButtonsWhenShown()
        for window in NSApp.windows where window.title.hasPrefix(appTitle) {
            style(window)
            styleButtons(in: window)
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
        if let anchor = main?.frame ?? screen {
            window.setFrame(centered(window.frame, on: anchor, within: screen), display: false)
        }
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
    private static var buttonNavMonitor: Any?

    /// Every window's buttons get the one button style (`styleButtons`) when the window becomes key,
    /// so windows built anywhere, and buttons added after they were built, all look the same.
    static func styleButtonsWhenShown() {
        if keyObserver == nil {
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                                 queue: .main) { note in
                if let window = note.object as? NSWindow { styleButtons(in: window) }
            }
        }
        if buttonNavMonitor == nil {
            buttonNavMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard let window = event.window, window !== mainWindow else { return event }
                return handleButtonNav(event, in: window) ? nil : event
            }
        }
    }

    /// Moves focus between visible, enabled push buttons using Arrow keys
    /// whenever a button currently has focus (or no text/table control has focus).
    @discardableResult
    static func handleButtonNav(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard !isTextOrTableResponder(window.firstResponder),
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        let currentButton = (window.firstResponder as? NSButton).flatMap { isPushButton($0) ? $0 : nil }
        if triggerNonDefaultButton(currentButton, keyCode: event.keyCode) { return true }
        return navigateByArrow(keyCode: event.keyCode, from: currentButton, in: window)
    }

    private static func navigateByArrow(keyCode: UInt16, from current: NSButton?, in window: NSWindow) -> Bool {
        guard let direction = arrowDirection(for: keyCode) else { return false }
        if let current = current { return moveButtonFocus(from: current, in: window, direction: direction) }
        return focusInitialOrFirstButton(in: window)
    }

    private static func triggerNonDefaultButton(_ button: NSButton?, keyCode: UInt16) -> Bool {
        guard keyCode == 36, let current = button, current.keyEquivalent != "\r" else { return false }
        current.performClick(nil)
        return true
    }

    private static func isTextOrTableResponder(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextView || responder is NSTableView || responder is NSComboBox
    }

    private static func focusInitialOrFirstButton(in window: NSWindow) -> Bool {
        if let initial = window.initialFirstResponder as? NSButton, isPushButton(initial), initial.isEnabled {
            window.makeFirstResponder(initial)
            return true
        }
        if let root = window.contentView, let first = firstPushButton(in: root) {
            window.makeFirstResponder(first)
            return true
        }
        return false
    }

    private static let arrowDirections: [UInt16: (dx: CGFloat, dy: CGFloat)] = [
        123: (-1, 0), // Left
        124: (1, 0),  // Right
        125: (0, -1), // Down
        126: (0, 1),  // Up
    ]

    private static func arrowDirection(for keyCode: UInt16) -> (dx: CGFloat, dy: CGFloat)? {
        arrowDirections[keyCode]
    }

    private static func firstPushButton(in view: NSView) -> NSButton? {
        guard !view.isHidden else { return nil }
        if let b = view as? NSButton, isPushButton(b), b.isEnabled { return b }
        for sub in view.subviews {
            if let found = firstPushButton(in: sub) { return found }
        }
        return nil
    }

    static func moveButtonFocus(from current: NSButton, in window: NSWindow, direction: (dx: CGFloat, dy: CGFloat)) -> Bool {
        guard let root = window.contentView else { return false }
        var buttons: [NSButton] = []
        collectEnabledPushButtons(in: root, into: &buttons)
        let curRect = current.convert(current.bounds, to: nil)
        let curCenter = NSPoint(x: curRect.midX, y: curRect.midY)
        let best = buttons.compactMap { candidate -> (button: NSButton, score: CGFloat)? in
            guard candidate !== current else { return nil }
            let r = candidate.convert(candidate.bounds, to: nil)
            return directionalScore(dx: r.midX - curCenter.x, dy: r.midY - curCenter.y, direction: direction).map { (candidate, $0) }
        }.min { $0.score < $1.score }
        guard let target = best?.button else { return false }
        window.makeFirstResponder(target)
        return true
    }

    private static func collectEnabledPushButtons(in view: NSView, into buttons: inout [NSButton]) {
        guard !view.isHidden else { return }
        if let b = view as? NSButton, isPushButton(b), b.isEnabled { buttons.append(b) }
        for subview in view.subviews { collectEnabledPushButtons(in: subview, into: &buttons) }
    }

    private static func directionalScore(dx: CGFloat, dy: CGFloat, direction: (dx: CGFloat, dy: CGFloat)) -> CGFloat? {
        let primary = dx * direction.dx + dy * direction.dy
        guard primary > 4 else { return nil }
        let perp = abs(dx * direction.dy + dy * direction.dx)
        return primary + perp * 3.0
    }

    static func styleButtons(in window: NSWindow) {
        if let root = window.contentView?.superview ?? window.contentView { styleButtons(in: root) }
    }

    /// Global design tokens (matching the unified dialog & control palette).
    private(set) static var accent = Theme.standard.accent.nsColor   // #0a63e0 by default
    static let danger = NSColor(srgbRed: 197 / 255, green: 34 / 255, blue: 31 / 255, alpha: 1)   // #c5221f
    static let errorText = NSColor(srgbRed: 179 / 255, green: 38 / 255, blue: 30 / 255, alpha: 1) // #b3261e

    /// Unified layout metrics shared across all windows, dialogs, and popups.
    enum Layout {
        static let margin: CGFloat = 16
        static let sectionSpacing: CGFloat = 12
        static let controlSpacing: CGFloat = 8
        static let buttonMinWidth: CGFloat = 88
    }

    /// One look for every push button: rounded, regular size, the regular system font.
    /// Buttons in the same stack, or the same grid column, are as wide as the widest of them.
    /// Checkboxes, radio buttons, pop-ups, toggle pills (`.recessed`), and compact icon-only
    /// buttons (`.regularSquare` with `.imageOnly`) are left alone; hidden views and the pages
    /// of tab views are included. Running it again changes nothing.
    static func styleButtons(in root: NSView) {
        var groups: [ObjectIdentifier: [NSButton]] = [:]
        var order: [ObjectIdentifier] = []
        collectPushButtons(in: root, groups: &groups, order: &order)
        for key in order { equalizeWidths(groups[key] ?? []) }
    }

    private static func collectPushButtons(in view: NSView, groups: inout [ObjectIdentifier: [NSButton]], order: inout [ObjectIdentifier]) {
        if let button = view as? NSButton, isPushButton(button) {
            stylePushButton(button)
            if let key = groupKey(of: button) {
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(button)
            }
        }
        for subview in view.subviews { collectPushButtons(in: subview, groups: &groups, order: &order) }
        if let tabs = view as? NSTabView { collectTabPages(in: tabs, groups: &groups, order: &order) }
    }

    private static func collectTabPages(in tabs: NSTabView, groups: inout [ObjectIdentifier: [NSButton]], order: inout [ObjectIdentifier]) {
        for item in tabs.tabViewItems {
            if let page = item.view, page.superview == nil {
                collectPushButtons(in: page, groups: &groups, order: &order)
            }
        }
    }

    /// Push buttons are bordered: checkboxes and radio buttons are not (pop-ups are NSButtons too).
    static func isPushButton(_ button: NSButton) -> Bool {
        button.isBordered && !(button is NSPopUpButton)
    }

    static func stylePushButton(_ button: NSButton) {
        if shouldUseRoundedBezel(button) { button.bezelStyle = .rounded }
        button.controlSize = .regular
        // Titles drawn in their own colours (Synchronize's arrows) or with underlined mnemonics keep them.
        if !hasCustomTitleStyling(button.attributedTitle) {
            button.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        if button.keyEquivalent == "\r" && button.bezelColor != danger {
            button.bezelColor = accent
        }
    }

    private static func shouldUseRoundedBezel(_ button: NSButton) -> Bool {
        let isIconOnlySquare = button.bezelStyle == .regularSquare && button.imagePosition == .imageOnly
        return !isIconOnlySquare && button.bezelStyle != .recessed && button.bezelStyle != .inline
    }

    private static func hasCustomTitleStyling(_ title: NSAttributedString) -> Bool {
        guard title.length > 0 else { return false }
        let colour = title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        if colour.map({ $0 != .controlTextColor }) ?? false { return true }
        var hasUnderline = false
        title.enumerateAttribute(.underlineStyle, in: NSRange(location: 0, length: title.length)) { val, _, stop in
            if let style = val as? Int, style != 0 { hasUnderline = true; stop.pointee = true }
        }
        return hasUnderline
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

    // MARK: - Table Cells

    /// Wraps a label in an `NSTableCellView` so its text is vertically centred and padded in the row.
    static func centeredCell(_ label: NSTextField, leading: CGFloat = 4) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -leading),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
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
