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
}
