import Cocoa
import os

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private static let logger = Logger(subsystem: AppConfig.bundleIdentifier, category: "Application")

    private var statusBarController: StatusBarController?

    // Lazy window initialization: backing store and view hierarchy are allocated only on demand,
    // saving ~16MB of resident memory during routine background/status bar operation.
    private lazy var window: NSWindow = createWindow()
    var commanderView: CommanderView?
    private let settings = SettingsStore()
    private var quitGate = DoublePressGate(interval: 1.5)
    private lazy var optionsController = OptionsWindowController(store: settings)

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // No "Show Tab Bar / Show All Tabs" (macOS adds them to a menu named View).
        NSWindow.allowsAutomaticWindowTabbing = false
        setupMainMenu()

        updateStatusBarIcon()
        showWindow()
        Self.logger.info("\(AppConfig.appName, privacy: .public) started successfully.")
    }

    public func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(AppConfig.appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(showOptions), keyEquivalent: ",")
        prefsItem.target = self
        appMenu.addItem(prefsItem)
        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: "Hide \(AppConfig.appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        // ⌘Q must be pressed twice so a stray keystroke never closes the commander.
        let quitItem = NSMenuItem(title: "Quit \(AppConfig.appName)", action: #selector(quitPressed), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        // Edit Menu: text fields (FTP dialogs, Find Files, Options…) get ⌘X/⌘C/⌘V/⌘A/⌘Z only
        // through these menu items, which go to whatever field has the focus.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // View Menu (Total Commander's "Show" menu): sorting, filters and what is shown, for the active panel.
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.delegate = self
        let sortMenu: [CommandAction] = [.sortByName, .sortByExtension, .sortByDate, .sortBySize, .sortUnsorted, .reverseOrder]
        let showMenu: [CommandAction] = [.showAllFiles, .showPrograms, .showCustomFilter]
        let toggles: [CommandAction] = [.toggleHiddenFiles, .toggleFunctionKeyBar, .toggleFolderBrackets]
        for (i, group) in [sortMenu, showMenu, toggles, [.quickFilter, .refresh, .swapPanels]].enumerated() {
            if i > 0 { viewMenu.addItem(.separator()) }
            for action in group {
                let item = NSMenuItem(title: Self.menuTitles[action] ?? action.label, action: #selector(netCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action.rawValue
                viewMenu.addItem(item)
            }
        }
        viewMenuItem.submenu = viewMenu

        // Commands Menu (Total Commander's tools)
        let commandsMenuItem = NSMenuItem()
        mainMenu.addItem(commandsMenuItem)
        let commandsMenu = NSMenu(title: "Commands")
        commandsMenu.delegate = self
        for action in [CommandAction.findFiles, .synchronizeDirs, nil, .openTerminal, .swapPanels] {
            guard let action = action else { commandsMenu.addItem(.separator()); continue }
            let item = NSMenuItem(title: Self.menuTitles[action] ?? action.label, action: #selector(netCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            commandsMenu.addItem(item)
        }
        commandsMenuItem.submenu = commandsMenu

        // Net Menu (FTP, as in Total Commander)
        let netMenuItem = NSMenuItem()
        mainMenu.addItem(netMenuItem)
        let netMenu = NSMenu(title: "Net")
        netMenu.delegate = self
        for (title, action) in [("FTP Connect…", CommandAction.ftpConnect),
                                ("FTP New Connection…", .ftpNewConnection),
                                ("FTP Disconnect", .ftpDisconnect),
                                ("Transfers…", .ftpTransfers)] {
            let item = NSMenuItem(title: title, action: #selector(netCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            netMenu.addItem(item)
            if action == .ftpDisconnect { netMenu.addItem(.separator()) }
        }
        netMenuItem.submenu = netMenu

        // Configuration Menu (Total Commander's home of Options…)
        let configMenuItem = NSMenuItem()
        mainMenu.addItem(configMenuItem)
        let configMenu = NSMenu(title: "Configuration")
        let optionsItem = NSMenuItem(title: "Options…", action: #selector(showOptions), keyEquivalent: "")
        optionsItem.target = self
        configMenu.addItem(optionsItem)
        configMenuItem.submenu = configMenu

        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)

        let windowMenu = NSMenu(title: "Window")
        let openWindowItem = NSMenuItem(title: "Open Window", action: #selector(openWindowFromMenu), keyEquivalent: "o")
        openWindowItem.target = self
        windowMenu.addItem(openWindowItem)
        windowMenu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(closeItem)
        let minimizeItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(minimizeItem)
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func quitPressed() {
        if quitGate.press() {
            NSApp.terminate(nil)
        } else if let commander = commanderView, window.isVisible {
            commander.showHint("Press ⌘Q again to quit")
        } else {
            NSSound.beep()
        }
    }

    static let menuTitles: [CommandAction: String] = [
        .findFiles: "Find Files…", .synchronizeDirs: "Synchronize Directories…", .openTerminal: "Open Terminal Here",
        .ftpConnect: "FTP Connect…", .ftpNewConnection: "FTP New Connection…", .ftpDisconnect: "FTP Disconnect", .ftpTransfers: "Transfers…",
        .sortByName: "Sort by Name", .sortByExtension: "Sort by Extension", .sortByDate: "Sort by Date/Time",
        .sortBySize: "Sort by Size", .sortUnsorted: "Unsorted", .reverseOrder: "Reverse Order",
        .showAllFiles: "All Files", .showPrograms: "Programs", .showCustomFilter: "Custom Filter…",
        .toggleHiddenFiles: "Hidden Files", .toggleFunctionKeyBar: "Function Key Buttons", .toggleFolderBrackets: "[Brackets] Around Folders",
        .quickFilter: "Quick Filter…", .refresh: "Refresh", .swapPanels: "Swap Panels",
    ]

    /// Commander menus show each item's current key (Options → Shortcuts may change it) as a real
    /// menu shortcut, so macOS draws and aligns it like any other. The shortcut exists only while
    /// the menu is open (removed in menuDidClose), so a closed menu never takes a key: keys keep
    /// going to the panels, text fields and the shortcut recorder exactly as before.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard let keys = commanderView?.settings.keys else { return }
        for item in menu.items {
            guard let raw = item.representedObject as? String, let action = CommandAction(rawValue: raw) else { continue }
            item.title = Self.menuTitles[action] ?? action.label
            if let combo = keys.keys(for: action).first, let equivalent = Self.keyEquivalent(for: combo) {
                item.keyEquivalent = equivalent.key
                item.keyEquivalentModifierMask = equivalent.modifiers
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }

    public func menuDidClose(_ menu: NSMenu) {
        for item in menu.items where item.representedObject is String {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    /// Key presses never consult these menus (and never trigger menuNeedsUpdate).
    public func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                                     action: AutoreleasingUnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    /// The menu-shortcut form of a key (character plus modifiers), or nil when a menu cannot show it.
    static func keyEquivalent(for combo: KeyCombo) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var mods: NSEvent.ModifierFlags = []
        if combo.modifiers.contains(.control) { mods.insert(.control) }
        if combo.modifiers.contains(.option) { mods.insert(.option) }
        if combo.modifiers.contains(.shift) { mods.insert(.shift) }
        if combo.modifiers.contains(.command) { mods.insert(.command) }
        func fn(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }
        let special: [UInt16: String] = [
            KeyCode.returnKey: "\r", KeyCode.tab: "\t", KeyCode.space: " ", KeyCode.delete: "\u{8}", KeyCode.escape: "\u{1b}",
            KeyCode.forwardDelete: fn(NSDeleteFunctionKey), KeyCode.left: fn(NSLeftArrowFunctionKey), KeyCode.right: fn(NSRightArrowFunctionKey),
            KeyCode.up: fn(NSUpArrowFunctionKey), KeyCode.down: fn(NSDownArrowFunctionKey), KeyCode.home: fn(NSHomeFunctionKey),
            KeyCode.end: fn(NSEndFunctionKey), KeyCode.pageUp: fn(NSPageUpFunctionKey), KeyCode.pageDown: fn(NSPageDownFunctionKey),
            122: fn(NSF1FunctionKey), 120: fn(NSF2FunctionKey), 99: fn(NSF3FunctionKey), 118: fn(NSF4FunctionKey),
            96: fn(NSF5FunctionKey), 97: fn(NSF6FunctionKey), 98: fn(NSF7FunctionKey), 100: fn(NSF8FunctionKey),
            101: fn(NSF9FunctionKey), 109: fn(NSF10FunctionKey), 103: fn(NSF11FunctionKey), 111: fn(NSF12FunctionKey),
        ]
        if let key = special[combo.keyCode] { return (key, mods) }
        // Letters, digits and punctuation: their (unshifted) character.
        guard let name = KeyCode.names[combo.keyCode], name.count == 1 else { return nil }
        return (name.lowercased(), mods)
    }

    /// Ticks for the active panel's sort, Show filter and the View toggles.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let raw = item.representedObject as? String, let action = CommandAction(rawValue: raw),
              let commander = commanderView else { return true }
        let panel = commander.activeView.model
        let display = commander.settings.display
        var on: Bool?
        switch action {
        case .sortByName: on = panel.sortOrder.column == .name
        case .sortByExtension: on = panel.sortOrder.column == .ext
        case .sortByDate: on = panel.sortOrder.column == .date
        case .sortBySize: on = panel.sortOrder.column == .size
        case .sortUnsorted: on = panel.sortOrder.column == .unsorted
        case .reverseOrder: on = !panel.sortOrder.ascending
        case .showAllFiles: on = panel.showFilter == .all
        case .showPrograms: on = panel.showFilter == .programs
        case .showCustomFilter: if case .mask = panel.showFilter { on = true } else { on = false }
        case .toggleHiddenFiles: on = display.showHiddenFiles
        case .toggleFunctionKeyBar: on = display.showFunctionKeyBar
        case .toggleFolderBrackets: on = display.showFolderBrackets
        default: break
        }
        if let on = on { item.state = on ? .on : .off }
        return true
    }

    @objc private func netCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = CommandAction(rawValue: raw) else { return }
        showWindow()
        commanderView?.perform(action)
    }

    @objc private func showOptions() {
        optionsController.present()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func settingsDidChange() {
        applySettings()
    }

    /// Shows or removes the floppy icon in the menu bar (Options → Display).
    private func updateStatusBarIcon() {
        if settings.display.showStatusBarIcon {
            guard statusBarController == nil else { return }
            let controller = StatusBarController()
            controller.onOpenWindow = { [weak self] in self?.showWindow() }
            controller.refreshMenu()
            statusBarController = controller
        } else {
            statusBarController?.cleanup()
            statusBarController = nil
        }
    }

    private func applySettings() {
        updateStatusBarIcon()
        commanderView?.settings = settings.settings
        window.backgroundColor = settings.theme.chrome.nsColor
    }

    @objc private func openWindowFromMenu() {
        showWindow()
    }

    private func createWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = AppConfig.appName
        win.minSize = NSSize(width: 640, height: 320)
        win.backgroundColor = settings.theme.chrome.nsColor
        win.center()
        win.setFrameAutosaveName("MainWindow")

        let home = FileManager.default.homeDirectoryForCurrentUser
        let model = CommanderModel(
            left: PanelModel(directory: home),
            right: PanelModel(directory: URL(fileURLWithPath: "/"))
        )
        let commander = CommanderView(model: model)
        commander.settings = settings.settings
        commander.onSettingsChange = { [weak self] new in self?.settings.save(new) }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: SettingsStore.didChange, object: settings)
        commander.onOpenFile = { url in
            NSWorkspace.shared.open(url)
        }
        self.commanderView = commander

        win.contentView = commander
        win.initialFirstResponder = commander
        win.makeFirstResponder(commander)
        win.delegate = self
        return win
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Panels are not watched for changes yet; re-read them whenever the window comes back to the front.
    public func windowDidBecomeKey(_ notification: Notification) {
        commanderView?.reloadPanels()
    }
}
