import AppKit

/// Synchronize Directories, laid out like Total Commander's dialog:
///   [left path] >>   [file filter] ?   [right path] >>
///   [Compare]  Asymmetric / Subdirs / by content / ignore date / empty dirs
///              Show: → = ≠ ←  duplicates  singles          [Synchronize…] [Close]
///   Name | Size | Date | ⇔ | Date | Size | Name
///   Files found: … (Identical: …, Different: …, Unique left: …, Unique right: …)
/// Comparing never changes a file. "Synchronize…" opens a separate confirmation listing every
/// operation; only its Start button copies or deletes.
public final class SyncWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSMenuDelegate {

    weak var commander: CommanderView?
    private let defaults: UserDefaults
    /// Tests compare and synchronize synchronously.
    var runSynchronously = false

    let leftPath = NSComboBox()
    let rightPath = NSComboBox()
    let maskField = NSComboBox()
    private let leftBrowse = NSButton(title: ">>", target: nil, action: nil)
    private let rightBrowse = NSButton(title: ">>", target: nil, action: nil)
    private let maskHelp = NSButton(title: "?", target: nil, action: nil)
    let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    let onlySelectedBox = NSButton(checkboxWithTitle: "Only selected\n(in main window)", target: nil, action: nil)
    let asymmetricBox = NSButton(checkboxWithTitle: "Asymmetric", target: nil, action: nil)
    let subdirsBox = NSButton(checkboxWithTitle: "Subdirs", target: nil, action: nil)
    let byContentBox = NSButton(checkboxWithTitle: "by content", target: nil, action: nil)
    let ignoreDateBox = NSButton(checkboxWithTitle: "ignore date", target: nil, action: nil)
    let emptyDirsBox = NSButton(checkboxWithTitle: "empty dirs", target: nil, action: nil)
    let showRight = NSButton(title: "→", target: nil, action: nil)
    let showEqual = NSButton(title: "=", target: nil, action: nil)
    let showDifferent = NSButton(title: "≠", target: nil, action: nil)
    let showLeft = NSButton(title: "←", target: nil, action: nil)
    let showDuplicates = NSButton(title: "duplicates", target: nil, action: nil)
    let showSingles = NSButton(title: "singles", target: nil, action: nil)
    let synchronizeButton = NSButton(title: "Synchronize…", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    let table = SyncTableView()
    let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private(set) var comparison = SyncComparison()
    private(set) var visibleIndexes: [Int] = []
    private(set) var config: SyncConfiguration?
    private(set) var isComparing = false
    private var cancelFlag: CancelFlag?
    private(set) var confirmation: SyncConfirmationController?
    /// Open diff windows (View / 3), kept until closed.
    private var diffWindows: [DiffWindowController] = []
    /// The result of the last synchronisation, shown in front of the re-comparison summary.
    private var lastSyncSummary: String?

    private enum Key {
        static let options = "sync.options"
        static let masks = "sync.maskHistory"
    }

    private enum Column: String {
        case leftName, leftSize, leftDate, action, rightDate, rightSize, rightName
    }

    init(commander: CommanderView, defaults: UserDefaults = .standard) {
        self.commander = commander
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = AppWindows.title("Synchronize directories")
        AppWindows.style(window)
        window.minSize = NSSize(width: 900, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
        loadOptions()
        maskField.addItems(withObjectValues: defaults.stringArray(forKey: Key.masks) ?? ["*.*"])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens the dialog with the two panels' folders (Total Commander's behaviour).
    public func present() {
        if let c = commander, !isComparing {
            // Left against right, also when a panel is connected to a server (shown as its address).
            func text(_ model: PanelModel) -> String {
                model.isRemote ? c.ftp.displayAddress(of: model.directory) ?? model.directory.absoluteString : model.directory.path
            }
            leftPath.stringValue = text(c.leftView.model)
            rightPath.stringValue = text(c.rightView.model)
            let marked = !c.leftView.model.marked.isEmpty || !c.rightView.model.marked.isEmpty
            onlySelectedBox.isEnabled = marked
            if !marked { onlySelectedBox.state = .off }
        }
        if maskField.stringValue.isEmpty { maskField.stringValue = "*.*" }
        updateButtons()
        if let window = window { AppWindows.place(window) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Building

    private func buildContent() -> NSView {
        let buttons = [leftBrowse, rightBrowse, maskHelp, compareButton, synchronizeButton, closeButton]
        for b in buttons {
            b.bezelStyle = .rounded
            b.target = self
            b.action = #selector(buttonPressed(_:))
        }
        for b in [leftBrowse, rightBrowse, maskHelp] { b.widthAnchor.constraint(equalToConstant: 40).isActive = true }
        compareButton.keyEquivalent = "\r"
        closeButton.keyEquivalent = "\u{1b}"
        for f in [leftPath, rightPath] { f.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true }
        maskField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        maskField.stringValue = "*.*"
        maskField.toolTip = "Files to compare, e.g. *.*  or  *.txt;*.doc  or  * | *.tmp"

        for b in [asymmetricBox, subdirsBox, byContentBox, ignoreDateBox, emptyDirsBox, onlySelectedBox] {
            b.target = self
            b.action = #selector(optionChanged)
        }
        onlySelectedBox.font = .systemFont(ofSize: 11)
        asymmetricBox.toolTip = "Left is the master: the right side becomes an exact copy; files only on the right are marked for deletion."
        byContentBox.toolTip = "Files of equal size are also compared byte by byte."
        ignoreDateBox.toolTip = "Only size (and content) decides; dates are ignored."
        emptyDirsBox.toolTip = "Also list empty folders and folders that exist on one side only."

        // Show: toggle buttons. Colours follow the result list.
        let toggles: [(NSButton, NSColor, String)] = [
            (showRight, .systemGreen, "Show files to copy left → right"),
            (showEqual, .labelColor, "Show identical files"),
            (showDifferent, .systemRed, "Show different files without a direction"),
            (showLeft, .systemBlue, "Show files to copy right → left"),
            (showDuplicates, .labelColor, "Show files that exist on both sides"),
            (showSingles, .labelColor, "Show files that exist on one side only"),
        ]
        for (b, color, tip) in toggles {
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .regularSquare
            b.state = .on
            b.toolTip = tip
            b.target = self
            b.action = #selector(filterChanged)
            if b.title.count == 1 {
                b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                    .foregroundColor: color, .font: NSFont.boldSystemFont(ofSize: 16),
                ])
                b.widthAnchor.constraint(equalToConstant: 34).isActive = true
            } else {
                b.font = .boldSystemFont(ofSize: 12)
                b.widthAnchor.constraint(equalToConstant: 96).isActive = true
            }
        }
        let arrows = NSStackView(views: [showRight, showEqual, showDifferent, showLeft])
        arrows.spacing = 2
        let sideFilters = NSStackView(views: [showDuplicates, showSingles])
        sideFilters.orientation = .vertical
        sideFilters.spacing = 2
        let showBox = NSBox()
        showBox.title = "Show:"
        showBox.contentViewMargins = NSSize(width: 8, height: 6)
        let showRow = NSStackView(views: [arrows, sideFilters])
        showRow.spacing = 10
        showRow.translatesAutoresizingMaskIntoConstraints = false
        if let content = showBox.contentView {
            content.addSubview(showRow)
            NSLayoutConstraint.activate([
                showRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                showRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                showRow.topAnchor.constraint(equalTo: content.topAnchor),
                showRow.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        let options = NSStackView(views: [asymmetricBox, subdirsBox, byContentBox, ignoreDateBox, emptyDirsBox])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 2
        compareButton.font = .boldSystemFont(ofSize: 13)
        compareButton.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let compareColumn = NSStackView(views: [compareButton, onlySelectedBox])
        compareColumn.orientation = .vertical
        compareColumn.alignment = .leading
        compareColumn.spacing = 6
        let actions = NSStackView(views: [synchronizeButton, closeButton])
        actions.orientation = .vertical
        actions.spacing = 6
        // Small vertical stacks must fill and hug, or their buttons have no fixed position
        // (ambiguous layout: Compare once drifted up over the path field).
        for column in [compareColumn, actions, options] {
            column.distribution = .fill
            column.setHuggingPriority(.required, for: .vertical)
        }
        for b in [synchronizeButton, closeButton] { b.widthAnchor.constraint(equalToConstant: 140).isActive = true }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let pathsRow = NSStackView(views: [leftPath, leftBrowse, maskField, maskHelp, rightPath, rightBrowse])
        pathsRow.spacing = 6
        let controlsRow = NSStackView(views: [compareColumn, options, showBox, spinner, NSView(), actions])
        controlsRow.alignment = .top
        controlsRow.spacing = 18

        let columns: [(Column, String, CGFloat, NSTextAlignment)] = [
            (.leftName, "Name", 230, .left), (.leftSize, "Size", 80, .right), (.leftDate, "Date", 125, .left),
            (.action, "<=>", 44, .center),
            (.rightDate, "Date", 125, .left), (.rightSize, "Size", 80, .right), (.rightName, "Name", 230, .left),
        ]
        for (id, title, width, align) in columns {
            let c = NSTableColumn(identifier: .init(id.rawValue))
            c.title = title
            c.width = width
            c.headerCell.alignment = align
            if id == .action { c.minWidth = 44; c.maxWidth = 60 }
            c.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 18
        table.target = self
        table.action = #selector(tableClicked)
        table.doubleAction = #selector(tableDoubleClicked)
        table.owner = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        statusLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [pathsRow, controlsRow, scroll, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pathsRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            controlsRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            leftPath.widthAnchor.constraint(equalTo: rightPath.widthAnchor),
        ])
        return root
    }

    private func loadOptions() {
        let o = defaults.dictionary(forKey: Key.options) as? [String: Bool] ?? [:]
        asymmetricBox.state = (o["asymmetric"] ?? false) ? .on : .off
        subdirsBox.state = (o["subdirs"] ?? true) ? .on : .off
        byContentBox.state = (o["byContent"] ?? false) ? .on : .off
        ignoreDateBox.state = (o["ignoreDate"] ?? false) ? .on : .off
        emptyDirsBox.state = (o["emptyDirs"] ?? false) ? .on : .off
    }

    private func saveOptions() {
        defaults.set(["asymmetric": asymmetricBox.state == .on, "subdirs": subdirsBox.state == .on,
                      "byContent": byContentBox.state == .on, "ignoreDate": ignoreDateBox.state == .on,
                      "emptyDirs": emptyDirsBox.state == .on], forKey: Key.options)
    }

    // MARK: Comparing

    /// Reads the controls into a configuration (paths as typed, "~" expanded).
    func readConfiguration() -> SyncConfiguration {
        func url(_ text: String) -> URL {
            let t = text.trimmingCharacters(in: .whitespaces)
            if let remote = commander?.ftp.location(fromAddress: t) { return remote }
            if t.hasPrefix(RemoteSession.scheme + "://"), let u = URL(string: t) { return u }   // a closed connection
            return URL(fileURLWithPath: (t as NSString).expandingTildeInPath).standardizedFileURL
        }
        var c = SyncConfiguration(left: url(leftPath.stringValue), right: url(rightPath.stringValue))
        c.mask = maskField.stringValue.isEmpty ? "*.*" : maskField.stringValue
        c.asymmetric = asymmetricBox.state == .on
        c.subdirectories = subdirsBox.state == .on
        c.byContent = byContentBox.state == .on
        c.ignoreDate = ignoreDateBox.state == .on
        c.emptyDirectories = emptyDirsBox.state == .on
        if onlySelectedBox.state == .on, let cmd = commander {
            let names = cmd.leftView.model.marked.union(cmd.rightView.model.marked)
            c.onlyNames = names.isEmpty ? nil : names
        }
        return c
    }

    @objc func compare() {
        if isComparing {
            cancelFlag?.cancel()
            return
        }
        let cfg = readConfiguration()
        saveOptions()
        rememberMask()
        let flag = CancelFlag()
        cancelFlag = flag
        isComparing = true
        compareButton.title = "Stop"
        statusLabel.stringValue = "Comparing…"
        spinner.startAnimation(nil)
        updateButtons()

        let sessions = commander?.ftp.sessionLookup ?? { _ in nil }
        let work = { () -> Result<SyncComparison, Error> in
            Result { try SyncEngine.compare(cfg, sessions: sessions, isCancelled: { flag.isCancelled }) }
        }
        let done: (Result<SyncComparison, Error>) -> Void = { [weak self] result in
            guard let self = self else { return }
            self.isComparing = false
            self.cancelFlag = nil
            self.compareButton.title = "Compare"
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let c):
                self.config = cfg
                self.comparison = c
                self.applyFilter()
                var status = c.summary
                if let synced = self.lastSyncSummary {
                    status = synced + "   ·   " + status
                    self.lastSyncSummary = nil
                }
                if c.cancelled { status += "  - comparison aborted" }
                if !c.errors.isEmpty { status += "  ·  \(c.errors.count) could not be read" }
                self.statusLabel.stringValue = status
                self.statusLabel.toolTip = c.errors.isEmpty ? nil : c.errors.prefix(30).joined(separator: "\n")
            case .failure(let error):
                self.statusLabel.stringValue = (error as? SearchValidationError)?.message ?? error.localizedDescription
                if !self.runSynchronously { NSSound.beep() }
            }
            self.updateButtons()
        }
        if runSynchronously {
            done(work())
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                DispatchQueue.main.async { done(result) }
            }
        }
    }

    private func rememberMask() {
        let mask = maskField.stringValue
        guard !mask.isEmpty else { return }
        var history = defaults.stringArray(forKey: Key.masks) ?? []
        history.removeAll { $0 == mask }
        history.insert(mask, at: 0)
        defaults.set(Array(history.prefix(15)), forKey: Key.masks)
    }

    @objc private func optionChanged() {
        saveOptions()
    }

    // MARK: Filters and row actions

    private var showFilter: SyncShowFilter {
        var f = SyncShowFilter()
        f.copyRight = showRight.state == .on
        f.equal = showEqual.state == .on
        f.different = showDifferent.state == .on
        f.copyLeft = showLeft.state == .on
        f.duplicates = showDuplicates.state == .on
        f.singles = showSingles.state == .on
        return f
    }

    @objc func filterChanged() {
        applyFilter()
    }

    private func applyFilter() {
        let f = showFilter
        visibleIndexes = comparison.rows.indices.filter { f.shows(comparison.rows[$0]) }
        if let sort = table.sortDescriptors.first, let key = sort.key.flatMap(SyncEngine.SortKey.init(rawValue:)) {
            visibleIndexes = SyncEngine.sorted(visibleIndexes, of: comparison.rows, by: key, ascending: sort.ascending)
        }
        table.reloadData()
        updateButtons()
    }

    var visibleRows: [SyncRow] { visibleIndexes.map { comparison.rows[$0] } }

    /// Sets the action on the given visible rows, keeping each to what is possible for it.
    func setAction(_ action: SyncAction, forVisible rows: [Int]) {
        for v in rows where visibleIndexes.indices.contains(v) {
            let i = visibleIndexes[v]
            if SyncEngine.choices(for: comparison.rows[i]).contains(action) {
                comparison.rows[i].action = action
            }
        }
        table.reloadData(forRowIndexes: IndexSet(rows), columnIndexes: IndexSet(0..<table.numberOfColumns))
        updateButtons()
    }

    private func modify(_ change: (SyncRow) -> SyncAction) {
        let selected = Array(table.selectedRowIndexes)
        for v in selected where visibleIndexes.indices.contains(v) {
            let i = visibleIndexes[v]
            let new = change(comparison.rows[i])
            if SyncEngine.choices(for: comparison.rows[i]).contains(new) { comparison.rows[i].action = new }
        }
        table.reloadData(forRowIndexes: IndexSet(selected), columnIndexes: IndexSet(0..<table.numberOfColumns))
        updateButtons()
    }

    @objc func markLeftToRight() { modify { _ in .copyToRight } }
    @objc func markRightToLeft() { modify { _ in .copyToLeft } }
    @objc func markDefault() { modify { $0.recommended } }
    @objc func unmark() { modify { _ in .none } }
    @objc func reverse() {
        modify { row in
            switch row.action {
            case .copyToRight: return .copyToLeft
            case .copyToLeft: return .copyToRight
            default: return row.action
            }
        }
    }
    @objc func markDeleteRight() { modify { _ in .deleteRight } }
    @objc func markDeleteLeft() { modify { _ in .deleteLeft } }

    @objc private func tableClicked() {
        // A click on the <=> column cycles the direction of that row.
        let row = table.clickedRow, column = table.clickedColumn
        guard row >= 0, column >= 0, table.tableColumns[column].identifier.rawValue == Column.action.rawValue,
              visibleIndexes.indices.contains(row) else { return }
        let i = visibleIndexes[row]
        comparison.rows[i].action = SyncEngine.cycle(comparison.rows[i])
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(0..<table.numberOfColumns))
        updateButtons()
    }

    @objc private func tableDoubleClicked() {
        let row = table.clickedRow, column = table.clickedColumn
        guard row >= 0, column >= 0, visibleIndexes.indices.contains(row) else { return }
        let id = table.tableColumns[column].identifier.rawValue
        let r = comparison.rows[visibleIndexes[row]]
        if id == Column.action.rawValue {
            setAction(.none, forVisible: [row])          // double-click an arrow: no operation
        } else if id.hasPrefix("left"), let info = r.left {
            reveal(info.url, side: .left)
        } else if let info = r.right {
            reveal(info.url, side: .right)
        }
    }

    /// View (3): the selected pair side by side with its differences. Files on a server are
    /// downloaded to a temporary folder first; a file present on one side only is compared to nothing.
    @objc func viewDifferences() {
        guard let v = table.selectedRowIndexes.first, visibleIndexes.indices.contains(v) else { return NSSound.beep() }
        let row = comparison.rows[visibleIndexes[v]]
        guard !row.isDirectory else { return NSSound.beep() }
        let lookup = commander?.ftp.sessionLookup ?? { _ in nil }
        func name(_ info: SyncFileInfo?, _ side: String) -> String {
            guard let url = info?.url else { return "(not on the \(side) side)" }
            return url.isRemoteLocation ? commander?.ftp.displayAddress(of: url) ?? url.absoluteString : url.path
        }
        let viewer = DiffWindowController(leftTitle: name(row.left, "left"), rightTitle: name(row.right, "right"))
        diffWindows.append(viewer)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: viewer.window, queue: .main) { [weak self, weak viewer] _ in
            self?.diffWindows.removeAll { $0 === viewer }
        }
        if let window = viewer.window { AppWindows.place(window) }
        viewer.showWindow(nil)
        let work = { () -> (Result<FileComparison, Error>, [URL]) in
            var temps: [URL] = []
            func local(_ info: SyncFileInfo?) throws -> URL {
                guard let info = info else { return URL(fileURLWithPath: "/dev/null") }
                guard let session = lookup(info.url) else { return info.url }
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cc-diff-\(UUID().uuidString)").appendingPathComponent(info.url.lastPathComponent)
                temps.append(temp.deletingLastPathComponent())
                try session.client.download(RemoteSession.path(of: info.url), to: temp, expectedSize: info.size,
                                            resume: false, cancel: nil, progress: nil)
                return temp
            }
            let result = Result { try FileComparison.compare(try local(row.left), try local(row.right)) }
            return (result, temps)
        }
        let done: ((Result<FileComparison, Error>, [URL])) -> Void = { [weak viewer] output in
            guard let viewer = viewer else { return DiffWindowController.removeTemporaryFiles(output.1) }
            viewer.temporaryFiles = output.1
            switch output.0 {
            case .success(let c): viewer.show(c)
            case .failure(let e): viewer.showError("Cannot compare: \((e as? FTPError)?.message ?? e.localizedDescription)")
            }
        }
        if runSynchronously { done(work()); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let output = work()
            DispatchQueue.main.async { done(output) }
        }
    }

