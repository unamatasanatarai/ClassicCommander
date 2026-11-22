import AppKit

/// Options → Shortcuts: every panel action with its keys. "Add Shortcut…" records the next key
/// combination for the selected action (Esc cancels); a key already used elsewhere moves over,
/// and the note under the table says where it came from.
final class ShortcutsPage: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var bindings = KeyBindings.standard {
        didSet { if bindings != oldValue { refilter() } }
    }
    var onChange: ((KeyBindings) -> Void)?

    private let table = NSTableView()
    private let addButton = NSButton(title: "Add Shortcut…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Shortcuts", target: nil, action: nil)
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

        let title = NSTextField(labelWithString: "Shortcuts")
        title.font = .boldSystemFont(ofSize: 15)

        let actionColumn = NSTableColumn(identifier: .init("action"))
        actionColumn.title = "Command"
        actionColumn.width = 300
        let keysColumn = NSTableColumn(identifier: .init("keys"))
        keysColumn.title = "Keys"
        keysColumn.width = 220
        table.addTableColumn(actionColumn)
        table.addTableColumn(keysColumn)
        table.rowHeight = 22
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
            scroll.heightAnchor.constraint(equalToConstant: 350),
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
        let text: String
        if column?.identifier.rawValue == "keys" {
            text = recordingAction == action
                ? "Press keys…  (Esc cancels)"
                : bindings.keys(for: action).map(\.displayName).joined(separator: ",  ")
        } else {
            text = action.label
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if recordingAction == action && column?.identifier.rawValue == "keys" {
            label.textColor = .controlAccentColor
        }
        return label
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
        removeButton.isEnabled = !(selectedAction.map { bindings.keys(for: $0).isEmpty } ?? true)
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

    @objc private func removePressed() {
        guard let action = selectedAction else { return }
        stopRecording()
        for combo in bindings.keys(for: action) { bindings.remove(combo, from: action) }
        note.stringValue = "“\(action.label)” has no shortcut now."
        changed()
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
