import AppKit

/// Every dialog, file panel, "open with the default app", app launch and quit goes through here.
/// In the app these do exactly what AppKit does; tests set the `answer…` hooks to reply instantly
/// (and see what was asked), so every dialog's code runs in tests without anything appearing.
enum Modal {
    /// Tests: the button an alert returns (the alert is passed in, so accessory fields can be filled).
    static var answerAlert: ((NSAlert) -> NSApplication.ModalResponse)?
    /// Tests: the URLs an open/save panel returns (empty = Cancel).
    static var answerPanel: ((NSSavePanel) -> [URL])?
    /// Tests: what would have been opened with its default app / launched / quit.
    static var opened: ((URL) -> Void)?
    static var launched: ((TerminalLauncher.Launch) -> Void)?
    static var terminated: (() -> Void)?

    /// Shows an alert modally and returns the button pressed.
    @discardableResult
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        if let answer = answerAlert { return answer(alert) }
        style(alert)
        return alert.runModal()
    }

    /// Tests: the button code a modal window (Copy / Move dialog, "target file exists") ends with;
    /// the window is passed in so its fields can be filled first.
    static var answerWindow: ((NSWindow) -> NSApplication.ModalResponse)?

    /// Alerts get the app's buttons (AppWindows.styleButtons), not the grey ones. An alert draws on
    /// a translucent background that turns its buttons grey; a button with its own appearance is
    /// drawn as a plain push button (the alert's own appearance, so light or dark still follows the theme).
    static func style(_ alert: NSAlert) {
        alert.layout()
        AppWindows.styleButtons(in: alert.window)
        let name = alert.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        for button in alert.buttons { button.appearance = NSAppearance(named: name) }

        // Disable text selection on static label text fields inside the alert window
        // to prevent unwanted selection highlights when opening.
        func deselectLabels(in view: NSView) {
            if let tf = view as? NSTextField, !tf.isEditable {
                tf.isSelectable = false
            }
            view.subviews.forEach(deselectLabels(in:))
        }
        if let content = alert.window.contentView {
            deselectLabels(in: content)
        }

        // Configure visual tab navigation order
        var tabViews: [NSView] = []
        if let acc = alert.accessoryView {
            var accControls: [NSView] = []
            func findControls(in v: NSView) {
                if (v is NSControl) || v.canBecomeKeyView {
                    accControls.append(v)
                } else {
                    v.subviews.forEach(findControls(in:))
                }
            }
            findControls(in: acc)
            tabViews.append(contentsOf: accControls.isEmpty ? [acc] : accControls)
        }

        // Sort buttons by visual reading order:
        // If vertical layout (different Y positions): top-to-bottom (descending Y)
        // If horizontal layout: left-to-right (ascending X)
        let sortedButtons = alert.buttons.sorted { b1, b2 in
            let f1 = b1.convert(b1.bounds, to: nil)
            let f2 = b2.convert(b2.bounds, to: nil)
            if abs(f1.origin.y - f2.origin.y) > 5 {
                return f1.origin.y > f2.origin.y
            }
            return f1.origin.x < f2.origin.x
        }
        tabViews.append(contentsOf: sortedButtons)

        if !tabViews.isEmpty {
            AppWindows.setTabOrder(tabViews, in: alert.window)
            if alert.accessoryView != nil {
                alert.window.initialFirstResponder = tabViews.first
            } else if let firstBtn = sortedButtons.first {
                alert.window.initialFirstResponder = firstBtn
            }
        }
    }

    /// Shows a window modally until one of its buttons stops it.
    static func runWindow(_ window: NSWindow) -> NSApplication.ModalResponse {
        if let answer = answerWindow { return answer(window) }
        return NSApp.runModal(for: window)
    }

    /// Shows an alert as a sheet on `window` (modally without one) and reports the button pressed.
    static func sheet(_ alert: NSAlert, for window: NSWindow?, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let answer = answerAlert { completion?(answer(alert)); return }
        style(alert)
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            let response = alert.runModal()
            completion?(response)
        }
    }

    /// Shows an open or save panel (as a sheet when there is a window) and passes on the chosen URLs
    /// (empty when cancelled).
    static func choose(_ panel: NSSavePanel, for window: NSWindow?, completion: @escaping ([URL]) -> Void) {
        if let answer = answerPanel { completion(answer(panel)); return }
        let result = PanelResult(panel: panel, completion: completion)
        if let window = window {
            panel.beginSheetModal(for: window, completionHandler: result.finished)
        } else {
            result.finished(panel.runModal())
        }
    }

    /// The URLs an open panel (several) or save panel (one) ended with.
    static func urls(of panel: NSSavePanel) -> [URL] {
        if let open = panel as? NSOpenPanel { return open.urls }
        if let url = panel.url { return [url] }
        return []
    }

    /// Turns a panel's response into the URLs handed to the caller.
    final class PanelResult {
        let panel: NSSavePanel
        let completion: ([URL]) -> Void
        init(panel: NSSavePanel, completion: @escaping ([URL]) -> Void) {
            self.panel = panel
            self.completion = completion
        }
        func finished(_ response: NSApplication.ModalResponse) {
            completion(response == .OK ? Modal.urls(of: panel) : [])
        }
    }

    /// Tests: files that would have been opened with a chosen app.
    static var openedWith: (([URL], URL) -> Void)?

    /// Opens files with a chosen app (Open With).
    static func open(_ urls: [URL], with app: URL) {
        if let openedWith = openedWith { openedWith(urls, app); return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// Opens a file with its default app.
    static func open(_ url: URL) {
        if let opened = opened { opened(url); return }
        NSWorkspace.shared.open(url)
    }

    /// Starts an app (the terminal for "Open terminal here"); `failed` gets launch errors.
    static func launch(_ launch: TerminalLauncher.Launch, failed: @escaping (Error) -> Void) {
        if let launched = launched { launched(launch); return }
        let config = NSWorkspace.OpenConfiguration()
        let result = LaunchResult(failed: failed)
        switch launch {
        case let .openFolder(app, folder):
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: config, completionHandler: result.finished)
        case let .run(app, arguments):
            config.arguments = arguments
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: config, completionHandler: result.finished)
        }
    }

    /// Reports a failed launch.
    final class LaunchResult {
        let failed: (Error) -> Void
        init(failed: @escaping (Error) -> Void) { self.failed = failed }
        func finished(_ app: NSRunningApplication?, _ error: Error?) {
            if let error = error { failed(error) }
        }
    }

    /// Tests: a pop-up menu that would have been shown.
    static var poppedUp: ((NSMenu) -> Void)?

    /// Shows a menu under a panel's drive bar (the menu runs its own tracking loop).
    static func popUp(_ menu: NSMenu, under panel: PanelView) {
        popUp(menu, at: panel.menuAnchor, in: panel, selecting: menu.items.first)
    }

    /// Shows a pop-up menu at a point of a view.
    static func popUp(_ menu: NSMenu, at point: NSPoint, in view: NSView, selecting item: NSMenuItem? = nil) {
        if let poppedUp = poppedUp { poppedUp(menu); return }
        menu.popUp(positioning: item, at: point, in: view)
    }

    /// Shows a context menu that opens while the mouse button is still held (long right click) and
    /// stays open when it is released (an NSMenu would close: see HeldMenu).
    static func popUpHeld(_ menu: NSMenu, at point: NSPoint, in view: NSView) {
        if let poppedUp = poppedUp { poppedUp(menu); return }
        guard let window = view.window else { return }
        let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
        HeldMenu(menu, at: screenPoint, appearance: view.effectiveAppearance).run()
    }

    /// Tests: the items of a drag that would have started.
    static var dragged: (([NSDraggingItem]) -> Void)?

    /// Starts dragging `items` out of `source` (files to the other panel, Finder or any app).
    static func drag(_ items: [NSDraggingItem], event: NSEvent, source: NSView & NSDraggingSource) {
        if let dragged = dragged { dragged(items); return }
        source.beginDraggingSession(with: items, event: event, source: source)
    }

    /// Tests: text that would have been put on the clipboard.
    static var copied: ((String) -> Void)?

    /// Puts text on the clipboard.
    static func copyToClipboard(_ text: String) {
        if let copied = copied { copied(text); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Quits the app.
    static func terminate() {
        if let terminated = terminated { terminated(); return }
        NSApp.terminate(nil)
    }
}