    private func reveal(_ url: URL, side: CommanderModel.Side) {
        guard let c = commander else { return }
        c.activate(side)
        c.reveal(url)
    }

    @objc private func showLeftInPanel() {
        guard let v = table.selectedRowIndexes.first, let info = comparison.rows[visibleIndexes[v]].left else { return NSSound.beep() }
        reveal(info.url, side: .left)
    }

    @objc private func showRightInPanel() {
        guard let v = table.selectedRowIndexes.first, let info = comparison.rows[visibleIndexes[v]].right else { return NSSound.beep() }
        reveal(info.url, side: .right)
    }

    // Context menu, rebuilt for the rows under the click.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        if clicked >= 0 && !table.selectedRowIndexes.contains(clicked) {
            table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        guard !table.selectedRowIndexes.isEmpty else { return }
        let items: [(String, Selector, String)] = [
            ("Copy left → right", #selector(markLeftToRight), "⌃L"),
            ("Copy right → left", #selector(markRightToLeft), "⌃R"),
            ("Default direction", #selector(markDefault), "⌃D"),
            ("Reverse direction", #selector(reverse), "⌃W"),
            ("Remove selection (don't copy)", #selector(unmark), "⌃M"),
            ("Delete on right side", #selector(markDeleteRight), ""),
            ("Delete on left side", #selector(markDeleteLeft), ""),
        ]
        for (title, sel, key) in items {
            let item = NSMenuItem(title: key.isEmpty ? title : "\(title)\t\(key)", action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let view = NSMenuItem(title: "View differences\t3", action: #selector(viewDifferences), keyEquivalent: "")
        view.target = self
        menu.addItem(view)
        for (title, sel) in [("Show left file in panel", #selector(showLeftInPanel)), ("Show right file in panel", #selector(showRightInPanel))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    /// A click on a column header: sort the list by it (again: reverse).
    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let selected = Set(table.selectedRowIndexes.compactMap { visibleIndexes.indices.contains($0) ? visibleIndexes[$0] : nil })
        applyFilter()
        let rows = IndexSet(visibleIndexes.indices.filter { selected.contains(visibleIndexes[$0]) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { table.scrollRowToVisible(first) }
    }

    /// ↑ ↓ move (the table does that), ← → set the direction, Space cycles ← = delete →,
    /// 3 / F3 views the differences; plus Total Commander's Ctrl shortcuts.
    func handleTableKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.isEmpty {
            let selected = Array(table.selectedRowIndexes)
            switch event.keyCode {
            case 123: setAction(.copyToLeft, forVisible: selected); return true
            case 124: setAction(.copyToRight, forVisible: selected); return true
            case 49:
                for v in selected where visibleIndexes.indices.contains(v) {
                    let i = visibleIndexes[v]
                    comparison.rows[i].action = SyncEngine.spaceCycle(comparison.rows[i])
                }
                table.reloadData(forRowIndexes: IndexSet(selected), columnIndexes: IndexSet(0..<table.numberOfColumns))
                updateButtons()
                return true
            case 20, 99: viewDifferences(); return true
            default: break
            }
        }
        guard event.modifierFlags.contains(.control), let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch ch {
        case "l": markLeftToRight()
        case "r": markRightToLeft()
        case "d": markDefault()
        case "m": unmark()
        case "w": reverse()
        default: return false
        }
        return true
    }

    // MARK: Synchronize

    var currentPlan: SyncPlan {
        guard let cfg = config else { return SyncPlan(rows: [], config: readConfiguration()) }
        return SyncPlan(rows: comparison.rows, config: cfg)
    }

    private func updateButtons() {
        synchronizeButton.isEnabled = !isComparing && config != nil && !currentPlan.isEmpty
        for b in [leftPath, rightPath, maskField] { b.isEnabled = !isComparing }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        switch sender {
        case compareButton: compare()
        case synchronizeButton: openConfirmation()
        case closeButton: window?.performClose(nil)
        case leftBrowse: browse(into: leftPath)
        case rightBrowse: browse(into: rightPath)
        case maskHelp: showMaskHelp()
        default: break
        }
    }

    private func openConfirmation() {
        guard let cfg = config, let window = window else { return }
        let plan = currentPlan
        guard !plan.isEmpty else { return NSSound.beep() }
        let sheet = SyncConfirmationController(plan: plan, config: cfg, sessions: commander?.ftp.sessionLookup ?? { _ in nil },
                                               shown: showFilter)
        sheet.onFinished = { [weak self] report in
            guard let self = self else { return }
            self.confirmation = nil
            var parts = ["\(report.copied) copied"]
            if report.created > 0 { parts.append("\(report.created) folders created") }
            if report.deleted > 0 { parts.append("\(report.deleted) deleted") }
            if !report.skipped.isEmpty { parts.append("\(report.skipped.count) skipped") }
            if !report.errors.isEmpty { parts.append("\(report.errors.count) failed") }
            let summary = "Synchronized: " + parts.joined(separator: ", ") + (report.cancelled ? " (stopped)" : "")
            self.commander?.reloadPanels()
            self.lastSyncSummary = summary
            self.compare()   // show the new state
            self.statusLabel.stringValue = summary
            let problems = report.skipped + report.errors
            self.statusLabel.toolTip = problems.isEmpty ? nil : problems.prefix(30).joined(separator: "\n")
        }
        confirmation = sheet
        window.beginSheet(sheet.window!)
    }

    private func browse(into field: NSComboBox) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        Modal.choose(panel, for: window) { urls in
            if let url = urls.first { field.stringValue = url.path }
        }
    }

    private func showMaskHelp() {
        let alert = NSAlert()
        alert.messageText = "File filter"
        alert.informativeText = """
            Which files are compared:  *.*  (all),  *.txt;*.doc  (several masks),  \
            * | *.tmp;*.bak  (all except the masks after |). Folders are always walked.
            """
        Modal.sheet(alert, for: window)
    }

    public func windowWillClose(_ notification: Notification) {
        cancelFlag?.cancel()
        saveOptions()
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { visibleIndexes.count }

    public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let id = column.flatMap({ Column(rawValue: $0.identifier.rawValue) }) else { return nil }
        let r = comparison.rows[visibleIndexes[row]]
        let f = EntryFormatter.shared
        func size(_ i: SyncFileInfo?) -> String {
            guard let i = i else { return "" }
            return i.isDirectory ? "<DIR>" : f.grouped(i.size)
        }
        func date(_ i: SyncFileInfo?) -> String {
            guard let i = i else { return "" }
            return f.date(FileEntry(name: "", url: i.url, kind: .file, modified: i.modified))
        }
        let text: String
        var alignment: NSTextAlignment = .left
        switch id {
        case .leftName: text = r.left == nil ? "" : EntryFormatter.visible(r.path)
        case .leftSize: text = size(r.left); alignment = .right
        case .leftDate: text = date(r.left)
        case .action: text = r.symbol; alignment = .center
        case .rightDate: text = date(r.right)
        case .rightSize: text = size(r.right); alignment = .right
        case .rightName: text = r.right == nil ? "" : EntryFormatter.visible(r.path)
        }
        let label = NSTextField(labelWithString: text)
        label.alignment = alignment
        label.lineBreakMode = id == .leftName || id == .rightName ? .byTruncatingMiddle : .byTruncatingTail
        label.textColor = Self.color(for: r)
        if id == .action { label.font = .boldSystemFont(ofSize: 15) }
        return label
    }

    /// Row colours like Total Commander: → green, ← blue, ≠ and deletions red, = normal.
    static func color(for row: SyncRow) -> NSColor {
        switch row.action {
        case .copyToRight: return .systemGreen
        case .copyToLeft: return .systemBlue
        case .deleteLeft, .deleteRight: return .systemRed
        case .none: return row.state == .identical ? .labelColor : .systemRed
        }
    }
}

/// The result list: forwards Total Commander's Ctrl shortcuts to the dialog.
public final class SyncTableView: NSTableView {
    weak var owner: SyncWindowController?

    public override func keyDown(with event: NSEvent) {
        if owner?.handleTableKey(event) == true { return }
        super.keyDown(with: event)
    }
}

/// The second stage: lists every pending operation and runs them only after "Start".
final class SyncConfirmationController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let plan: SyncPlan
    private let config: SyncConfiguration
    private let sessions: SyncSessionLookup
    /// The Show filter of the comparison: a direction starts ticked only if its rows are shown.
    private let shown: SyncShowFilter
    var onFinished: ((SyncReport) -> Void)?
    /// Tests run synchronously.
    var runSynchronously = false

    let leftToRightBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let rightToLeftBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let deleteBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let overwriteBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let emptyDirsBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let table = NSTableView()
    private let progress = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var running = false
    private var cancelFlag: CancelFlag?

    init(plan: SyncPlan, config: SyncConfiguration, sessions: @escaping SyncSessionLookup = { _ in nil },
         shown: SyncShowFilter = SyncShowFilter()) {
        self.plan = plan
        self.config = config
        self.sessions = sessions
        self.shown = shown
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.title = AppWindows.title("Synchronize")
        AppWindows.style(window)
        window.minSize = NSSize(width: 640, height: 420)
        window.maxSize = NSSize(width: 1200, height: 1200)
        super.init(window: window)
        window.contentView = build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() -> NSView {
        let f = EntryFormatter.shared
        func describe(_ ops: [SyncOperation]) -> String {
            "\(ops.count) file\(ops.count == 1 ? "" : "s"), \(f.compact(SyncPlan.bytes(ops)))"
        }
        leftToRightBox.title = "Left to right:  copy \(describe(plan.toRight))"
        rightToLeftBox.title = "Right to left:  copy \(describe(plan.toLeft))"
        let onServer = plan.deletions.filter { $0.destination.isRemoteLocation }.count
        let trashNote = onServer == 0 ? "moved to the Trash"
            : onServer == plan.deletions.count ? "PERMANENTLY deleted on the server"
            : "on this Mac to the Trash, \(onServer) PERMANENTLY on the server"
        deleteBox.title = "Delete:  \(plan.deletions.count) file\(plan.deletions.count == 1 ? "" : "s") (\(trashNote))"
        let replacing = plan.all.filter(\.overwrites).count
        overwriteBox.title = "Overwrite existing files  (\(replacing) would be replaced)"
        let folders = plan.all.filter { $0.kind == .makeDirectory }.count
        emptyDirsBox.title = "Create empty directories  (\(folders))"
        for (box, ops) in [(leftToRightBox, plan.toRight), (rightToLeftBox, plan.toLeft), (deleteBox, plan.deletions)] {
            // Ticked only when the comparison shows rows of that kind (e.g. only ← shown: only right to left).
            box.state = ops.contains { shown.shows($0.row) } ? .on : .off
            box.isEnabled = !ops.isEmpty
        }
        overwriteBox.state = .on
        overwriteBox.isEnabled = replacing > 0
        emptyDirsBox.state = .on
        emptyDirsBox.isEnabled = folders > 0

        for (id, title, width) in [("op", "Operation", 90), ("src", "Source", 290), ("dst", "Destination", 290)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = CGFloat(width)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(max(1, plan.all.count))
        progress.isHidden = true
        progressLabel.lineBreakMode = .byTruncatingMiddle

        for (b, sel) in [(startButton, #selector(start)), (cancelButton, #selector(cancel))] {
            b.bezelStyle = .rounded
            b.target = self
            b.action = sel
            b.widthAnchor.constraint(equalToConstant: 100).isActive = true
        }
        startButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancelButton, startButton])

        let title = NSTextField(labelWithString: "Left:  \(address(config.left))\nRight:  \(address(config.right))")
        title.font = .boldSystemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 2
        // Long paths truncate instead of widening the sheet.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.toolTip = "Left: \(address(config.left))\nRight: \(address(config.right))"
        let stack = NSStackView(views: [title, leftToRightBox, rightToLeftBox, deleteBox, overwriteBox, emptyDirsBox,
                                        scroll, progress, progressLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            root.widthAnchor.constraint(equalToConstant: 760),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            progressLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        return root
    }

    var options: SyncRunOptions {
        var o = SyncRunOptions()
        o.leftToRight = leftToRightBox.state == .on
        o.rightToLeft = rightToLeftBox.state == .on
        o.delete = deleteBox.state == .on
        o.overwrite = overwriteBox.state == .on
        o.createEmptyDirectories = emptyDirsBox.state == .on
        return o
    }

    @objc func start() {
        guard !running else { return }
        running = true
        let flag = CancelFlag()
        cancelFlag = flag
        startButton.isEnabled = false
        cancelButton.title = "Stop"
        for b in [leftToRightBox, rightToLeftBox, deleteBox, overwriteBox, emptyDirsBox] { b.isEnabled = false }
        progress.isHidden = false
        let opts = options
        let plan = self.plan
        var done = 0.0
        let step: (SyncOperation) -> Void = { [weak self] op in
            let update = {
                done += 1
                self?.progress.doubleValue = done
                self?.progressLabel.stringValue = (op.kind == .delete ? "Deleting " : "Copying ") + op.row.path
            }
            if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
        }
        let finish: (SyncReport) -> Void = { [weak self] report in
            guard let self = self, let window = self.window else { return }
            window.sheetParent?.endSheet(window)
            self.onFinished?(report)
        }
        let sessions = self.sessions
        if runSynchronously {
            finish(SyncExecutor.run(plan, options: opts, sessions: sessions, isCancelled: { flag.isCancelled }, progress: step))
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let report = SyncExecutor.run(plan, options: opts, sessions: sessions, isCancelled: { flag.isCancelled }, progress: step)
                DispatchQueue.main.async { finish(report) }
            }
        }
    }

    @objc private func cancel() {
        if running {
            cancelFlag?.cancel()
        } else if let window = window {
            window.sheetParent?.endSheet(window)
        }
    }

    /// "Left ▸ docs/readme.md" — the side and the path inside it (full path in the title above).
    private func sidePath(_ url: URL) -> String {
        for (name, root) in [("Left", config.left), ("Right", config.right)] where root.isRemoteLocation == url.isRemoteLocation && root.host == url.host {
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if url.path.hasPrefix(prefix) { return "\(name) ▸ \(url.path.dropFirst(prefix.count))" }
        }
        return address(url)
    }

    /// A local path, or "sftp://user@host/path" for a folder on a server.
    private func address(_ url: URL) -> String {
        guard url.isRemoteLocation else { return url.path }
        return (sessions(url)?.addressLabel ?? "server") + RemoteSession.path(of: url)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { plan.all.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let op = plan.all[row]
        let text: String
        switch column?.identifier.rawValue {
        case "op":
            switch op.kind {
            case .copy: text = op.overwrites ? "Overwrite" : "Copy"
            case .makeDirectory: text = "Create dir"
            case .delete: text = "Delete"
            }
        case "src": text = op.source.map(sidePath) ?? "—"
        default: text = sidePath(op.destination)
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingHead
        if op.kind == .delete { label.textColor = .systemRed }
        return label
    }
}
