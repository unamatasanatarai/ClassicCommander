import AppKit

/// Options → Shortcuts: every panel action with its keys. "Add Shortcut…" records the next key
/// combination for the selected action (Esc cancels); a key already used elsewhere moves over,
/// and the note under the table says where it came from. Individual shortcuts can be removed
/// via their inline "×" button, the "Remove Shortcut…" button, or the right-click context menu.
final class ShortcutsPage: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var bindings = KeyBindings.standard {
        didSet { if bindings != oldValue { refilter() } }
    }
    var onChange: ((KeyBindings) -> Void)?

    private let table = ShortcutsTableView()
    private let addButton = NSButton(title: "Add Shortcut…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Shortcut", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)
    let note = NSTextField(labelWithString: "")
    private var monitor: Any?
    private(set) var recordingAction: CommandAction?

    /// The rows shown: every action, or those matching the filter field (best match first).
    private(set) var actions = CommandAction.allCases
    /// Fuzzy filter over command names and their keys ("copy", "F5", "⌥7", "nwfl").
    let filterField = NSSearchField()

    init() {
        super.init(frame: .zero)
        table.shortcutsPage = self

        let title = NSTextField(labelWithString: "Shortcuts")
        title.font = .boldSystemFont(ofSize: 15)

        let actionColumn = NSTableColumn(identifier: .init("action"))
        actionColumn.title = "Command"
        actionColumn.width = 300
        let keysColumn = NSTableColumn(identifier: .init("keys"))
        keysColumn.title = "Keys"
        keysColumn.width = 280
        table.addTableColumn(actionColumn)
        table.addTableColumn(keysColumn)
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(addPressed)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for (button, action) in [(addButton, #selector(addPressed)), (removeButton, #selector(removePressed)),
                                 (resetButton, #selector(resetPressed))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [addButton, removeButton, NSView(), resetButton])
        buttons.spacing = 8
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping

        filterField.placeholderString = "Filter commands or keys — fuzzy, e.g. copy, F5, ⌥7, nwfl"
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.sendsSearchStringImmediately = true
        filterField.delegate = self   // also refilter on every text change, however the text arrives
        let stack = NSStackView(views: [title, filterField, scroll, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filterField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let action = actions[row]
        if column?.identifier.rawValue == "keys" {
            if recordingAction == action {
                let label = NSTextField(labelWithString: "Press keys…  (Esc cancels)")
                label.lineBreakMode = .byTruncatingTail
                label.textColor = AppWindows.accent
                return AppWindows.centeredCell(label)
            }
            let keys = bindings.keys(for: action)
            if keys.isEmpty {
                return AppWindows.centeredCell(NSTextField(labelWithString: ""))
            }
            let container = NSStackView()
            container.orientation = .horizontal
            container.spacing = 5
            container.alignment = .centerY
            for combo in keys {
                let pill = KeyPillView(action: action, combo: combo) { [weak self] act, c in
                    self?.removeSingle(combo: c, from: act)
                }
                pill.setContentHuggingPriority(.required, for: .horizontal)
                pill.setContentCompressionResistancePriority(.required, for: .horizontal)
                container.addArrangedSubview(pill)
            }
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            container.addArrangedSubview(spacer)
            let cell = NSTableCellView()
            container.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                container.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                container.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        } else {
            let label = NSTextField(labelWithString: action.label)
            label.lineBreakMode = .byTruncatingTail
            return AppWindows.centeredCell(label)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        stopRecording()
        updateButtons()
    }

    private var selectedAction: CommandAction? {
        table.selectedRow >= 0 ? actions[table.selectedRow] : nil
    }

    /// Searchable text of a command: its name, its keys (as shown and spelled out) and its id.
    func searchText(for action: CommandAction) -> String {
        let keys = bindings.keys(for: action)
        let spelled = keys.map { combo -> String in
            var words: [String] = []
            if combo.modifiers.contains(.control) { words.append("ctrl control") }
            if combo.modifiers.contains(.option) { words.append("alt option") }
            if combo.modifiers.contains(.shift) { words.append("shift") }
            if combo.modifiers.contains(.command) { words.append("cmd command") }
            return words.joined(separator: " ")
        }
        return ([action.label] + keys.map(\.displayName) + spelled + [action.rawValue]).joined(separator: "  ")
    }

    @objc func filterChanged() {
        refilter()
    }

    func controlTextDidChange(_ obj: Notification) {
        refilter()
    }

    /// Applies the filter text, keeping the selected command selected when it is still listed.
    func refilter() {
        let selected = selectedAction
        actions = FuzzyMatch.filter(CommandAction.allCases, query: filterField.stringValue) { searchText(for: $0) }
        table.reloadData()
        if let s = selected, let row = actions.firstIndex(of: s) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !actions.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateButtons()
    }

    func select(_ action: CommandAction) {
        if !actions.contains(action) {
            filterField.stringValue = ""
            refilter()
        }
        if let row = actions.firstIndex(of: action) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func updateButtons() {
        let keys = selectedAction.map { bindings.keys(for: $0) } ?? []
        removeButton.isEnabled = !keys.isEmpty
        removeButton.title = keys.count > 1 ? "Remove Shortcut…" : "Remove Shortcut"
        addButton.isEnabled = selectedAction != nil
    }

    // MARK: Editing

    @objc func addPressed() {
        guard let action = selectedAction else { return }
        stopRecording()
        recordingAction = action
        note.stringValue = "Press the new key combination for “\(action.label)”."
        table.reloadData()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.recordingAction != nil else { return event }
            self.record(KeyCombo(event))
            return nil
        }
    }

    /// Handles one recorded key; also called directly by tests.
    func record(_ combo: KeyCombo) {
        guard let action = recordingAction else { return }
        stopRecording()
        if combo.keyCode == KeyCode.escape && combo.modifiers.isEmpty {
            note.stringValue = ""
            return
        }
        if combo.isReservedByMenu {
            note.stringValue = "\(combo.displayName) belongs to the app menu and can’t be used here."
            return
        }
        let previous = bindings.add(combo, to: action)
        note.stringValue = previous.map { "\(combo.displayName) moved here from “\($0.label)”." }
            ?? "\(combo.displayName) added to “\(action.label)”."
        changed()
    }

    /// Removes a single shortcut key combination from an action.
    public func removeSingle(combo: KeyCombo, from action: CommandAction) {
        bindings.remove(combo, from: action)
        note.stringValue = "\(combo.displayName) removed from “\(action.label)”."
        changed()
    }

    @objc func removeSpecificComboItem(_ sender: NSMenuItem) {
        guard let action = selectedAction, let combo = sender.representedObject as? KeyCombo else { return }
        removeSingle(combo: combo, from: action)
    }

    @objc func removeAllCombos() {
        guard let action = selectedAction else { return }
        for combo in bindings.keys(for: action) { bindings.remove(combo, from: action) }
        note.stringValue = "“\(action.label)” has no shortcut now."
        changed()
    }

    @objc func removePressed() {
        guard let action = selectedAction else { return }
        stopRecording()
        let keys = bindings.keys(for: action)
        guard !keys.isEmpty else { return }

        let isMouse = NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .leftMouseDown
        if keys.count > 1 && isMouse {
            let menu = makeRemoveMenu(for: keys)
            let pt = NSPoint(x: 0, y: removeButton.bounds.height + 2)
            menu.popUp(positioning: nil, at: pt, in: removeButton)
            return
        }

        removeAllCombos()
    }

    private func makeRemoveMenu(for keys: [KeyCombo]) -> NSMenu {
        let menu = NSMenu(title: "Remove Shortcut")
        for combo in keys {
            let item = NSMenuItem(title: "Remove \(combo.displayName)", action: #selector(removeSpecificComboItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = combo
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let allItem = NSMenuItem(title: "Remove All (\(keys.count) shortcuts)", action: #selector(removeAllCombos), keyEquivalent: "")
        allItem.target = self
        menu.addItem(allItem)
        return menu
    }

    @objc private func resetPressed() {
        stopRecording()
        bindings = .standard
        note.stringValue = "All shortcuts are back to their defaults."
        changed()
    }

    func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recordingAction != nil {
            recordingAction = nil
            table.reloadData()
        }
    }

    private func changed() {
        table.reloadData()
        updateButtons()
        onChange?(bindings)
    }
}

/// An individual keyboard shortcut badge with an inline "×" remove button.
final class KeyPillView: NSView {
    let action: CommandAction
    let combo: KeyCombo
    var onRemove: ((CommandAction, KeyCombo) -> Void)?

    init(action: CommandAction, combo: KeyCombo, onRemove: @escaping (CommandAction, KeyCombo) -> Void) {
        self.action = action
        self.combo = combo
        self.onRemove = onRemove
        super.init(frame: .zero)

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let pillText = NSColor(srgbRed: isDark ? 0.92 : 0.12, green: isDark ? 0.92 : 0.12, blue: isDark ? 0.94 : 0.13, alpha: 1)
        let pillMute = NSColor(srgbRed: isDark ? 0.65 : 0.40, green: isDark ? 0.65 : 0.40, blue: isDark ? 0.68 : 0.43, alpha: 1)

        let label = NSTextField(labelWithString: combo.displayName)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = pillText
        label.lineBreakMode = .byClipping

        let closeBtn = NSButton()
        closeBtn.bezelStyle = .inline
        closeBtn.isBordered = false
        closeBtn.attributedTitle = NSAttributedString(string: "×", attributes: [
            .foregroundColor: pillMute,
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
        ])
        closeBtn.target = self
        closeBtn.action = #selector(removeClicked)
        closeBtn.toolTip = "Remove shortcut \(combo.displayName)"

        let stack = NSStackView(views: [label, closeBtn])
        stack.spacing = 3
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 13),
            closeBtn.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pillPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)

        // Pill background: always crisp control background in the active appearance (never black on scroll)
        NSColor.controlBackgroundColor.setFill()
        pillPath.fill()

        NSColor.separatorColor.setStroke()
        pillPath.lineWidth = 1.0
        pillPath.stroke()
    }

    @objc private func removeClicked() {
        onRemove?(action, combo)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Custom table view with right-click context menu to remove individual shortcuts or add shortcuts.
private final class ShortcutsTableView: NSTableView {
    weak var shortcutsPage: ShortcutsPage?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let page = shortcutsPage, page.actions.indices.contains(row) else {
            return super.menu(for: event)
        }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let action = page.actions[row]
        let keys = page.bindings.keys(for: action)
        let menu = NSMenu(title: action.label)
        let addItem = NSMenuItem(title: "Add Shortcut…", action: #selector(page.addPressed), keyEquivalent: "")
        addItem.target = page
        menu.addItem(addItem)
        if !keys.isEmpty {
            menu.addItem(.separator())
            for combo in keys {
                let item = NSMenuItem(title: "Remove \(combo.displayName)", action: #selector(page.removeSpecificComboItem(_:)), keyEquivalent: "")
                item.target = page
                item.representedObject = combo
                menu.addItem(item)
            }
            if keys.count > 1 {
                menu.addItem(.separator())
                let allItem = NSMenuItem(title: "Remove All (\(keys.count) shortcuts)", action: #selector(page.removeAllCombos), keyEquivalent: "")
                allItem.target = page
                menu.addItem(allItem)
            }
        }
        return menu
    }
}
