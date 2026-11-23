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
        return alert.runModal()
    }

    /// Shows an alert as a sheet on `window` (modally without one) and reports the button pressed.
    static func sheet(_ alert: NSAlert, for window: NSWindow?, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let answer = answerAlert { completion?(answer(alert)); return }
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

    /// Quits the app.
    static func terminate() {
        if let terminated = terminated { terminated(); return }
        NSApp.terminate(nil)
    }
}
