import AppKit
import UniformTypeIdentifiers

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
    private(set) lazy var multiRename = MultiRenameWindowController(commander: self)
    public private(set) lazy var findFiles = FindFilesWindowController(commander: self)
    public private(set) lazy var quickSearch = QuickSearchController(commander: self)
    public private(set) lazy var synchronize = SyncWindowController(commander: self)
    /// FTP connections, remote navigation and transfers.
    public private(set) lazy var ftp = FTPController(commander: self)
    /// Open Lister windows (several can be open, as in Total Commander).
    public private(set) var listers: [ListerWindowController] = []

    /// Saves settings changed from the View menu (hidden files, button bar, brackets).
    public var onSettingsChange: ((Settings) -> Void)?
    /// Last mask typed for View → Show → Custom (⌃F12).
    private var lastShowMask = "*.txt *.md"

    /// The lister for folders on this Mac, following View → Hidden files.
    public var localLister: FileSystemLister { FileSystemLister(showHidden: settings.display.showHiddenFiles) }

    public var settings: Settings = .standard {
        didSet {
            applySettingsToPanels(oldValue: oldValue)
            applySettingsToChrome(oldValue: oldValue)
            needsLayout = true
            needsDisplay = true
        }
    }

    private func applySettingsToPanels(oldValue: Settings) {
        for view in [leftView, rightView] {
            if !view.model.isRemote, (view.model.lister as? FileSystemLister)?.showHidden != settings.display.showHiddenFiles {
                view.model.setLister(localLister, visibleRows: view.visibleRows)
            }
            view.theme = settings.theme
            view.display = settings.display
            view.contextMenuHold = settings.operation.contextMenuHold
        }
        if settings.operation.autoRefresh != oldValue.operation.autoRefresh { watch(.left); watch(.right) }
    }

    private func applySettingsToChrome(oldValue: Settings) {
        (fileCommands.prompts as? AlertPrompts)?.sizeFormat = settings.display.sizeFormat
        if ftp.transfersWindow.sizeFormat != settings.display.sizeFormat { ftp.transfersWindow.sizeFormat = settings.display.sizeFormat }
        for bar in [leftTabBar, rightTabBar] { bar.theme = settings.theme }
        functionBar.theme = settings.theme
        functionBar.keys = settings.keys
        functionBar.isHidden = !settings.display.showFunctionKeyBar
        if ftp.transfers.limits != settings.operation.transferLimits { ftp.transfers.limits = settings.operation.transferLimits }
        _ = oldValue
    }

    /// Mounted drives for the location menu; replaceable in tests.
    public var drivesProvider: () -> [LocationMenu.Item] = LocationMenu.mountedDrives
    /// Shows the location menu under a panel's drive bar; replaceable in tests (popping up blocks).
    public var presentMenu: (NSMenu, PanelView) -> Void = Modal.popUp
    /// Where folder sizes are worked out.
    public var sizingQueue = DispatchQueue(label: "ClassicCommander.folderSize", qos: .userInitiated)

    /// A panel moved to another folder (also by swapping panels); the app remembers it for the next launch.
    public var onFolderChange: ((CommanderModel.Side, URL) -> Void)?
    /// The tabs of each panel (the active tab is the folder the panel shows).
    public private(set) var tabs: [CommanderModel.Side: PanelTabs] = [:]
    let leftTabBar = TabBarView(), rightTabBar = TabBarView()
    /// Tabs were opened, closed, switched or moved to another folder (the app remembers them).
    public var onTabsChange: ((CommanderModel.Side, PanelTabs) -> Void)?

    public init(model: CommanderModel) {
        self.model = model
        leftView = PanelView(model: model.left)
        rightView = PanelView(model: model.right)
        super.init(frame: .zero)
        for (view, side) in [(leftView, CommanderModel.Side.left), (rightView, .right)] {
            addSubview(view)
            wirePanel(view, side: side)
        }
        for (bar, side) in [(leftTabBar, CommanderModel.Side.left), (rightTabBar, .right)] {
            let pView = view(for: side)
            tabs[side] = PanelTabs(folder: pView.model.directory)
            bar.tabs = tabs[side]!
            bar.onSelect = { [weak self] i in self?.selectTab(i, side: side) }
            bar.onClose = { [weak self] i in self?.closeTab(i, side: side) }
            bar.onNew = { [weak self] in self?.newTab(side) }
            pView.addSubview(bar)
        }
        watch(.left)
        watch(.right)
        addSubview(functionBar)
        functionBar.onAction = { [weak self] action in
            self?.window?.makeFirstResponder(self)
            self?.perform(action)
        }
        syncActive()
    }

    private func wirePanel(_ view: PanelView, side: CommanderModel.Side) {
        view.onActivate = { [weak self] in self?.activate(side) }
        view.onOpen = { [weak self] in self?.openCurrent() }
        view.onLocationMenu = { [weak self] in self?.showLocationMenu(for: side) }
        view.onHotlist = { [weak self] in self?.showHotlist(for: side) }
        view.onShowHint = { [weak self] hint in self?.showHint(hint, duration: 2.5) }
        view.onNavigateToPath = { [weak self, weak view] path in self?.navigateRemotePath(path, in: view) ?? false }
        // After the drop has finished (the copy dialog must not run inside the drag).
        view.onDrop = { [weak self] drop in DispatchQueue.main.async { self?.drop(drop) } }
        view.onFilesChanged = { [weak self] in self?.reloadPanels() }
        view.onContextMenu = { [weak self, weak view] point in self?.openContextMenu(at: point, in: view) }
        view.onNavigate = { [weak self] action in self?.activate(side); self?.perform(action) }
        view.model.onDirectoryChange = { [weak self, weak view] in self?.handleDirectoryChange(in: view, side: side) }
    }

    private func navigateRemotePath(_ path: String, in view: PanelView?) -> Bool {
        guard let view = view, view.model.isRemote, let session = ftp.session(for: view) else { return false }
        let stripped = stripRemoteAddress(path, in: view)
        let (dir, mask) = PanelView.parsePathAndMask(stripped, currentDirectory: view.model.directory.path)
        view.model.setShowFilter(Self.showFilter(forMask: mask), visibleRows: view.visibleRows)
        _ = ftp.reveal(session.url(for: dir), in: view)
        return true
    }

    private func stripRemoteAddress(_ path: String, in view: PanelView) -> String {
        guard let addr = ftp.displayAddress(of: view.model.directory), path.hasPrefix(addr) else { return path }
        return String(path.dropFirst(addr.count))
    }

    private static func showFilter(forMask mask: String?) -> PanelShowFilter {
        (mask == nil || mask == "*.*" || mask == "*") ? .all : .mask(mask!)
    }

    private func openContextMenu(at point: NSPoint, in view: PanelView?) {
        guard let view = view else { return }
        Modal.popUpHeld(contextMenu(for: view), at: point, in: view)
    }

    private func handleDirectoryChange(in view: PanelView?, side: CommanderModel.Side) {
        guard let view = view else { return }
        cancelSizing(for: view)
        watch(side)
        tabs[side]?.update(folder: view.model.directory, focus: view.model.currentEntry?.name)
        tabsChanged(side)
        onFolderChange?(side, view.model.directory)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: Divider between the panels

    static let margin: CGFloat = 2, gap: CGFloat = 6
    /// The left panel's share of the width (0.5 = halves). Dragging the divider changes it.
    public var splitRatio: CGFloat = 0.5 {
        didSet { if splitRatio != oldValue { needsLayout = true; window?.invalidateCursorRects(for: self) } }
    }
    /// The divider was moved (the app remembers the position).
    public var onSplitChange: ((CGFloat) -> Void)?
    /// The gap between the panels, where the divider is dragged.
    var dividerRect: NSRect { NSRect(x: leftView.frame.maxX, y: 0, width: Self.gap, height: leftView.frame.height) }
    private var draggingDivider = false

    /// The left panel's width for a ratio: never narrower than a panel's minimum on either side.
    static func leftWidth(ratio: CGFloat, total: CGFloat) -> CGFloat {
        let minimum = min(PanelView.minimumWidth, total / 2)
        return floor(min(max(total * ratio, minimum), total - minimum))
    }

    /// The ratio for the divider dragged to `x`; close to the middle it snaps to 50 %.
    static func ratio(forDividerAt x: CGFloat, total: CGFloat) -> CGFloat {
        guard total > 0 else { return 0.5 }
        let left = leftWidth(ratio: (x - margin - gap / 2) / total, total: total)
        return abs(left - total / 2) < 12 ? 0.5 : left / total
    }

    public override func layout() {
        super.layout()
        let margin = Self.margin, gap = Self.gap
        let width = max(0, bounds.width - 2 * margin - gap)
        let left = Self.leftWidth(ratio: splitRatio, total: width)
        let barHeight = settings.display.showFunctionKeyBar ? FunctionKeyBar.height : 0
        functionBar.frame = NSRect(x: margin, y: bounds.height - barHeight, width: bounds.width - 2 * margin, height: barHeight)
        let height = max(0, bounds.height - margin - barHeight)
        for (side, x, w) in [(CommanderModel.Side.left, margin, left), (.right, margin + left + gap, width - left)] {
            let pView = view(for: side)
            let tabHeight = showsTabs(side) ? TabBarView.height : 0
            pView.tabHeight = tabHeight
            pView.frame = NSRect(x: x, y: 0, width: w, height: height)
            let bar = tabBar(for: side)
            bar.isHidden = tabHeight == 0
            bar.frame = NSRect(x: 0, y: pView.layoutInfo.driveBar.maxY, width: w, height: tabHeight)
        }
    }

    public override func resetCursorRects() {
        addCursorRect(dividerRect, cursor: .resizeLeftRight)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard dividerRect.insetBy(dx: -2, dy: 0).contains(point) else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            // Double-click: halves again.
            splitRatio = 0.5
            onSplitChange?(splitRatio)
            return
        }
        draggingDivider = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard draggingDivider else { return super.mouseDragged(with: event) }
        let x = convert(event.locationInWindow, from: nil).x
        splitRatio = Self.ratio(forDividerAt: x, total: max(0, bounds.width - 2 * Self.margin - Self.gap))
        layoutSubtreeIfNeeded()
    }

    public override func mouseUp(with event: NSEvent) {
        guard draggingDivider else { return super.mouseUp(with: event) }
        draggingDivider = false
        onSplitChange?(splitRatio)
    }

    public override func draw(_ dirtyRect: NSRect) {
        settings.theme.chrome.nsColor.setFill()
        dirtyRect.fill()
    }

    public func view(for side: CommanderModel.Side) -> PanelView {
        side == .left ? leftView : rightView
    }

    public var activeView: PanelView { view(for: model.activeSide) }

    /// Files dropped on a panel (from a panel, Finder or another app): 5 Copy (or 6 Move) of exactly
    /// those files, with the usual dialog, into the drop's folder (local or on a server).
    func drop(_ drop: PanelDrop) {
        if let target = drop.target { activate(target === leftView ? .left : .right) }
        fileCommands.drop(drop)
    }

    public func activate(_ side: CommanderModel.Side) {
        model.activate(side)
        syncActive()
        window?.makeFirstResponder(self)
    }

    /// "Go to file": shows `url` in the active panel, cursor on it.
    public func reveal(_ url: URL) {
        focusRemotePanelIfNeeded(for: url)
        let panel = activeView
        if url.isRemoteLocation {
            // A file on a server: shown when this panel is connected to that server.
            if !ftp.reveal(url, in: panel) { NSSound.beep() }
        } else {
            revealLocalFile(url, in: panel)
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
    }

    private func revealLocalFile(_ url: URL, in panel: PanelView) {
        if panel.model.isRemote && url.isFileURL { ftp.disconnect(model.activeSide) }
        let folder = url.deletingLastPathComponent()
        if case .failed = panel.model.go(to: folder, visibleRows: panel.visibleRows) {
            NSSound.beep()
        }
        panel.model.focus(name: url.lastPathComponent, visibleRows: panel.visibleRows)
        panel.needsDisplay = true
    }

    private func focusRemotePanelIfNeeded(for url: URL) {
        if url.isRemoteLocation, otherPanelMatchesSession(of: url) {
            activate(model.activeSide.other)
        }
    }

    private func otherPanelMatchesSession(of url: URL) -> Bool {
        let targetID = RemoteSession.sessionID(of: url)
        return matchesOtherPanelSession(targetID: targetID, activeID: RemoteSession.sessionID(of: activeView.model.directory))
    }

    func matchesOtherPanelSession(targetID: UUID?, activeID: UUID?) -> Bool {
        if activeID == targetID { return false }
        return RemoteSession.sessionID(of: view(for: model.activeSide.other).model.directory) == targetID
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
        leftTabBar.isActive = leftView.isActive
        rightTabBar.isActive = rightView.isActive
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
        // "Letters alone": a typed letter always starts Quick Search, before plain-letter shortcuts.
        if let text = lettersOnlyQuickSearchText(for: event) {
            openQuickSearch(with: text)
        } else if !handleBindingOrQuickSearch(with: event) {
            super.keyDown(with: event)
        }
    }

    private func handleBindingOrQuickSearch(with event: NSEvent) -> Bool {
        if let action = settings.keys.action(for: KeyCombo(event)) { perform(action); return true }
        if let text = quickSearchStart(event) { openQuickSearch(with: text); return true }
        return clearPanelFiltersIfEscape(event)
    }

    private func lettersOnlyQuickSearchText(for event: NSEvent) -> String? {
        guard settings.quickSearch.activation == .lettersOnly, Self.isPlainLetter(event) else { return nil }
        return quickSearchStart(event)
    }

    private func openQuickSearch(with text: String) {
        let mode: QuickSearchController.Mode = settings.quickSearch.filterByDefault ? .filter : .search
        quickSearch.open(in: activeView, mode: mode, text: text)
    }

    private func clearPanelFiltersIfEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == KeyCode.escape,
              activeView.model.quickFilter != nil || activeView.model.showsMarkedOnly else { return false }
        // Esc in the panel removes a kept quick filter and shows the entries a selection hid.
        activeView.model.setQuickFilter(nil, visibleRows: activeView.visibleRows)
        activeView.model.showMarkedOnly(false, visibleRows: activeView.visibleRows)
        activeView.needsDisplay = true
        return true
    }

    /// A letter typed without ⌘ ⌃ ⌥ (⇧ allowed).
    static func isPlainLetter(_ event: NSEvent) -> Bool {
        guard KeyCombo(event).modifiers.subtracting(.shift).isEmpty, let chars = event.charactersIgnoringModifiers,
              chars.count == 1, let scalar = chars.unicodeScalars.first else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    // MARK: ⇧6 Rename in place

    /// ⇧6: edits the name right in the panel (the name, or the name with its extension, preselected).
    func renameInPlace(_ panel: PanelView) {
        guard let entry = panel.model.currentEntry, entry.kind != .parent, panel.model.virtualTitle == nil else { return NSSound.beep() }
        panel.beginRename(selectingExtension: settings.operation.renameSelectsExtension) { [weak self, weak panel] newName in
            guard let self = self, let panel = panel else { return }
            self.window?.makeFirstResponder(self)
            if let newName = newName { self.rename(entry, to: newName, in: panel) }
        }
    }

    /// Renames one entry (on this Mac or on the server) and keeps the cursor on it.
    func rename(_ entry: FileEntry, to newName: String, in panel: PanelView) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard name != entry.name else { return }
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            showHint("“\(name)” can't be a file name", duration: 2.5)
            return NSSound.beep()
        }
        if panel.model.isRemote {
            ftp.rename(entry, to: name, in: panel)
            return
        }
        let target = entry.url.deletingLastPathComponent().appendingPathComponent(name)
        // Only a change of upper/lowercase may land on "itself" (the Mac's disk ignores case).
        if FileManager.default.fileExists(atPath: target.path), name.lowercased() != entry.name.lowercased() {
            showHint("“\(name)” exists already", duration: 2.5)
            return NSSound.beep()
        }
        do {
            try FileManager.default.moveItem(at: entry.url, to: target)
        } catch {
            showHint("Rename failed: \(error.localizedDescription)", duration: 3)
            return NSSound.beep()
        }
        panel.model.reload(visibleRows: panel.visibleRows)
        panel.model.focus(name: name, visibleRows: panel.visibleRows)
        panel.needsDisplay = true
    }

    /// The text that starts Quick Search for this key event, per Options → Quick Search, or nil.
    /// Shortcuts are checked first, so bound keys (hjkl, 5–8 …) keep working in "letter alone" mode.
    func quickSearchStart(_ event: NSEvent) -> String? {
        guard let wanted = requiredQuickSearchModifiers,
              KeyCombo(event).modifiers.subtracting(.shift) == wanted,
              let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let scalar = chars.unicodeScalars.first else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-*?~#@&()[]+"))
        return allowed.contains(scalar) ? chars : nil
    }

    private var requiredQuickSearchModifiers: KeyCombo.Modifiers? {
        switch settings.quickSearch.activation {
        case .off: return nil
        case .controlOption: return [.control, .option]
        case .option: return [.option]
        case .lettersOnly: return []
        }
    }

    public func perform(_ action: CommandAction) {
        let panel = activeView
        let rows = panel.visibleRows
        // Remote panels: navigation needs the listing from the server first.
        if panel.model.isRemote, [.open, .enterFolder, .parentFolder, .goRoot, .goHome, .goDownloads].contains(action),
           ftp.navigate(panel, action) {
            panel.needsDisplay = true
            return
        }
        if performNavigation(action, in: panel, rows: rows)
            || performSelection(action, in: panel, rows: rows)
            || performViewAndSort(action, in: panel, rows: rows) {
            return
        }
        performFileOperation(action, in: panel)
        panel.needsDisplay = true
    }

    /// Returns true when the action already handled its own redraw / return.
    private func performNavigation(_ action: CommandAction, in panel: PanelView, rows: Int) -> Bool {
        if performCursorMove(action, in: panel, rows: rows) { return true }
        return performFolderOrTabNav(action, in: panel, rows: rows)
    }

    private static let cursorMoveActions: [CommandAction: (PanelModel, Int) -> Void] = [
        .cursorUp: { $0.moveCursor(by: -1, visibleRows: $1) },
        .cursorDown: { $0.moveCursor(by: 1, visibleRows: $1) },
        .pageUp: { $0.pageUp(visibleRows: $1) },
        .pageDown: { $0.pageDown(visibleRows: $1) },
        .firstItem: { $0.moveToStart(visibleRows: $1) },
        .lastItem: { $0.moveToEnd(visibleRows: $1) },
    ]

    private func performCursorMove(_ action: CommandAction, in panel: PanelView, rows: Int) -> Bool {
        if let move = Self.cursorMoveActions[action] {
            move(panel.model, rows)
            panel.needsDisplay = true
            return true
        }
        return performPanelSwitchOrLocationMenu(action)
    }

    private func performPanelSwitchOrLocationMenu(_ action: CommandAction) -> Bool {
        if action == .switchPanel { model.toggleActive(); syncActive(); return true }
        guard let side = Self.locationMenuSide(for: action) else { return false }
        showLocationMenu(for: side)
        return true
    }

    private static func locationMenuSide(for action: CommandAction) -> CommanderModel.Side? {
        if action == .leftLocationMenu { return .left }
        return action == .rightLocationMenu ? .right : nil
    }

    private func performFolderOrTabNav(_ action: CommandAction, in panel: PanelView, rows: Int) -> Bool {
        if performFolderNav(action, in: panel, rows: rows) { return true }
        return performTabNav(action, in: panel)
    }

    private func beepIfFailed(_ result: PanelModel.OpenResult) {
        if case .failed = result { NSSound.beep() }
    }

    private static let folderNavActions: [CommandAction: (PanelModel, Int) -> PanelModel.OpenResult] = [
        .enterFolder: { $0.enterCurrentFolder(visibleRows: $1) },
        .parentFolder: { $0.goUp(visibleRows: $1) },
        .goHome: { $0.goHome(visibleRows: $1) },
        .goDownloads: { $0.goDownloads(visibleRows: $1) },
        .goRoot: { $0.goToRoot(visibleRows: $1) },
    ]

    private func performFolderNav(_ action: CommandAction, in panel: PanelView, rows: Int) -> Bool {
        if let nav = Self.folderNavActions[action] {
            beepIfFailed(nav(panel.model, rows))
        } else if action == .open {
            openCurrent()
        } else if action == .directoryHotlist {
            showHotlist(for: model.activeSide)
        } else {
            return false
        }
        panel.needsDisplay = true
        return true
    }

    private func performTabNav(_ action: CommandAction, in panel: PanelView) -> Bool {
        switch action {
        case .newTab: newTab(model.activeSide)
        case .closeTab: closeTab(tabs[model.activeSide]?.active ?? 0, side: model.activeSide)
        case .nextTab: stepTab(by: 1)
        case .previousTab: stepTab(by: -1)
        default: return false
        }
        panel.needsDisplay = true
        return true
    }

    private func stepTab(by delta: Int) {
        guard let t = tabs[model.activeSide], t.count > 1 else { NSSound.beep(); return }
        selectTab(t.neighbour(delta), side: model.activeSide)
    }

    private func performSelection(_ action: CommandAction, in panel: PanelView, rows: Int) -> Bool {
        if let kind = Self.copySelectionKinds[action] {
            copySelection(kind)
            panel.needsDisplay = true
            return true
        }
        if performMaskOrExtensionSelection(action, in: panel, rows: rows) || performMarkAction(action, in: panel, rows: rows) {
            panel.needsDisplay = true
            return true
        }
        return false
    }

    private func performMarkAction(_ action: CommandAction, in panel: PanelView, rows: Int) -> Bool {
        let handlers: [CommandAction: () -> Void] = [
            .toggleSelection: { self.toggleSelection(in: panel) },
            .invertSelection: { panel.model.invertMarks() },
            .selectAll: { panel.model.markAll(true) },
            .restoreSelection: { if panel.model.restoreMarks() == 0 { NSSound.beep() } },
            .showMarkedOnly: { panel.model.showMarkedOnly(!panel.model.showsMarkedOnly, visibleRows: rows) },
        ]
        guard let fn = handlers[action] else { return false }
        fn()
        return true
    }

    private func performMaskOrExtensionSelection(_ action: CommandAction, in panel: PanelView, rows: Int) -> Bool {
        let handlers: [CommandAction: () -> Void] = [
            .selectByMask: { self.markByMask(true, in: panel) },
            .deselectByMask: { self.markByMask(false, in: panel) },
            .deselectAll: { self.deselectAllEntries(in: panel, rows: rows) },
            .selectSameExtension: { self.markSameExtension(true, in: panel) },
            .deselectSameExtension: { self.markSameExtension(false, in: panel) },
        ]
        guard let fn = handlers[action] else { return false }
        fn()
        return true
    }

    private func deselectAllEntries(in panel: PanelView, rows: Int) {
        panel.model.markAll(false)
        if panel.model.showsMarkedOnly { panel.model.showMarkedOnly(false, visibleRows: rows) }
    }

    private func markSameExtension(_ mark: Bool, in panel: PanelView) {
        if panel.model.setMarksWithCurrentExtension(mark) == nil { NSSound.beep() }
        else if mark { applySelectionView(panel) }
    }

    private static let copySelectionKinds: [CommandAction: SelectionClipboard.Format] = [
        .copyNames: .names,
        .copyPaths: .paths,
        .copyNamesWithDetails: .namesWithDetails,
        .copyPathsWithDetails: .pathsWithDetails,
    ]

    private func performViewAndSort(_ action: CommandAction, in panel: PanelView, rows: Int) -> Bool {
        if performSortOrFilter(action, in: panel, rows: rows) { return true }
        if toggleDisplaySetting(action) { panel.needsDisplay = true; return true }
        return performRefreshOrQuickSearch(action, in: panel, rows: rows)
    }

    private func performRefreshOrQuickSearch(_ action: CommandAction, in panel: PanelView, rows: Int) -> Bool {
        switch action {
        case .refresh: refreshPanel(panel, rows: rows)
        case .quickFilter: quickSearch.open(in: panel, mode: .filter, text: panel.model.quickFilter ?? "")
        case .reopenQuickSearch: quickSearch.open(in: panel, mode: .search, text: quickSearch.lastText)
        default: return false
        }
        return true
    }

    private func refreshPanel(_ panel: PanelView, rows: Int) {
        if panel.model.isRemote { ftp.refresh(panel) } else { panel.model.reload(visibleRows: rows); panel.invalidateVolumeInfo() }
        panel.needsDisplay = true
    }

    private func toggleDisplaySetting(_ action: CommandAction) -> Bool {
        var s = settings
        switch action {
        case .toggleHiddenFiles: s.display.showHiddenFiles.toggle()
        case .toggleFunctionKeyBar: s.display.showFunctionKeyBar.toggle()
        case .toggleFolderBrackets: s.display.showFolderBrackets.toggle()
        default: return false
        }
        change(s)
        return true
    }

    private static let sortColumns: [CommandAction: SortColumn] = [
        .sortByName: .name,
        .sortByExtension: .ext,
        .sortByDate: .date,
        .sortBySize: .size,
    ]

    private func performSortOrFilter(_ action: CommandAction, in panel: PanelView, rows: Int) -> Bool {
        if let col = Self.sortColumns[action] {
            panel.model.sort(by: col, visibleRows: rows)
            panel.needsDisplay = true
            return true
        }
        return performFilterOrOrderAction(action, in: panel, rows: rows)
    }

    private func performFilterOrOrderAction(_ action: CommandAction, in panel: PanelView, rows: Int) -> Bool {
        switch action {
        case .sortUnsorted: panel.model.setSort(.unsorted, visibleRows: rows)
        case .reverseOrder: panel.model.reverseSort(visibleRows: rows)
        case .showAllFiles: panel.model.setShowFilter(.all, visibleRows: rows)
        case .showPrograms: panel.model.setShowFilter(.programs, visibleRows: rows)
        case .showCustomFilter: return applyCustomFilter(in: panel, rows: rows)
        default: return false
        }
        panel.needsDisplay = true
        return true
    }

    private func applyCustomFilter(in panel: PanelView, rows: Int) -> Bool {
        guard let mask = askShowMask() else { return true }
        panel.model.setShowFilter(mask.isEmpty ? .all : .mask(mask), visibleRows: rows)
        panel.needsDisplay = true
        return true
    }

    private func performFileOperation(_ action: CommandAction, in panel: PanelView) {
        if performFileTransferOrTool(action, in: panel) { return }
        performWindowOrConnection(action, in: panel)
    }

    private func performFileTransferOrTool(_ action: CommandAction, in panel: PanelView) -> Bool {
        if performFileTransferAction(action, in: panel) { return true }
        let tools: [CommandAction: () -> Void] = [
            .changeAttributes: { self.changeAttributes(for: panel) },
            .multiRename: { self.openMultiRename(in: panel) },
            .findFiles: { self.findFiles.present() },
            .synchronizeDirs: { self.synchronize.present() },
        ]
        guard let fn = tools[action] else { return false }
        fn()
        return true
    }

    private func openMultiRename(in panel: PanelView) {
        if panel.model.entries.contains(where: { $0.kind != .parent }) { multiRename.present(for: panel) }
        else { NSSound.beep() }
    }

    private static let fileTransferActions: [CommandAction: (CommanderView, PanelView) -> Void] = [
        .copy: { c, _ in c.fileCommands.copy() },
        .move: { c, _ in c.fileCommands.move() },
        .newFolder: { c, _ in c.fileCommands.newFolder() },
        .delete: { c, _ in c.fileCommands.delete() },
        .deletePermanently: { c, _ in c.fileCommands.delete(permanently: true) },
        .renameInPlace: { c, p in c.renameInPlace(p) },
        .packFiles: { c, _ in c.fileCommands.pack() },
        .unpackFiles: { c, _ in c.fileCommands.unpack() },
    ]

    private func performFileTransferAction(_ action: CommandAction, in panel: PanelView) -> Bool {
        guard let handler = Self.fileTransferActions[action] else { return false }
        handler(self, panel)
        return true
    }

    private func performWindowOrConnection(_ action: CommandAction, in panel: PanelView) {
        if action == .view {
            if !ftp.view(panel) { view(in: panel) }
            return
        }
        let handlers: [CommandAction: () -> Void] = [
            .ftpConnect: { self.ftp.managerWindow.present() },
            .ftpNewConnection: { self.ftp.managerWindow.present(newConnection: true) },
            .ftpDisconnect: { self.ftp.disconnectActive() },
            .ftpTransfers: { self.ftp.transfersWindow.present() },
            .swapPanels: { self.swapPanels() },
            .openTerminal: { self.openTerminal() },
            .openInFinder: { self.openInFinder() },
            .compareByDate: { self.compareDirectories(by: .date) },
            .compareBySize: { self.compareDirectories(by: .size) },
        ]
        handlers[action]?()
    }

    public private(set) var chmodDialog: ChmodDialogController?

    public func changeAttributes(for panel: PanelView) {
        let targets = panel.model.operationTargets.filter { $0.kind != .parent }
        guard !targets.isEmpty else { NSSound.beep(); return }

        let dialog = ChmodDialogController(targets: targets) { [weak self, weak panel] state in
            guard let self = self, let panel = panel else { return }
            self.applyChmod(state: state, targets: targets, panel: panel)
        }
        self.chmodDialog = dialog
        dialog.present()
    }

    private func applyChmod(state: ChmodDialogController.PermissionState, targets: [FileEntry], panel: PanelView) {
        if panel.model.isRemote {
            applyRemoteChmod(mode: state.mode, recursive: state.recursive, targets: targets, panel: panel)
        } else {
            applyLocalChmod(mode: state.mode, recursive: state.recursive, targets: targets, panel: panel)
        }
    }

    private func applyRemoteChmod(mode: Int, recursive: Bool, targets: [FileEntry], panel: PanelView) {
        guard let session = ftp.session(for: panel) else { return }
        ftp.commander?.showHint("Applying permissions…", duration: 10)
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak panel] in
            let count = targets.reduce(0) { $0 + Self.chmodRemoteTarget($1, mode: mode, recursive: recursive, session: session) }
            DispatchQueue.main.async {
                self?.ftp.commander?.showHint("Changed permissions on \(count) item\(count == 1 ? "" : "s")", duration: 1.5)
                if let panel = panel { self?.ftp.refresh(panel) }
            }
        }
    }

    private static func chmodRemoteTarget(_ target: FileEntry, mode: Int, recursive: Bool, session: RemoteSession) -> Int {
        let path = RemoteSession.path(of: target.url)
        do {
            try session.client.chmod(mode, of: path)
            return 1 + (recursive && target.kind == .directory ? chmodRemoteDescendants(at: path, mode: mode, session: session) : 0)
        } catch {
            return 0
        }
    }

    private static func chmodRemoteDescendants(at path: String, mode: Int, session: RemoteSession) -> Int {
        guard let walked = try? session.walk(path) else { return 0 }
        var count = 0
        for f in walked.files { try? session.client.chmod(mode, of: f.path); count += 1 }
        for d in walked.folders { try? session.client.chmod(mode, of: d); count += 1 }
        return count
    }

    private func applyLocalChmod(mode: Int, recursive: Bool, targets: [FileEntry], panel: PanelView) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak panel] in
            let count = targets.reduce(0) { $0 + Self.chmodLocalTarget($1, mode: mode, recursive: recursive) }
            DispatchQueue.main.async {
                self?.showHint("Changed permissions on \(count) item\(count == 1 ? "" : "s")", duration: 1.5)
                panel?.model.reload(visibleRows: panel?.visibleRows ?? 20)
                panel?.needsDisplay = true
            }
        }
    }

    private static func chmodLocalTarget(_ target: FileEntry, mode: Int, recursive: Bool) -> Int {
        let fm = FileManager.default
        do {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.url.path)
            var count = 1
            if recursive && target.kind == .directory {
                let walker = fm.enumerator(at: target.url, includingPropertiesForKeys: [.isDirectoryKey])
                while let item = walker?.nextObject() as? URL {
                    try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: item.path)
                    count += 1
                }
            }
            return count
        } catch {
            return 0
        }
    }

    /// Applies a settings change made here and has it saved (Options shows it too).
    private func change(_ new: Settings) {
        settings = new
        onSettingsChange?(new)
    }

    /// View → Show → Custom (⌃F12): asks for a mask like "*.txt *.md" or "*.* | *.tmp".
    private func askShowMask() -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Show only files matching"
        alert.informativeText = "e.g. *.txt *.md   or   *.* | *.tmp *.log  (after | : excluded). Folders are always shown. Empty shows all files."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        if case .mask(let current) = activeView.model.showFilter { field.stringValue = current } else { field.stringValue = lastShowMask }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Show")
        alert.addButton(withTitle: "Cancel")
        guard Modal.run(alert) == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { lastShowMask = text }
        return text
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
        Modal.launch(launch, failed: reportTerminalFailure)
    }

    // MARK: Context menu (long right-click)

    /// What a long right-click offers for the marked entries (or the one under the cursor).
    func contextMenu(for panel: PanelView) -> NSMenu {
        let menu = NSMenu(title: "Context")
        let local = !panel.model.isRemote
        let groups: [[(String, CommandAction)]] = [
            [("Open", .open), ("View", .view)],
            [("Copy…", .copy), ("Move / Rename…", .move), ("Delete", .delete), ("New Folder…", .newFolder)],
            [("Change Attributes…", .changeAttributes)],
            [("Copy File Path", .copyPaths), ("Copy Name", .copyNames),
             ("Copy Names with Details", .copyNamesWithDetails), ("Copy Paths with Details", .copyPathsWithDetails)],
            local ? [("Open in Finder", .openInFinder), ("Open Terminal Here", .openTerminal)] : [],
        ]
        for (index, group) in groups.enumerated() where !group.isEmpty {
            appendContextGroup(group, to: menu, includeOpenWith: index == 0 && local, panel: panel)
        }
        return menu
    }

    private func appendContextGroup(_ group: [(String, CommandAction)], to menu: NSMenu, includeOpenWith: Bool, panel: PanelView) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for (title, action) in group {
            let item = NSMenuItem(title: title, action: #selector(contextCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
        // Open With…, right after Open / View, for files and folders on this Mac.
        if includeOpenWith, let entry = panel.model.currentEntry, entry.kind != .parent {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = openWithMenu(for: panel.model.operationTargets.map(\.url))
            menu.addItem(openWith)
        }
    }

    /// The apps that can open these files (the default one first), then "Other…".
    func openWithMenu(for urls: [URL]) -> NSMenu {
        let menu = NSMenu(title: "Open With")
        guard let first = urls.first else { return menu }
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: first)
        var apps = workspace.urlsForApplications(toOpen: first)
        if let d = defaultApp { apps.removeAll { $0 == d }; apps.insert(d, at: 0) }
        for app in apps.prefix(30) {
            menu.addItem(openWithAppItem(app, urls: urls, isDefault: app == defaultApp))
        }
        if !apps.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "Other…", action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        other.representedObject = OpenWithChoice(urls: urls, app: nil)
        menu.addItem(other)
        return menu
    }

    private func openWithAppItem(_ app: URL, urls: [URL], isDefault: Bool) -> NSMenuItem {
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let item = NSMenuItem(title: isDefault ? "\(name) (default)" : name, action: #selector(openWithChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = OpenWithChoice(urls: urls, app: app)
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    @objc func openWithChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? OpenWithChoice, let app = choice.app else { return }
        Modal.open(choice.urls, with: app)
    }

    /// Other…: pick any app in /Applications.
    @objc func openWithOther(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? OpenWithChoice else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        Modal.choose(panel, for: window) { urls in
            if let app = urls.first { Modal.open(choice.urls, with: app) }
        }
    }

    @objc func contextCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = CommandAction(rawValue: raw) else { return }
        perform(action)
    }

    // MARK: Select menu

    /// Select group, same extension, Compare directories: with Options → Operation → "hide all
    /// others", only the marked entries stay visible afterwards (Esc shows everything again).
    func applySelectionView(_ panel: PanelView) {
        guard settings.operation.selectionHidesOthers else { return }
        panel.model.showMarkedOnly(true, visibleRows: panel.visibleRows)
    }

    /// Select → Copy … to Clipboard, for the marked entries (or the one under the cursor).
    func copySelection(_ format: SelectionClipboard.Format) {
        let panel = activeView
        let items = panel.model.operationTargets
        guard !items.isEmpty else { return NSSound.beep() }
        let text = SelectionClipboard.text(items, format: format, path: { [weak self] entry in
            entry.url.isRemoteLocation ? self?.ftp.displayAddress(of: entry.url) ?? entry.url.path : entry.url.path
        }, folderSize: panel.model.folderSize(for:))
        Modal.copyToClipboard(text)
        showHint("Copied \(items.count) \(items.count == 1 ? "line" : "lines") to the clipboard", duration: 1.5)
    }

    /// Select → Compare Directories: marks in both panels what differs (names, then dates or sizes).
    func compareDirectories(by criterion: PanelComparison.Criterion) {
        let remote = leftView.model.isRemote || rightView.model.isRemote
        let result = PanelComparison.compare(left: leftView.model.allEntries, right: rightView.model.allEntries,
                                             by: criterion, tolerance: remote ? 60 : 2)
        leftView.model.setMarks(result.left)
        rightView.model.setMarks(result.right)
        for view in [leftView, rightView] {
            applySelectionView(view)
            view.needsDisplay = true
        }
        showHint(result.isIdentical ? "The folders contain the same files"
                 : "Different: \(result.left.count) on the left, \(result.right.count) on the right", duration: 3)
    }

    /// ⌘A (Edit → Select All) in a panel selects everything.
    public override func selectAll(_ sender: Any?) { perform(.selectAll) }

    /// Opens the active panel's folder in a Finder window, as `open .` does in Terminal.
    public func openInFinder() {
        let panel = activeView
        guard !panel.model.isRemote else {
            showHint("Open in Finder works for folders on this Mac (this panel shows a server).", duration: 3)
            return NSSound.beep()
        }
        Modal.open(panel.model.directory)
    }

    /// Launch errors arrive on a background thread.
    func reportTerminalFailure(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.terminalFailed(error) }
    }

    func terminalFailed(_ error: Error) {
        showHint("Could not open the terminal: \(error.localizedDescription)", duration: 4)
        NSSound.beep()
    }

    /// Ctrl+U: the left panel's contents go right and the right panel's go left; the active side stays.
    public func swapPanels() {
        quickSearch.close(clearFilter: false)
        // The tabs go along with the panels' contents.
        let leftTabs = tabs[.left], rightTabs = tabs[.right]
        tabs[.left] = rightTabs
        tabs[.right] = leftTabs
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
        case .file(let url) where url.isFileURL: openLocalFile(url, in: panel)
        case .file, .failed: NSSound.beep()
        case .navigated, .none: break
        }
        panel.needsDisplay = true
    }

    private func openLocalFile(_ url: URL, in panel: PanelView) {
        guard panel.model.isInsideZip else { onOpenFile?(url); return }
        openZipTempFile(url)
    }

    private func openZipTempFile(_ url: URL) {
        if let temp = try? ZipArchive.extractToTemp(url: url) { onOpenFile?(temp) }
        else { NSSound.beep() }
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
        guard let text = askMaskPattern(mark: mark) else { return }
        lastMask = text
        let mask = FileMask(text)
        let hits = mask.isEmpty ? 0 : panel.model.setMarks(mark, matching: mask, folders: settings.operation.maskSelectsFolders)
        if hits == 0 { NSSound.beep() } else if mark { applySelectionView(panel) }
        panel.needsDisplay = true
    }

    private func askMaskPattern(mark: Bool) -> String? {
        let message = (mark ? "Select" : "Deselect")
            + " files matching (e.g. *.txt;*.jpg — end a mask with / for folders):"
        return fileCommands.prompts.askText(title: mark ? "Select Files" : "Deselect Files",
                                            message: message, defaultValue: lastMask,
                                            okTitle: mark ? "Select" : "Deselect")
    }

    /// "3" / F3: Lister for a file (n / p step through the panel's files); on a folder, its size.
    @discardableResult
    func view(in panel: PanelView) -> ListerWindowController? {
        guard let entry = panel.model.currentEntry, entry.kind != .parent else { NSSound.beep(); return nil }
        if entry.kind == .directory { viewFolderSize(of: entry, in: panel); return nil }
        return openListerForFile(entry, in: panel)
    }

    private func openListerForFile(_ entry: FileEntry, in panel: PanelView) -> ListerWindowController? {
        if panel.model.isInsideZip {
            guard let temp = try? ZipArchive.extractToTemp(url: entry.url) else { NSSound.beep(); return nil }
            return openLister(files: [temp], index: 0)
        }
        let files = panel.model.entries.filter { $0.kind == .file }
        let index = files.firstIndex { $0.url == entry.url } ?? 0
        return openLister(files: files.map(\.url), index: index, onNavigate: { [weak panel] url in
            Self.focusURL(url, in: panel)
        })
    }

    private static func focusURL(_ url: URL, in panel: PanelView?) {
        guard let panel = panel else { return }
        panel.model.focus(url: url, visibleRows: panel.visibleRows)
        panel.needsDisplay = true
    }

    private func viewFolderSize(of entry: FileEntry, in panel: PanelView) {
        if panel.model.folderSize(for: entry) == nil, !panel.pendingSizes.contains(entry.name) {
            calculateSize(of: entry, in: panel)
        }
    }

    /// Opens Lister on `files[index]`; n / p step through `files`. Used by the panels and Find Files.
    @discardableResult
    public func openLister(files: [URL], index: Int, onNavigate: ((URL) -> Void)? = nil) -> ListerWindowController {
        let lister = ListerWindowController(files: files, index: index)
        lister.onNavigate = onNavigate
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
        let menu = NSMenu(title: "Location")
        menu.autoenablesItems = false
        populateLocationMenu(menu, from: locationMenu(for: side), side: side)
        presentMenu(menu, panel)
    }

    private func populateLocationMenu(_ menu: NSMenu, from location: LocationMenu, side: CommanderModel.Side) {
        for (index, item) in location.items.enumerated() {
            if index == 2 { menu.addItem(.separator()) }
            menu.addItem(locationMenuItem(for: item, index: index, side: side))
        }
    }

    private func locationMenuItem(for item: LocationMenu.Item, index: Int, side: CommanderModel.Side) -> NSMenuItem {
        // Digits pick an entry straight from the keyboard, like Total Commander's drive letters.
        let key = index < 9 ? String(index + 1) : ""
        let menuItem = NSMenuItem(title: LocationMenu.title(for: item), action: #selector(locationChosen(_:)), keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = []
        menuItem.target = self
        menuItem.representedObject = LocationChoice(side: side, url: item.url)
        menuItem.image = Self.menuIcon(for: item)
        return menuItem
    }

    @objc private func locationChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? LocationChoice else { return }
        jump(choice.side, to: choice.url)
    }

    // MARK: Directory hotlist (quick locations)

    /// ▼ on the path bar or ⌃D: the saved quick locations, "Save current location…" and "Remove".
    public func showHotlist(for side: CommanderModel.Side) {
        let panel = view(for: side)
        activate(side)
        let button = panel.layoutInfo.hotlistButton
        Modal.popUp(hotlistMenu(for: side), at: NSPoint(x: button.minX, y: button.maxY), in: panel)
    }

    func hotlistMenu(for side: CommanderModel.Side) -> NSMenu {
        let menu = NSMenu(title: "Quick Locations")
        menu.autoenablesItems = false
        let saved = settings.quickLocations
        appendSavedHotlistItems(saved, to: menu, side: side)
        menu.addItem(makeAddHotlistItem(for: side))
        if !saved.isEmpty { menu.addItem(hotlistRemoveMenu(saved, side: side)) }
        return menu
    }

    private func appendSavedHotlistItems(_ saved: [QuickLocation], to menu: NSMenu, side: CommanderModel.Side) {
        guard !saved.isEmpty else { return }
        for (index, location) in saved.enumerated() {
            menu.addItem(hotlistItem(for: location, index: index, side: side))
        }
        menu.addItem(.separator())
    }

    private func makeAddHotlistItem(for side: CommanderModel.Side) -> NSMenuItem {
        let add = NSMenuItem(title: "Save Current Location…", action: #selector(saveHotlistLocation(_:)), keyEquivalent: "")
        add.target = self
        add.tag = side == .left ? 0 : 1
        add.isEnabled = !view(for: side).model.isRemote
        return add
    }

    private func hotlistItem(for location: QuickLocation, index: Int, side: CommanderModel.Side) -> NSMenuItem {
        // Digits pick a location straight from the keyboard.
        let item = NSMenuItem(title: location.name, action: #selector(hotlistChosen(_:)), keyEquivalent: index < 9 ? String(index + 1) : "")
        item.keyEquivalentModifierMask = []
        item.target = self
        item.toolTip = location.path
        item.representedObject = LocationChoice(side: side, url: URL(fileURLWithPath: location.path, isDirectory: true))
        item.image = Self.folderIcon(location.path)
        return item
    }

    private func hotlistRemoveMenu(_ saved: [QuickLocation], side: CommanderModel.Side) -> NSMenuItem {
        let remove = NSMenuItem(title: "Remove", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Remove")
        for (index, location) in saved.enumerated() {
            let item = NSMenuItem(title: location.name, action: #selector(removeHotlistLocation(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            sub.addItem(item)
        }
        remove.submenu = sub
        return remove
    }

    @objc func hotlistChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? LocationChoice else { return }
        jump(choice.side, to: choice.url)
    }

    /// Asks for a name (the folder's own by default) and adds the panel's folder to the hotlist;
    /// a folder already in it gets the new name. Folders on servers can't be saved.
    @objc func saveHotlistLocation(_ sender: NSMenuItem) {
        let panel = view(for: sender.tag == 0 ? .left : .right)
        guard !panel.model.isRemote else { return NSSound.beep() }
        saveLocalHotlistLocation(for: panel.model.directory)
    }

    private func saveLocalHotlistLocation(for directory: URL) {
        let path = directory.path
        guard let name = askHotlistName(for: directory, path: path) else { return }
        upsertQuickLocation(name: name, path: path)
        showHint("Saved “\(name)”: ▼ on the path bar or ⌃D goes there", duration: 2)
    }

    private func askHotlistName(for directory: URL, path: String) -> String? {
        let suggested = path == "/" ? "/" : directory.lastPathComponent
        return fileCommands.prompts.askText(title: "Save Current Location",
                                            message: "Name for \(path) in the quick locations:",
                                            defaultValue: suggested, okTitle: "Save")
    }

    private func upsertQuickLocation(name: String, path: String) {
        var new = settings
        if let i = new.quickLocations.firstIndex(where: { $0.path == path }) {
            new.quickLocations[i].name = name
        } else {
            new.quickLocations.append(QuickLocation(name: name, path: path))
        }
        change(new)
    }

    @objc func removeHotlistLocation(_ sender: NSMenuItem) {
        guard settings.quickLocations.indices.contains(sender.tag) else { return }
        var new = settings
        new.quickLocations.remove(at: sender.tag)
        change(new)
    }

    private static func folderIcon(_ path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path).copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// Finder's "Open With → ClassicCommander": a folder is shown; files (or a package such as an
    /// app) are shown in their folder with the cursor on the first and, for several, all marked.
    public func show(_ urls: [URL], in side: CommanderModel.Side) {
        guard let first = urls.first?.standardizedFileURL else { return }
        let isFolder = urls.count == 1 && Self.isFolderURL(first)
        let folder = isFolder ? first : first.deletingLastPathComponent()
        jump(side, to: folder)
        guard !isFolder else { return }
        markAndFocusShownFiles(urls, first: first, folder: folder, in: view(for: side))
    }

    private static func isFolderURL(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    private func markAndFocusShownFiles(_ urls: [URL], first: URL, folder: URL, in panel: PanelView) {
        let here = urls.map(\.standardizedFileURL).filter { $0.deletingLastPathComponent().path == folder.path }
        if here.count > 1 { panel.model.setMarks(Set(here.map(\.lastPathComponent))) }
        panel.model.focus(name: first.lastPathComponent, visibleRows: panel.visibleRows)
        panel.needsDisplay = true
    }

    // MARK: Refresh automatically

    /// One watcher per panel, for the folder it shows (none for servers, search results, or Off).
    private(set) var watchers: [CommanderModel.Side: DirectoryWatcher] = [:]

    /// (Re)starts watching the folder one panel shows, per Options → Operation.
    func watch(_ side: CommanderModel.Side) {
        let panel = view(for: side)
        watchers[side]?.stop()
        watchers[side] = panel.model.virtualTitle == nil
            ? DirectoryWatcher(folder: panel.model.directory, mode: settings.operation.autoRefresh) { [weak self, weak panel] in
                self?.folderChanged(panel)
            }
            : nil
    }

    /// Files changed in a watched folder: the panel re-reads it (cursor and marks stay).
    func folderChanged(_ panel: PanelView?) {
        guard let panel = panel, !panel.model.isRemote, panel.model.virtualTitle == nil, panel.renameField == nil else { return }
        panel.model.reload(visibleRows: panel.visibleRows)
        panel.needsDisplay = true
    }

    // MARK: Tabs

    func tabBar(for side: CommanderModel.Side) -> TabBarView { side == .left ? leftTabBar : rightTabBar }

    /// The tab bar shows with two or more tabs, or always (Options → Display).
    func showsTabs(_ side: CommanderModel.Side) -> Bool {
        settings.display.tabBar == .always || (tabs[side]?.count ?? 1) > 1
    }

    /// Redraws a tab bar (and the layout when it appears or goes) and reports the tabs.
    private func tabsChanged(_ side: CommanderModel.Side) {
        guard let t = tabs[side] else { return }
        let bar = tabBar(for: side)
        if bar.isHidden == showsTabs(side) { needsLayout = true }
        bar.tabs = t
        bar.isActive = model.activeSide == side
        onTabsChange?(side, t)
    }

    /// Restores saved tabs (the app does this at launch).
    public func restoreTabs(_ saved: PanelTabs, side: CommanderModel.Side) {
        tabs[side] = saved
        if saved.current.folder.path != view(for: side).model.directory.path {
            _ = view(for: side).model.go(to: saved.current.folder, visibleRows: view(for: side).visibleRows)
        }
        tabsChanged(side)
    }

    /// ⌃T: a new tab on the same folder, after the active one.
    public func newTab(_ side: CommanderModel.Side) {
        let panel = view(for: side)
        // The tab being left remembers where the cursor was.
        tabs[side]?.update(folder: panel.model.directory, focus: panel.model.currentEntry?.name)
        tabs[side]?.add(folder: panel.model.directory, focus: panel.model.currentEntry?.name)
        activate(side)
        tabsChanged(side)
    }

    /// Click on a tab (⌃Tab / ⌃⇧Tab): the panel goes to its folder, cursor where it was left.
    public func selectTab(_ index: Int, side: CommanderModel.Side) {
        guard var t = tabs[side], t.tabs.indices.contains(index) else { return }
        let panel = view(for: side)
        t.update(folder: panel.model.directory, focus: panel.model.currentEntry?.name)
        t.select(index)
        tabs[side] = t
        show(t.current, side: side)
    }

    public func hasMultipleTabs(in side: CommanderModel.Side) -> Bool {
        (tabs[side]?.count ?? 0) > 1
    }

    /// Middle-click or ⌘W / ⌃W: closes a tab; when only one tab remains, hides the window.
    public func closeTab(_ index: Int, side: CommanderModel.Side) {
        guard var t = tabs[side], t.count > 1 else {
            if let win = window {
                if win.styleMask.contains(.closable) {
                    win.performClose(nil)
                } else {
                    win.close()
                }
            }
            return
        }
        let changed = t.close(index)
        tabs[side] = t
        if changed { show(t.current, side: side) } else { tabsChanged(side) }
    }

    /// Shows a tab's folder in the panel. A server folder whose connection is closed goes home.
    private func show(_ tab: PanelTabs.Tab, side: CommanderModel.Side) {
        let panel = view(for: side)
        navigateToTabFolder(tab, in: panel, side: side)
        if let focus = tab.focus { panel.model.focus(name: focus, visibleRows: panel.visibleRows) }
        panel.needsDisplay = true
        tabsChanged(side)
    }

    private func navigateToTabFolder(_ tab: PanelTabs.Tab, in panel: PanelView, side: CommanderModel.Side) {
        if !tab.folder.isFileURL && ftp.session(for: panel) == nil {
            showHint("The server connection of this tab is closed", duration: 2.5)
            jump(side, to: FileManager.default.homeDirectoryForCurrentUser)
        } else if tab.folder.path != panel.model.directory.path || tab.folder.isFileURL != panel.model.directory.isFileURL {
            jump(side, to: tab.folder)
        } else {
            activate(side)
        }
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

/// What an "Open With" item opens, and with which app (nil: Other…).
final class OpenWithChoice: NSObject {
    let urls: [URL]
    let app: URL?
    init(urls: [URL], app: URL?) {
        self.urls = urls
        self.app = app
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
