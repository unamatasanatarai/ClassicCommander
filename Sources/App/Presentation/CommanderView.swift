import AppKit

/// The two side-by-side panels. Holds keyboard focus for the window and turns keys into
/// `CommandAction`s through the user's key bindings (Options → Shortcuts).
public final class CommanderView: NSView {
    public let model: CommanderModel
    public let leftView: PanelView
    public let rightView: PanelView

    /// Called when Enter or a double click lands on a file (not a directory).
    public var onOpenFile: ((URL) -> Void)?

    public let functionBar = FunctionKeyBar()
    public private(set) lazy var fileCommands = FileCommands(commander: self)
    public private(set) lazy var findFiles = FindFilesWindowController(commander: self)
    public private(set) lazy var quickSearch = QuickSearchController(commander: self)
    public private(set) lazy var synchronize = SyncWindowController(commander: self)
    /// FTP connections, remote navigation and transfers.
    public private(set) lazy var ftp = FTPController(commander: self)
    /// Open Lister windows (several can be open, as in Total Commander).
    public private(set) var listers: [ListerWindowController] = []

    public var settings: Settings = .standard {
        didSet {
            for view in [leftView, rightView] {
                view.theme = settings.theme
                view.display = settings.display
            }
            functionBar.theme = settings.theme
            functionBar.keys = settings.keys
            functionBar.isHidden = !settings.display.showFunctionKeyBar
            if ftp.transfers.limits != settings.operation.transferLimits { ftp.transfers.limits = settings.operation.transferLimits }
            needsLayout = true
            needsDisplay = true
        }
    }

    /// Mounted drives for the location menu; replaceable in tests.
    public var drivesProvider: () -> [LocationMenu.Item] = LocationMenu.mountedDrives
    /// Shows the location menu under a panel's drive bar; replaceable in tests (popping up blocks).
    public var presentMenu: (NSMenu, PanelView) -> Void = { menu, panel in
        menu.popUp(positioning: menu.items.first, at: panel.menuAnchor, in: panel)
    }
    /// Where folder sizes are worked out.
    public var sizingQueue = DispatchQueue(label: "ClassicCommander.folderSize", qos: .userInitiated)

