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
        var chosen: NSApplication.ModalResponse = .alertFirstButtonReturn
        let win = dialogWindow(for: alert) { response in
            chosen = response
            NSApp.stopModal(withCode: response)
        }
        AppWindows.place(win)
        NSApp.runModal(for: win)
        win.orderOut(nil)
        return chosen
    }

    /// Builds a unified horizontal ClassicCommander dialog window from an `NSAlert`:
    /// left-aligned 48×48 icon + 17pt title/13pt subtitle header, optional detail panel or
    /// error list or input field, and right-aligned buttons (36pt tall, primary/danger accented).
    static func dialogWindow(for alert: NSAlert, onButton: @escaping (NSApplication.ModalResponse) -> Void) -> NSWindow {
        let (surfaceColor, panelColor) = dialogSurfaceColors()
        let parsed = parseAlertBody(alert.informativeText)
        let winWidth = dialogWindowWidth(hasDetails: !parsed.kvPairs.isEmpty || !parsed.bullets.isEmpty,
                                         accessoryView: alert.accessoryView)
        let win = makeBaseDialogWindow(title: alert.messageText, width: winWidth, surfaceColor: surfaceColor)

        let headerRow = makeDialogHeader(alert: alert, subtitle: parsed.subtitle)
        let margin: CGFloat = 20
        let (bodyViews, firstInput) = makeDialogBodyViews(
            headerRow: headerRow, kvPairs: parsed.kvPairs, bullets: parsed.bullets,
            remaining: parsed.remaining, accessoryView: alert.accessoryView,
            panelColor: panelColor, contentWidth: winWidth - margin * 2
        )
        let handler = AlertButtonHandler(onButton: onButton)
        let visualButtons = Array(makeDialogButtons(for: alert, handler: handler).reversed())
        let buttonRow = NSStackView(views: [NSView()] + visualButtons)
        buttonRow.spacing = 12
        let stack = makeDialogStack(views: bodyViews + [buttonRow], margin: margin)
        win.contentView = makeDialogRootView(
            stack: stack, handler: handler, winWidth: winWidth, margin: margin,
            headerRow: headerRow, buttonRow: buttonRow, accessoryView: alert.accessoryView
        )
        configureDialogFocus(firstInput: firstInput, buttons: visualButtons, in: win)
        return win
    }

    private static func dialogWindowWidth(hasDetails: Bool, accessoryView: NSView?) -> CGFloat {
        let isWide = hasDetails || (accessoryView?.frame.width ?? 0) > 400
        return isWide ? 460 : 440
    }

    private static func configureDialogFocus(firstInput: NSView?, buttons: [NSButton], in win: NSWindow) {
        let inputs = firstInput.map { [$0] } ?? []
        AppWindows.setTabOrder(inputs + buttons, in: win)
        if let input = firstInput { win.initialFirstResponder = input }
        AppWindows.styleButtons(in: win)
    }

    private static func makeBaseDialogWindow(title: String, width: CGFloat, surfaceColor: NSColor) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 150),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = AppWindows.title(title.isEmpty ? "Alert" : title)
        win.backgroundColor = surfaceColor
        win.isReleasedWhenClosed = false
        return win
    }

    private static func makeDialogStack(views: [NSView], margin: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private static func dialogSurfaceColors() -> (surface: NSColor, panel: NSColor) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? (NSColor(srgbRed: 36 / 255, green: 36 / 255, blue: 38 / 255, alpha: 1),
               NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 52 / 255, alpha: 1))
            : (NSColor(srgbRed: 244 / 255, green: 244 / 255, blue: 244 / 255, alpha: 1),
               NSColor(srgbRed: 233 / 255, green: 233 / 255, blue: 233 / 255, alpha: 1))
    }

    private static func makeDialogRootView(
        stack: NSStackView, handler: AlertButtonHandler, winWidth: CGFloat, margin: CGFloat,
        headerRow: NSView, buttonRow: NSView, accessoryView: NSView?
    ) -> NSView {
        let root = AlertContainerView()
        root.handler = handler
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: winWidth),
            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -margin * 2),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -margin * 2),
        ])
        if let acc = accessoryView {
            acc.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -margin * 2).isActive = true
        }
        return root
    }

    private static func makeDialogBodyViews(
        headerRow: NSView,
        kvPairs: [(String, String)],
        bullets: [String],
        remaining: [String],
        accessoryView: NSView?,
        panelColor: NSColor,
        contentWidth: CGFloat
    ) -> ([NSView], NSView?) {
        var bodyViews: [NSView] = [headerRow]
        if !kvPairs.isEmpty {
            bodyViews.append(makeDetailPanel(pairs: kvPairs, background: panelColor, width: contentWidth))
        }
        if !bullets.isEmpty {
            bodyViews.append(makeErrorListPanel(items: bullets, background: panelColor, width: contentWidth))
        }
        if !remaining.isEmpty {
            bodyViews.append(makeRemainingBodyLabel(remaining, contentWidth: contentWidth))
        }
        let firstInput = accessoryView.map { prepareAccessoryView($0, into: &bodyViews) } ?? nil
        return (bodyViews, firstInput)
    }

    private static func makeRemainingBodyLabel(_ remaining: [String], contentWidth: CGFloat) -> NSTextField {
        let bodyLabel = NSTextField(wrappingLabelWithString: remaining.joined(separator: "\n"))
        bodyLabel.font = .systemFont(ofSize: 14)
        bodyLabel.isSelectable = false
        bodyLabel.preferredMaxLayoutWidth = contentWidth
        return bodyLabel
    }

    private static func prepareAccessoryView(_ acc: NSView, into bodyViews: inout [NSView]) -> NSView? {
        let h = acc.frame.height
        acc.translatesAutoresizingMaskIntoConstraints = false
        if h > 0 { acc.heightAnchor.constraint(equalToConstant: h).isActive = true }
        bodyViews.append(acc)
        return (acc as? NSTextField) ?? acc.subviews.first { $0 is NSTextField }
    }

    private static func makeDialogHeader(alert: NSAlert, subtitle: String?) -> NSStackView {
        let iconImage: NSImage = (alert.alertStyle == .warning || alert.alertStyle == .critical)
            ? warningTriangleIcon()
            : (NSApp.applicationIconImage ?? NSImage())
        iconImage.size = NSSize(width: 48, height: 48)
        let iconView = NSImageView(image: iconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 48).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let titleLabel = NSTextField(wrappingLabelWithString: alert.messageText)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.isSelectable = false

        var headerTextViews: [NSView] = [titleLabel]
        if let subText = subtitle {
            let sub = NSTextField(wrappingLabelWithString: subText)
            sub.font = .systemFont(ofSize: 13)
            sub.textColor = .secondaryLabelColor
            sub.isSelectable = false
            headerTextViews.append(sub)
        }

        let headerText = NSStackView(views: headerTextViews)
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2

        let headerRow = NSStackView(views: [iconView, headerText])
        headerRow.alignment = .centerY
        headerRow.spacing = 14
        return headerRow
    }

    private static func parseAlertBody(_ text: String) -> (
        subtitle: String?,
        kvPairs: [(String, String)],
        bullets: [String],
        remaining: [String]
    ) {
        let infoLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if infoLines.contains(where: { $0.hasPrefix("• ") }) {
            return parseBulletBody(infoLines)
        }
        if infoLines.contains(where: { $0.contains(": ") && !$0.hasPrefix("•") }) {
            let (subtitle, kvPairs, remaining) = parseKVBody(infoLines)
            return (subtitle, kvPairs, [], remaining)
        }
        return (text.isEmpty ? nil : text, [], [], [])
    }

    private static func parseBulletBody(_ infoLines: [String]) -> (
        subtitle: String?, kvPairs: [(String, String)], bullets: [String], remaining: [String]
    ) {
        var bullets: [String] = []
        var remaining: [String] = []
        for line in infoLines {
            if line.hasPrefix("• ") { bullets.append(String(line.dropFirst(2))) }
            else if !line.isEmpty { remaining.append(line) }
        }
        let subtitle = remaining.isEmpty ? nil : remaining.removeFirst()
        return (subtitle, [], bullets, remaining)
    }

    private static func parseKVBody(_ infoLines: [String]) -> (String?, [(String, String)], [String]) {
        var subtitle: String?
        var kvPairs: [(String, String)] = []
        var remaining: [String] = []
        var idx = 0
        if let first = infoLines.first, !first.contains(": ") && !first.isEmpty {
            subtitle = first
            idx = 1
        }
        for line in infoLines.dropFirst(idx) where !line.isEmpty {
            if let pair = splitKVPair(line, allowAll: kvPairs.isEmpty) {
                kvPairs.append(pair)
            } else {
                remaining.append(line)
            }
        }
        return (subtitle, kvPairs, remaining)
    }

    private static func splitKVPair(_ line: String, allowAll: Bool) -> (String, String)? {
        guard let colon = line.range(of: ": "), isKVLineAllowed(line, allowAll: allowAll) else { return nil }
        let key = String(line[..<colon.lowerBound])
        guard key.count <= 16 && !key.contains(".") else { return nil }
        return (key, String(line[colon.upperBound...]))
    }

    private static func isKVLineAllowed(_ line: String, allowAll: Bool) -> Bool {
        allowAll || (!line.hasSuffix("?") && !line.hasPrefix("Only "))
    }

    private static func makeDialogButtons(for alert: NSAlert, handler: AlertButtonHandler) -> [NSButton] {
        let titles = alert.buttons.isEmpty ? ["OK"] : alert.buttons.map(\.title)
        return titles.enumerated().map { makeDialogButton(at: $0.offset, title: $0.element, alert: alert, handler: handler) }
    }

    private static func makeDialogButton(at i: Int, title: String, alert: NSAlert, handler: AlertButtonHandler) -> NSButton {
        let b = NSButton(title: title, target: handler, action: #selector(AlertButtonHandler.pressed(_:)))
        b.tag = Int(NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) + i
        b.bezelStyle = .rounded
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: AppWindows.Layout.buttonMinWidth).isActive = true
        if i == 0 {
            b.keyEquivalent = "\r"
            b.bezelColor = alert.alertStyle == .critical ? AppWindows.danger : AppWindows.accent
        } else if title == "Cancel" {
            b.keyEquivalent = "\u{1b}"
        }
        return b
    }

    private static func makeDetailPanel(pairs: [(String, String)], background: NSColor, width: CGFloat) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 10
        box.fillColor = background

        var rows: [[NSView]] = []
        for (k, v) in pairs {
            let keyLabel = NSTextField(labelWithString: k)
            keyLabel.font = .systemFont(ofSize: 13)
            keyLabel.textColor = .secondaryLabelColor
            keyLabel.widthAnchor.constraint(equalToConstant: 86).isActive = true

            let valLabel = NSTextField(wrappingLabelWithString: v)
            valLabel.isSelectable = false
            valLabel.preferredMaxLayoutWidth = width - 86 - 40
            if k.lowercased().contains("sha") || k.lowercased().contains("fingerprint") {
                valLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            } else if k.lowercased() == "problem" {
                valLabel.font = .systemFont(ofSize: 13, weight: .semibold)
                valLabel.textColor = AppWindows.errorText
            } else {
                valLabel.font = .systemFont(ofSize: 13)
            }
            rows.append([keyLabel, valLabel])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            box.widthAnchor.constraint(equalToConstant: width),
        ])
        return box
    }

    private static func makeErrorListPanel(items: [String], background: NSColor, width: CGFloat) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 10
        box.fillColor = background

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        list.translatesAutoresizingMaskIntoConstraints = false

        for item in items {
            let parts = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let icon = NSImageView(image: errorCircleIcon())
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true

            let title = NSTextField(labelWithString: parts[0])
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            var textViews: [NSView] = [title]
            if parts.count > 1 {
                let sub = NSTextField(wrappingLabelWithString: parts[1])
                sub.font = parts[1].hasPrefix("/") ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
                sub.textColor = .secondaryLabelColor
                sub.preferredMaxLayoutWidth = width - 56
                textViews.append(sub)
            }
            let col = NSStackView(views: textViews)
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 2
            let row = NSStackView(views: [icon, col])
            row.alignment = .top
            row.spacing = 10
            list.addArrangedSubview(row)
        }
        box.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            list.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            list.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            list.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            box.widthAnchor.constraint(equalToConstant: width),
        ])
        return box
    }

    private static func warningTriangleIcon() -> NSImage {
        NSImage(size: NSSize(width: 48, height: 48), flipped: false) { _ in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 24, y: 43))
            p.line(to: NSPoint(x: 45, y: 7))
            p.line(to: NSPoint(x: 3, y: 7))
            p.close()
            p.lineJoinStyle = .round
            p.lineWidth = 2
            NSColor(srgbRed: 245/255, green: 184/255, blue: 0, alpha: 1).setFill()
            p.fill()
            NSColor(srgbRed: 184/255, green: 130/255, blue: 0, alpha: 1).setStroke()
            p.stroke()
            let bar = NSBezierPath(roundedRect: NSRect(x: 22.5, y: 18, width: 3, height: 13), xRadius: 1.5, yRadius: 1.5)
            NSColor(srgbRed: 58/255, green: 46/255, blue: 0, alpha: 1).setFill()
            bar.fill()
            NSBezierPath(ovalIn: NSRect(x: 22, y: 11, width: 4, height: 4)).fill()
            return true
        }
    }

    private static func errorCircleIcon() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            AppWindows.danger.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14)).fill()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 5.2, y: 5.2))
            p.line(to: NSPoint(x: 10.8, y: 10.8))
            p.move(to: NSPoint(x: 10.8, y: 5.2))
            p.line(to: NSPoint(x: 5.2, y: 10.8))
            p.lineWidth = 1.6
            p.lineCapStyle = .round
            NSColor.white.setStroke()
            p.stroke()
            return true
        }
    }

    private final class AlertButtonHandler: NSObject {
        let onButton: (NSApplication.ModalResponse) -> Void
        init(onButton: @escaping (NSApplication.ModalResponse) -> Void) { self.onButton = onButton }
        @objc func pressed(_ sender: NSButton) {
            onButton(NSApplication.ModalResponse(rawValue: sender.tag))
        }
    }

    private final class AlertContainerView: NSView {
        var handler: AlertButtonHandler?
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
        if let content = alert.window.contentView { deselectLabels(in: content) }
        configureAlertTabOrder(for: alert)
    }

    private static func configureAlertTabOrder(for alert: NSAlert) {
        var tabViews: [NSView] = []
        if let acc = alert.accessoryView { findControls(in: acc, into: &tabViews) }
        tabViews.append(contentsOf: sortedAlertButtons(for: alert))
        if !tabViews.isEmpty {
            AppWindows.setTabOrder(tabViews, in: alert.window)
            alert.window.initialFirstResponder = tabViews.first
        }
    }

    private static func deselectLabels(in view: NSView) {
        if let tf = view as? NSTextField, !tf.isEditable { tf.isSelectable = false }
        for subview in view.subviews { deselectLabels(in: subview) }
    }

    private static func findControls(in view: NSView, into result: inout [NSView]) {
        if (view is NSControl) || view.canBecomeKeyView {
            result.append(view)
        } else {
            for subview in view.subviews { findControls(in: subview, into: &result) }
        }
    }

    private static func sortedAlertButtons(for alert: NSAlert) -> [NSButton] {
        alert.buttons.sorted { b1, b2 in
            let f1 = b1.convert(b1.bounds, to: nil)
            let f2 = b2.convert(b2.bounds, to: nil)
            if abs(f1.origin.y - f2.origin.y) > 5 { return f1.origin.y > f2.origin.y }
            return f1.origin.x < f2.origin.x
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
        performWorkspaceLaunch(launch, result: LaunchResult(failed: failed))
    }

    static func performWorkspaceLaunch(
        _ launch: TerminalLauncher.Launch,
        result: LaunchResult,
        openFolder: ([URL], URL, NSWorkspace.OpenConfiguration, @escaping (NSRunningApplication?, Error?) -> Void) -> Void = { urls, app, cfg, cb in
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: cfg, completionHandler: cb)
        },
        openApp: (URL, NSWorkspace.OpenConfiguration, @escaping (NSRunningApplication?, Error?) -> Void) -> Void = { app, cfg, cb in
            NSWorkspace.shared.openApplication(at: app, configuration: cfg, completionHandler: cb)
        }
    ) {
        let config = NSWorkspace.OpenConfiguration()
        switch launch {
        case let .openFolder(app, folder):
            openFolder([folder], app, config, result.finished)
        case let .run(app, arguments):
            config.arguments = arguments
            config.createsNewApplicationInstance = true
            openApp(app, config, result.finished)
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
