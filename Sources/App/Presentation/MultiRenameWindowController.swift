import AppKit

/// Multi-Rename Tool (⌃M), laid out like Total Commander's: name and extension masks with buttons
/// for the placeholders, Search & Replace, upper/lowercase and the counter on top; the old and new
/// names below (problems in red, which keep Start! off); Start!, Undo and Close at the bottom.
/// Works on the marked files and folders of the active panel, or on the whole list.
final class MultiRenameWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSComboBoxDelegate, NSTextFieldDelegate {
    weak var commander: CommanderView?
    private let defaults: UserDefaults

    let nameField = NSComboBox()
    let extField = NSTextField()
    let searchField = NSComboBox()
    let replaceField = NSComboBox()
    let caseBox = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    let firstOnlyBox = NSButton(checkboxWithTitle: "Only the first (1x)", target: nil, action: nil)
    let extensionBox = NSButton(checkboxWithTitle: "Also the extension", target: nil, action: nil)
    let regexBox = NSButton(checkboxWithTitle: "RegEx", target: nil, action: nil)
    let casePopup = NSPopUpButton()
    let startField = NSTextField()
    let stepField = NSTextField()
    let digitsPopup = NSPopUpButton()
    let table = NSTableView()
    let statusLabel = NSTextField(labelWithString: "")
    let startButton = NSButton(title: "Start!", target: nil, action: nil)
    let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    /// What is being renamed (updated to the new names after Start!).
    private(set) var entries: [FileEntry] = []
    private(set) var rows: [MultiRename.Row] = []
    /// The panel the entries come from.
    private weak var panel: PanelView?
    /// The renames of the last Start! (Undo reverses them).
    private(set) var lastRun: [MultiRename.Move] = []

    private enum Key {
        static let names = "multiRename.nameHistory"
        static let searches = "multiRename.searchHistory"
        static let replaces = "multiRename.replaceHistory"
    }

