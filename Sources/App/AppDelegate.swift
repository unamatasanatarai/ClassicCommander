import Cocoa
import os

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private static let logger = Logger(subsystem: AppConfig.bundleIdentifier, category: "Application")

    private(set) var statusBarController: StatusBarController?

    // Lazy window initialization: backing store and view hierarchy are allocated only on demand,
    // saving ~16MB of resident memory during routine background/status bar operation.
    private lazy var window: NSWindow = createWindow()
    var commanderView: CommanderView?
    private let settings: SettingsStore
    /// Where the main window keeps its frame ("" = not saved; tests).
    private let windowAutosaveName: String
    /// Brings the app to the front when showing windows (tests turn it off).
    var activatesApp = true
    private var quitGate = DoublePressGate(interval: 1.5)
    private lazy var optionsController = OptionsWindowController(store: settings)

    public init(settings: SettingsStore = SettingsStore(), windowAutosaveName: String = "MainWindow") {
        self.settings = settings
        self.windowAutosaveName = windowAutosaveName
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if activatesApp { NSApp.setActivationPolicy(.regular) }
        // No "Show Tab Bar / Show All Tabs" (macOS adds them to a menu named View).
        NSWindow.allowsAutomaticWindowTabbing = false
        ComboHover.install()
        setupMainMenu()

        updateStatusBarIcon()
        showWindow()
        Self.logger.info("\(AppConfig.appName, privacy: .public) started successfully.")
    }

    public func showWindow() {
        window.makeKeyAndOrderFront(nil)
        if activatesApp { NSApp.activate(ignoringOtherApps: true) }
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

        // Select Menu (Total Commander's "Mark" menu): every way to select, copy names, compare folders.
        let selectMenuItem = NSMenuItem()
        mainMenu.addItem(selectMenuItem)
        let selectMenu = NSMenu(title: "Select")
        selectMenu.delegate = self
        let selectGroups: [[CommandAction]] = [
            [.selectByMask, .deselectByMask, .selectAll, .deselectAll, .invertSelection],
            [.selectSameExtension, .deselectSameExtension, .restoreSelection, .showMarkedOnly],
            [.copyNames, .copyPaths, .copyNamesWithDetails, .copyPathsWithDetails],
            [.compareByDate, .compareBySize],
        ]
        for (i, group) in selectGroups.enumerated() {
            if i > 0 { selectMenu.addItem(.separator()) }
            for action in group {
                let item = NSMenuItem(title: Self.menuTitles[action] ?? action.label, action: #selector(netCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action.rawValue
                selectMenu.addItem(item)
            }
        }
        selectMenuItem.submenu = selectMenu

        // Commands Menu (Total Commander's tools)
        let commandsMenuItem = NSMenuItem()
        mainMenu.addItem(commandsMenuItem)
        let commandsMenu = NSMenu(title: "Commands")
        commandsMenu.delegate = self
        for action in [CommandAction.findFiles, .synchronizeDirs, .multiRename, .packFiles, .unpackFiles, nil, .openTerminal, .openInFinder, .swapPanels] {
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
                                ("Queue…", .ftpTransfers)] {
            let item = NSMenuItem(title: title, action: #selector(netCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            netMenu.addItem(item)
            if action == .ftpDisconnect { netMenu.addItem(.separator()) }
        }
        netMenuItem.submenu = netMenu

        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)

        let windowMenu = NSMenu(title: "Window")
        let openWindowItem = NSMenuItem(title: "Open Window", action: #selector(openWindowFromMenu), keyEquivalent: "o")
        openWindowItem.target = self
        windowMenu.addItem(openWindowItem)
        windowMenu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(title: "Close Window", action: #selector(closeWindowOrTab(_:)), keyEquivalent: "w")
        closeItem.target = self
        windowMenu.addItem(closeItem)
        let minimizeItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(minimizeItem)
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc func closeWindowOrTab(_ sender: Any?) {
        if let keyWin = NSApp.keyWindow, keyWin !== window {
            keyWin.performClose(sender)
            return
        }
        if let commander = commanderView, commander.hasMultipleTabs(in: commander.model.activeSide) {
            commander.perform(.closeTab)
        } else {
            window.performClose(sender)
        }
    }

    @objc private func quitPressed() {
        if quitGate.press() {
            Modal.terminate()
        } else if let commander = commanderView, window.isVisible {
            commander.showHint("Press ⌘Q again to quit")
        } else {
            NSSound.beep()
        }
    }

    static let menuTitles: [CommandAction: String] = [
        .findFiles: "Find Files…", .synchronizeDirs: "Synchronize Directories…", .openTerminal: "Open Terminal Here", .openInFinder: "Open in Finder", .multiRename: "Multi-Rename Tool…", .packFiles: "Pack…", .unpackFiles: "Unpack…",
        .ftpConnect: "FTP Connect…", .ftpNewConnection: "FTP New Connection…", .ftpDisconnect: "FTP Disconnect", .ftpTransfers: "Queue…",
        .sortByName: "Sort by Name", .sortByExtension: "Sort by Extension", .sortByDate: "Sort by Date/Time",
        .sortBySize: "Sort by Size", .sortUnsorted: "Unsorted", .reverseOrder: "Reverse Order",
        .showAllFiles: "All Files", .showPrograms: "Programs", .showCustomFilter: "Custom Filter…",
        .toggleHiddenFiles: "Hidden Files", .toggleFunctionKeyBar: "Function Key Buttons", .toggleFolderBrackets: "[Brackets] Around Folders",
        .quickFilter: "Quick Filter…", .refresh: "Refresh", .swapPanels: "Swap Panels",
        .selectByMask: "Select Group…", .deselectByMask: "Unselect Group…", .selectAll: "Select All", .deselectAll: "Unselect All",
        .invertSelection: "Invert Selection", .selectSameExtension: "Select All with Same Extension",
        .deselectSameExtension: "Unselect All with Same Extension", .restoreSelection: "Restore Selection",
        .showMarkedOnly: "Show Selected Only", .copyNames: "Copy Names to Clipboard",
        .copyPaths: "Copy Names with Path to Clipboard", .copyNamesWithDetails: "Copy Names with All Details to Clipboard",
        .copyPathsWithDetails: "Copy Names with Path and All Details to Clipboard",
        .compareByDate: "Compare Directories (Newer and Missing)", .compareBySize: "Compare Directories (Size and Missing)",
    ]

    /// Commander menus show each item's current key (Options → Shortcuts may change it) as a real
    /// menu shortcut, so macOS draws and aligns it like any other. The shortcut exists only while
    /// the menu is open (removed in menuDidClose), so a closed menu never takes a key: keys keep
    /// going to the panels, text fields and the shortcut recorder exactly as before.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Window" {
            for item in menu.items where item.action == #selector(closeWindowOrTab(_:)) {
                let hasTabs = commanderView?.hasMultipleTabs(in: commanderView?.model.activeSide ?? .left) ?? false
                item.title = hasTabs ? "Close Tab" : "Close Window"
            }
        }
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
        // Shortcuts are kept intact; `menuHasKeyEquivalent` returns false so closed menus never intercept keys.
    }

    /// Key presses never consult these menus (and never trigger menuNeedsUpdate).
    public func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                                     action: UnsafeMutablePointer<Selector?>) -> Bool {
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
        case .showMarkedOnly: on = panel.showsMarkedOnly
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
        optionsController.onOpenFTPManager = { [weak self] in
            self?.showWindow()
            self?.commanderView?.perform(.ftpConnect)
        }
        optionsController.present()
        if activatesApp { NSApp.activate(ignoringOtherApps: true) }
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
        // Every window (dialogs, alerts and menus too) follows the theme of the panels.
        AppWindows.apply(settings.theme)
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
        // Closing only hides it: the app keeps this window and shows it again from the Dock.
        // (Released on close, the Dock icon would bring back a freed window and crash.)
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 640, height: 320)
        AppWindows.apply(settings.theme)
        AppWindows.style(win)
        AppWindows.mainWindow = win
        win.center()
        if !windowAutosaveName.isEmpty { win.setFrameAutosaveName(windowAutosaveName) }

        let home = FileManager.default.homeDirectoryForCurrentUser
        // Both panels open where they were when the app was last used.
        let model = CommanderModel(
            left: PanelModel(directory: settings.lastFolder(.left) ?? home),
            right: PanelModel(directory: settings.lastFolder(.right) ?? URL(fileURLWithPath: "/"))
        )
        let commander = CommanderView(model: model)
        commander.settings = settings.settings
        commander.onSettingsChange = { [weak self] new in self?.settings.save(new) }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: SettingsStore.didChange, object: settings)
        commander.onOpenFile = Modal.open
        commander.onFolderChange = { [weak self] side, folder in self?.settings.rememberFolder(folder, side: side) }
        for side in [CommanderModel.Side.left, .right] {
            let saved = settings.tabs(side)
            if !saved.paths.isEmpty {
                commander.restoreTabs(PanelTabs(saved: saved.paths, active: saved.active,
                                                fallback: commander.view(for: side).model.directory), side: side)
            }
        }
        commander.onTabsChange = { [weak self] side, tabs in self?.settings.saveTabs(tabs, side: side) }
        commander.splitRatio = settings.splitRatio
        commander.onSplitChange = { [weak self] ratio in self?.settings.splitRatio = ratio }
        self.commanderView = commander

        win.contentView = commander
        win.initialFirstResponder = commander
        win.makeFirstResponder(commander)
        win.delegate = self
        return win
    }

    /// Finder's "Open With → ClassicCommander" (and files dropped on the Dock icon): shown in the
    /// panel chosen in Options → Operation.
    public func application(_ sender: NSApplication, open urls: [URL]) {
        showWindow()
        commanderView?.show(urls, in: settings.operation.finderOpensIn == .left ? .left : .right)
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