    public init(model: CommanderModel) {
        self.model = model
        leftView = PanelView(model: model.left)
        rightView = PanelView(model: model.right)
        super.init(frame: .zero)
        for (view, side) in [(leftView, CommanderModel.Side.left), (rightView, .right)] {
            addSubview(view)
            view.onActivate = { [weak self] in self?.activate(side) }
            view.onOpen = { [weak self] in self?.openCurrent() }
            view.onLocationMenu = { [weak self] in self?.showLocationMenu(for: side) }
            view.onNavigate = { [weak self] action in
                self?.activate(side)
                self?.perform(action)
            }
            view.model.onDirectoryChange = { [weak self, weak view] in
                guard let self = self, let view = view else { return }
                self.cancelSizing(for: view)
            }
        }
        addSubview(functionBar)
        functionBar.onAction = { [weak self] action in
            self?.window?.makeFirstResponder(self)
            self?.perform(action)
        }
        syncActive()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func layout() {
        super.layout()
        let margin: CGFloat = 2, gap: CGFloat = 6
        let width = max(0, bounds.width - 2 * margin - gap)
        let half = floor(width / 2)
        let barHeight = settings.display.showFunctionKeyBar ? FunctionKeyBar.height : 0
        functionBar.frame = NSRect(x: margin, y: bounds.height - barHeight, width: bounds.width - 2 * margin, height: barHeight)
        let height = max(0, bounds.height - margin - barHeight)
        leftView.frame = NSRect(x: margin, y: 0, width: half, height: height)
        rightView.frame = NSRect(x: margin + half + gap, y: 0, width: width - half, height: height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        settings.theme.chrome.nsColor.setFill()
        dirtyRect.fill()
    }

    public func view(for side: CommanderModel.Side) -> PanelView {
        side == .left ? leftView : rightView
    }

    public var activeView: PanelView { view(for: model.activeSide) }

    public func activate(_ side: CommanderModel.Side) {
        model.activate(side)
        syncActive()
        window?.makeFirstResponder(self)
    }

    /// "Go to file": shows `url` in the active panel, cursor on it.
    public func reveal(_ url: URL) {
        let panel = activeView
        if url.isRemoteLocation {
            // A file on a server: shown when this panel is connected to that server.
            if !ftp.reveal(url, in: panel) { NSSound.beep() }
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
            return
        }
        if panel.model.isRemote && url.isFileURL { ftp.disconnect(model.activeSide) }
        let folder = url.deletingLastPathComponent()
        if case .failed = panel.model.go(to: folder, visibleRows: panel.visibleRows) {
            NSSound.beep()
        }
        panel.model.focus(name: url.lastPathComponent, visibleRows: panel.visibleRows)
        panel.needsDisplay = true
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
    }

    /// Re-reads both directories (e.g. when the window comes back to the front).
    public func reloadPanels() {
        for view in [leftView, rightView] {
            if view.model.isRemote {
                ftp.refresh(view)   // re-read from the server in the background
                continue
            }
            view.model.reload(visibleRows: view.visibleRows)
            view.invalidateVolumeInfo()
            view.needsDisplay = true
        }
    }

    // MARK: Hint

    private var hintBox: NSView?
    private var hintLabel: NSTextField?
    private var hintToken = 0

    /// A short message floating over the panels that fades away by itself (e.g. the ⌘Q reminder).
    public func showHint(_ text: String, duration: TimeInterval = 1.5) {
        if hintBox == nil { makeHint() }
        guard let box = hintBox, let label = hintLabel else { return }
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + 40, height: ceil(label.frame.height) + 20)
        box.frame = NSRect(x: floor((bounds.width - size.width) / 2), y: floor((bounds.height - size.height) / 2),
                           width: size.width, height: size.height)
        label.frame.origin = NSPoint(x: floor((size.width - label.frame.width) / 2),
                                     y: floor((size.height - label.frame.height) / 2))
        box.alphaValue = 1
        box.isHidden = false
        hintToken += 1
        let token = hintToken
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, token == self.hintToken, let box = self.hintBox else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                box.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.hintToken == token { box.isHidden = true }
            })
        }
    }

    var hintText: String? {
        guard let box = hintBox, !box.isHidden else { return nil }
        return hintLabel?.stringValue
    }

    private func makeHint() {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        box.layer?.cornerRadius = 8
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        box.addSubview(label)
        addSubview(box)
        hintBox = box
        hintLabel = label
    }

    private func syncActive() {
        leftView.isActive = model.activeSide == .left
        rightView.isActive = model.activeSide == .right
        updateFunctionBar()
    }

    /// The button bar gets "FTP Disconnect" while the active panel shows a server.
    func updateFunctionBar() {
        var actions = FunctionKeyBar.actions
        if activeView.model.isRemote { actions.append(.ftpDisconnect) }
        functionBar.shownActions = actions
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        if fileCommands.isBusy && event.keyCode == KeyCode.escape {
            fileCommands.cancelRunning()
            return
        }
        if let action = settings.keys.action(for: KeyCombo(event)) {
            perform(action)
        } else if let text = quickSearchStart(event) {
            quickSearch.open(in: activeView, mode: .search, text: text)
        } else if event.keyCode == KeyCode.escape, activeView.model.quickFilter != nil {
            // Esc in the panel removes a kept quick filter.
            activeView.model.setQuickFilter(nil, visibleRows: activeView.visibleRows)
            activeView.needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }

    /// The text that starts Quick Search for this key event, per Options → Quick Search, or nil.
    /// Shortcuts are checked first, so bound keys (hjkl, 5–8 …) keep working in "letter alone" mode.
    func quickSearchStart(_ event: NSEvent) -> String? {
        let mods = KeyCombo(event).modifiers.subtracting(.shift)
        let wanted: KeyCombo.Modifiers
        switch settings.quickSearch.activation {
        case .off: return nil
        case .controlOption: wanted = [.control, .option]
        case .option: wanted = [.option]
        case .lettersOnly: wanted = []
        }
        guard mods == wanted, let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let scalar = chars.unicodeScalars.first else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-*?~#@&()[]+"))
        return allowed.contains(scalar) ? chars : nil
    }

    public func perform(_ action: CommandAction) {
        let panel = activeView
        let rows = panel.visibleRows
        // Remote panels: navigation needs the listing from the server first.
        if panel.model.isRemote, [.open, .enterFolder, .parentFolder, .goRoot, .goHome].contains(action),
           ftp.navigate(panel, action) {
            panel.needsDisplay = true
            return
        }
        switch action {
        case .switchPanel:
            model.toggleActive()
            syncActive()
            return
        case .leftLocationMenu:
            showLocationMenu(for: .left)
            return
        case .rightLocationMenu:
            showLocationMenu(for: .right)
            return
        case .cursorUp: panel.model.moveCursor(by: -1, visibleRows: rows)
        case .cursorDown: panel.model.moveCursor(by: 1, visibleRows: rows)
        case .pageUp: panel.model.pageUp(visibleRows: rows)
        case .pageDown: panel.model.pageDown(visibleRows: rows)
        case .firstItem: panel.model.moveToStart(visibleRows: rows)
        case .lastItem: panel.model.moveToEnd(visibleRows: rows)
        case .open: openCurrent()
        case .enterFolder:
            if case .failed = panel.model.enterCurrentFolder(visibleRows: rows) { NSSound.beep() }
        case .parentFolder:
            if case .failed = panel.model.goUp(visibleRows: rows) { NSSound.beep() }
        case .toggleSelection: toggleSelection(in: panel)
        case .invertSelection: panel.model.invertMarks()
        case .selectByMask: markByMask(true, in: panel)
        case .deselectByMask: markByMask(false, in: panel)
        case .goHome:
            if case .failed = panel.model.goHome(visibleRows: rows) { NSSound.beep() }
        case .goRoot:
            if case .failed = panel.model.goToRoot(visibleRows: rows) { NSSound.beep() }
        case .copy: fileCommands.copy()
        case .move: fileCommands.move()
        case .newFolder: fileCommands.newFolder()
        case .delete: fileCommands.delete()
        case .findFiles: findFiles.present()
        case .synchronizeDirs: synchronize.present()
        case .view: if !ftp.view(panel) { view(in: panel) }
        case .ftpConnect: ftp.managerWindow.present()
        case .ftpNewConnection: ftp.managerWindow.present(newConnection: true)
        case .ftpDisconnect: ftp.disconnectActive()
        case .ftpTransfers: ftp.transfersWindow.present()
        case .swapPanels: swapPanels()
        case .openTerminal: openTerminal()
        case .refresh:
            if panel.model.isRemote { ftp.refresh(panel) } else { panel.model.reload(visibleRows: rows); panel.invalidateVolumeInfo() }
        case .quickFilter:
            quickSearch.open(in: panel, mode: .filter, text: panel.model.quickFilter ?? "")
            return
        case .reopenQuickSearch:
            quickSearch.open(in: panel, mode: .search, text: quickSearch.lastText)
            return
        }
        panel.needsDisplay = true
    }

    /// Opens the configured terminal app in the active panel's folder (Options → Operation).
    public func openTerminal() {
        let panel = activeView
        guard !panel.model.isRemote else {
            showHint("Open terminal works for folders on this Mac (this panel shows a server).", duration: 3)
            return NSSound.beep()
        }
        let ops = settings.operation
        let launch = TerminalLauncher.launch(appPath: ops.terminalApp, template: ops.terminalArguments, folder: panel.model.directory)
        let config = NSWorkspace.OpenConfiguration()
        let report: (Error?) -> Void = { [weak self] error in
            guard let error = error else { return }
            DispatchQueue.main.async {
                self?.showHint("Could not open the terminal: \(error.localizedDescription)", duration: 4)
                NSSound.beep()
            }
        }
        switch launch {
        case let .openFolder(app, folder):
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: config) { _, e in report(e) }
        case let .run(app, arguments):
            config.arguments = arguments
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, e in report(e) }
        }
    }

    /// Ctrl+U: the left panel's contents go right and the right panel's go left; the active side stays.
    public func swapPanels() {
        quickSearch.close(clearFilter: false)
        model.left.exchangeContents(with: model.right)
        swap(&leftView.remote, &rightView.remote)
        ftp.panelsSwapped()
        for view in [leftView, rightView] {
            view.invalidateVolumeInfo()
            view.needsDisplay = true
        }
        updateFunctionBar()
    }

    private func openCurrent() {
        let panel = activeView
        // Remote panels (Enter and double-click alike) download files and fetch folders first.
        if ftp.navigate(panel, .open) { panel.needsDisplay = true; return }
        switch panel.model.openCurrent(visibleRows: panel.visibleRows) {
        case .file(let url) where url.isFileURL: onOpenFile?(url)
        case .file: NSSound.beep()
        case .failed: NSSound.beep()
        case .navigated, .none: break
        }
        panel.needsDisplay = true
    }

    // MARK: Selection and folder sizes

    private var sizingFlags: [ObjectIdentifier: [CancelFlag]] = [:]

    /// Space: toggle the mark; optionally work out a folder's size and move down (Options → Operation).
    private func toggleSelection(in panel: PanelView) {
        let entry = panel.model.toggleMarkAtCursor()
        if let entry = entry, entry.kind == .directory, settings.operation.spaceCalculatesFolderSize, !panel.model.isRemote,
           panel.model.folderSize(for: entry) == nil, !panel.pendingSizes.contains(entry.name) {
            calculateSize(of: entry, in: panel)
        }
        if settings.operation.spaceMovesCursorDown {
            panel.model.moveCursor(by: 1, visibleRows: panel.visibleRows)
        }
    }

    /// The mask last used with "+" or "-", offered again next time ("*.*" at first).
    public private(set) var lastMask = "*.*"

    private func markByMask(_ mark: Bool, in panel: PanelView) {
        let message = (mark ? "Select" : "Deselect")
            + " files matching (e.g. *.txt;*.jpg — end a mask with / for folders):"
        guard let text = fileCommands.prompts.askText(title: mark ? "Select Files" : "Deselect Files",
                                                      message: message, defaultValue: lastMask,
                                                      okTitle: mark ? "Select" : "Deselect") else { return }
        lastMask = text
        let mask = FileMask(text)
        if mask.isEmpty || panel.model.setMarks(mark, matching: mask) == 0 { NSSound.beep() }
        panel.needsDisplay = true
    }

    /// "3" / F3: Lister for a file (n / p step through the panel's files); on a folder, its size.
    @discardableResult
    func view(in panel: PanelView) -> ListerWindowController? {
        guard let entry = panel.model.currentEntry, entry.kind != .parent else { NSSound.beep(); return nil }
        if entry.kind == .directory {
            if panel.model.folderSize(for: entry) == nil, !panel.pendingSizes.contains(entry.name) {
                calculateSize(of: entry, in: panel)
            }
            return nil
        }
        let files = panel.model.entries.filter { $0.kind == .file }
        let index = files.firstIndex { $0.url == entry.url } ?? 0
        return openLister(files: files.map(\.url), index: index)
    }

    /// Opens Lister on `files[index]`; n / p step through `files`. Used by the panels and Find Files.
    @discardableResult
    public func openLister(files: [URL], index: Int) -> ListerWindowController {
        let lister = ListerWindowController(files: files, index: index)
        lister.onClose = { [weak self] closed in self?.listers.removeAll { $0 === closed } }
        listers.append(lister)
        lister.present()
        return lister
    }

    private func calculateSize(of entry: FileEntry, in panel: PanelView) {
        let flag = CancelFlag()
        sizingFlags[ObjectIdentifier(panel), default: []].append(flag)
        let directory = panel.model.directory
        let url = entry.url
        let name = entry.name
        panel.pendingSizes.insert(name)
        sizingQueue.async { [weak self, weak panel] in
            let size = FolderSizer.totalSize(of: url, isCancelled: { flag.isCancelled })
            DispatchQueue.main.async {
                guard let panel = panel else { return }
                self?.sizingFlags[ObjectIdentifier(panel)]?.removeAll { $0 === flag }
                guard !flag.isCancelled else { return }
                panel.pendingSizes.remove(name)
                panel.model.setFolderSize(size, for: name, in: directory)
                panel.needsDisplay = true
            }
        }
    }

    private func cancelSizing(for panel: PanelView) {
        sizingFlags[ObjectIdentifier(panel)]?.forEach { $0.cancel() }
        sizingFlags[ObjectIdentifier(panel)] = []
        panel.pendingSizes = []
    }

    // MARK: Location menu (⌥1 / ⌥2)

    /// Builds the menu for one panel: the cursor panel's folder, home, then the drives.
    public func locationMenu(for side: CommanderModel.Side) -> LocationMenu {
        LocationMenu(cursorFolder: model.active.directory,
                     home: FileManager.default.homeDirectoryForCurrentUser,
                     drives: drivesProvider())
    }

    public func showLocationMenu(for side: CommanderModel.Side) {
        let panel = view(for: side)
        let location = locationMenu(for: side)
        let menu = NSMenu(title: "Location")
        menu.autoenablesItems = false
        for (index, item) in location.items.enumerated() {
            if index == 2 { menu.addItem(.separator()) }
            // Digits pick an entry straight from the keyboard, like Total Commander's drive letters.
            let key = index < 9 ? String(index + 1) : ""
            let menuItem = NSMenuItem(title: LocationMenu.title(for: item), action: #selector(locationChosen(_:)),
                                      keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = []
            menuItem.target = self
            menuItem.representedObject = LocationChoice(side: side, url: item.url)
            menuItem.image = Self.menuIcon(for: item)
            menu.addItem(menuItem)
        }
        presentMenu(menu, panel)
    }

    @objc private func locationChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? LocationChoice else { return }
        jump(choice.side, to: choice.url)
    }

    /// Sends one panel to a folder and gives it the focus.
    public func jump(_ side: CommanderModel.Side, to url: URL) {
        let panel = view(for: side)
        if panel.model.isRemote { ftp.disconnect(side) }   // a local place ends the FTP session
        if case .failed = panel.model.go(to: url, visibleRows: panel.visibleRows) { NSSound.beep() }
        activate(side)
        panel.needsDisplay = true
    }

    private static func menuIcon(for item: LocationMenu.Item) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: item.url.path).copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

private final class LocationChoice: NSObject {
    let side: CommanderModel.Side
    let url: URL
    init(side: CommanderModel.Side, url: URL) {
        self.side = side
        self.url = url
    }
}


extension KeyCombo {
    /// The combo an AppKit key event represents (only ⌃ ⌥ ⇧ ⌘ count as modifiers).
    public init(_ event: NSEvent) {
        let flags = event.modifierFlags
        var m: Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        self.init(event.keyCode, m)
    }
}