    init(commander: CommanderView, defaults: UserDefaults = .standard) {
        self.commander = commander
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = AppWindows.title("Multi-Rename Tool")
        window.minSize = NSSize(width: 900, height: 420)
        window.isReleasedWhenClosed = false
        AppWindows.style(window)
        super.init(window: window)
        window.delegate = self
        window.contentView = build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Building

    private func group(_ title: String, _ views: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 12)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func tokenButton(_ title: String, _ token: String, into field: NSTextField) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(insertToken(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.identifier = NSUserInterfaceItemIdentifier(token)
        b.tag = field === extField ? 1 : 0
        return b
    }

    private func build() -> NSView {
        nameField.stringValue = "[N]"
        nameField.addItems(withObjectValues: defaults.stringArray(forKey: Key.names) ?? [])
        extField.stringValue = "[E]"
        searchField.addItems(withObjectValues: defaults.stringArray(forKey: Key.searches) ?? [])
        replaceField.addItems(withObjectValues: defaults.stringArray(forKey: Key.replaces) ?? [])
        for f in [nameField, extField, searchField, replaceField, startField, stepField] as [NSTextField] {
            f.delegate = self
            f.target = self
            f.action = #selector(changed)
        }
        for c in [caseBox, firstOnlyBox, extensionBox, regexBox, casePopup, digitsPopup] as [NSControl] {
            c.target = self
            c.action = #selector(changed)
        }
        casePopup.addItems(withTitles: RenameRules.Case.allCases.map(\.label))
        digitsPopup.addItems(withTitles: (1...10).map(String.init))
        startField.integerValue = 1
        stepField.integerValue = 1
        for f in [startField, stepField] {
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 60).isActive = true
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            f.formatter = formatter
        }
        nameField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        extField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        replaceField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let nameButtons = NSGridView(views: [
            [tokenButton("[N] Name", "[N]", into: nameField), tokenButton("[YMD] Date", "[YMD]", into: nameField)],
            [tokenButton("[N#-#] Range", "[N1-3]", into: nameField), tokenButton("[hms] Time", "[hms]", into: nameField)],
            [tokenButton("[C] Counter", "[C]", into: nameField), NSGridCell.emptyContentView],
        ])
        nameButtons.rowSpacing = 4
        nameButtons.columnSpacing = 4
        let extButtons = NSStackView(views: [tokenButton("[E] Ext.", "[E]", into: extField), tokenButton("[E#-#] Range", "[E1-3]", into: extField),
                                             tokenButton("[C] Counter", "[C]", into: extField)])
        extButtons.orientation = .vertical
        extButtons.alignment = .leading
        extButtons.spacing = 4
        let searchGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Search for:"), searchField],
            [NSTextField(labelWithString: "Replace with:"), replaceField],
        ])
        searchGrid.rowSpacing = 6
        let checks = NSGridView(views: [[caseBox, firstOnlyBox], [extensionBox, regexBox]])
        checks.rowSpacing = 4
        let counterGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Start at:"), startField],
            [NSTextField(labelWithString: "Step by:"), stepField],
            [NSTextField(labelWithString: "Digits:"), digitsPopup],
        ])
        counterGrid.rowSpacing = 6
        let top = NSStackView(views: [
            group("Rename mask: file name", [nameField, nameButtons]),
            group("Extension", [extField, extButtons]),
            group("Search & Replace", [searchGrid, checks, NSTextField(labelWithString: "Upper/lowercase:"), casePopup]),
            group("Counter [C]", [counterGrid]),
        ])
        top.alignment = .top
        top.spacing = 22

        for (id, title, width) in [("old", "Old name", 300), ("new", "New name", 300), ("size", "Size", 90), ("date", "Date", 140), ("where", "Location", 220)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = CGFloat(width)
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for (b, sel) in [(startButton, #selector(startPressed)), (undoButton, #selector(undoPressed)), (closeButton, #selector(closePressed))] {
            b.bezelStyle = .rounded
            b.target = self
            b.action = sel
        }
        startButton.keyEquivalent = "\r"
        closeButton.keyEquivalent = "\u{1b}"
        statusLabel.lineBreakMode = .byTruncatingTail
        let bottom = NSStackView(views: [statusLabel, NSView(), startButton, undoButton, closeButton])

        let stack = NSStackView(views: [top, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        return root
    }

    // MARK: Showing

    /// Opens on the marked entries of `panel`, or on its whole list when nothing is marked.
    func present(for panel: PanelView) {
        self.panel = panel
        let marked = panel.model.entries.filter { $0.kind != .parent && panel.model.marked.contains($0.name) }
        entries = marked.isEmpty ? panel.model.entries.filter { $0.kind != .parent } : marked
        lastRun = []
        update()
        if let window = window { AppWindows.place(window) }
        showWindow(nil)
        window?.makeFirstResponder(nameField)
    }

    /// The rules as set in the window.
    var rules: RenameRules {
        var r = RenameRules()
        r.nameMask = nameField.stringValue
        r.extensionMask = extField.stringValue
        r.search = searchField.stringValue
        r.replace = replaceField.stringValue
        r.caseSensitive = caseBox.state == .on
        r.firstOnly = firstOnlyBox.state == .on
        r.includeExtension = extensionBox.state == .on
        r.regex = regexBox.state == .on
        r.letterCase = RenameRules.Case.allCases[max(0, casePopup.indexOfSelectedItem)]
        r.counterStart = startField.integerValue
        r.counterStep = stepField.integerValue
        r.counterDigits = max(1, digitsPopup.indexOfSelectedItem + 1)
        return r
    }

    /// Names in the folder that aren't being renamed (a new name may not take one of them).
    private var otherNames: Set<String> {
        let all = Set(panel?.model.allEntries.filter { $0.kind != .parent }.map(\.name) ?? [])
        return all.subtracting(entries.map(\.name))
    }

    /// Recomputes the new names and what is wrong with them.
    @objc func changed() { update() }
    func controlTextDidChange(_ obj: Notification) { update() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    func update() {
        do {
            rows = try MultiRename.preview(entries, rules: rules, existing: otherNames)
            let problems = rows.filter { $0.problem != nil }.count
            let changes = rows.filter(\.changes).count
            if problems > 0 {
                statusLabel.stringValue = "\(problems) name\(problems == 1 ? " has a problem" : "s have problems") (in red) — fix the masks to rename"
                statusLabel.textColor = .systemRed
            } else {
                statusLabel.stringValue = changes == 0 ? "Nothing changes yet — edit the masks above"
                    : "\(changes) of \(entries.count) will be renamed. Press Start!"
                statusLabel.textColor = .labelColor
            }
            startButton.isEnabled = problems == 0 && changes > 0
        } catch {
            rows = entries.map { MultiRename.Row(entry: $0, newName: $0.name, problem: nil) }
            statusLabel.stringValue = "The regular expression is not valid: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
            startButton.isEnabled = false
        }
        undoButton.isEnabled = !lastRun.isEmpty
        table.reloadData()
    }

    /// [N] Name, [C] Counter…: puts the placeholder where the cursor is in its field.
    @objc func insertToken(_ sender: NSButton) {
        let field: NSTextField = sender.tag == 1 ? extField : nameField
        let token = sender.identifier?.rawValue ?? ""
        if let editor = field.currentEditor() {
            editor.insertText(token)
        } else {
            field.stringValue += token
        }
        update()
    }

    // MARK: Renaming

    /// Renames on this Mac, or on the server the panel shows.
    private func renamer() -> (URL, URL) throws -> Void {
        if let panel = panel, let session = commander?.ftp.session(for: panel) {
            return { from, to in
                try session.client.rename(RemoteSession.path(of: from), to: RemoteSession.path(of: to))
                session.invalidate(RemoteSession.path(of: from.deletingLastPathComponent()))
            }
        }
        return { from, to in try FileManager.default.moveItem(at: from, to: to) }
    }

    @objc func startPressed() {
        update()
        guard startButton.isEnabled else { return NSSound.beep() }
        rememberHistory()
        let (done, errors) = MultiRename.apply(rows, rename: renamer())
        lastRun = done
        follow(done)
        finish("Renamed \(done.count) of \(rows.filter(\.changes).count)", errors: errors)
    }

    @objc func undoPressed() {
        guard !lastRun.isEmpty else { return NSSound.beep() }
        let (done, errors) = MultiRename.undo(lastRun, rename: renamer())
        follow(done)
        lastRun = []
        finish("Undone: \(done.count) name\(done.count == 1 ? "" : "s") back", errors: errors)
    }

    /// The list keeps showing the same files under their new names.
    private func follow(_ moves: [MultiRename.Move]) {
        var renamed: [String: URL] = [:]
        for move in moves { renamed[move.from.path] = move.to }
        entries = entries.map { e in
            guard let to = renamed[e.url.path] else { return e }
            return FileEntry(name: to.lastPathComponent, url: to, kind: e.kind, size: e.size, modified: e.modified,
                             isSymlink: e.isSymlink, permissions: e.permissions)
        }
    }

    private func finish(_ message: String, errors: [String]) {
        commander?.reloadPanels()
        update()
        statusLabel.stringValue = message + (errors.isEmpty ? "" : " — \(errors.count) failed: \(errors.joined(separator: "; "))")
        statusLabel.textColor = errors.isEmpty ? .labelColor : .systemRed
    }

    private func rememberHistory() {
        for (box, key) in [(nameField, Key.names), (searchField, Key.searches), (replaceField, Key.replaces)] {
            let value = box.stringValue
            guard !value.isEmpty else { continue }
            var history = defaults.stringArray(forKey: key) ?? []
            history.removeAll { $0 == value }
            history.insert(value, at: 0)
            history = Array(history.prefix(15))
            defaults.set(history, forKey: key)
            box.removeAllItems()
            box.addItems(withObjectValues: history)
        }
    }

    @objc func closePressed() { close() }

    func windowWillClose(_ notification: Notification) { lastRun = [] }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// Click a column title: sort by it (the counter follows the new order).
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        let f = EntryFormatter.shared
        func value(_ e: FileEntry) -> String {
            switch key {
            case "size": return String(format: "%020lld", e.size ?? -1)
            case "date": return f.date(e)
            case "where": return e.url.deletingLastPathComponent().path
            case "new": return (try? MultiRename.newName(for: e, index: 0, rules: rules)) ?? e.name
            default: return e.name
            }
        }
        entries.sort { a, b in
            let r = value(a).localizedStandardCompare(value(b))
            return d.ascending ? r == .orderedAscending : r == .orderedDescending
        }
        update()
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let r = rows[row]
        let f = EntryFormatter.shared
        let label: NSTextField
        switch column?.identifier.rawValue {
        case "new":
            label = NSTextField(labelWithString: EntryFormatter.visible(r.newName))
            if let problem = r.problem {
                label.textColor = .systemRed
                label.toolTip = problem
            } else if r.changes {
                label.font = .boldSystemFont(ofSize: 13)
            }
        case "size":
            label = NSTextField(labelWithString: r.entry.kind == .file ? f.grouped(r.entry.size ?? 0) : "<DIR>")
            label.alignment = .right
        case "date": label = NSTextField(labelWithString: f.date(r.entry))
        case "where":
            let url = r.entry.url.deletingLastPathComponent()
            label = NSTextField(labelWithString: url.isRemoteLocation ? commander?.ftp.displayAddress(of: url) ?? url.path : url.path)
        default: label = NSTextField(labelWithString: EntryFormatter.visible(r.entry.name))
        }
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}
