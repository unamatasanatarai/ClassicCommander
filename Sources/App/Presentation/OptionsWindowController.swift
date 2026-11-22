import AppKit
import UniformTypeIdentifiers

/// Configuration → Options, modelled on Total Commander's Options dialog: a page list on the left,
/// the selected page on the right, OK / Cancel at the bottom.
/// Pages: Display, Operation, Color and Shortcuts.
/// Changes apply live: each edit is saved at once and shows in the main window. OK (or closing the
/// window) keeps them; Cancel restores the settings from when the dialog was opened.
public final class OptionsWindowController: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore
    /// The settings being edited. Every change is saved straight away (live), except while
    /// the dialog itself is loading them.
    private(set) var working: Settings {
        didSet { if isLive && working != oldValue { store.save(working) } }
    }
    private var isLive = false
    /// What Cancel goes back to.
    private(set) var original: Settings

    private var wells: [ThemeSlot: NSColorWell] = [:]
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let previewActive: PanelView
    private let previewInactive: PanelView
    private let bracketsCheckbox = NSButton(checkboxWithTitle: "Show square brackets around directory names",
                                            target: nil, action: nil)
    private let functionBarCheckbox = NSButton(checkboxWithTitle: "Show function key buttons (Copy, Move, NewFolder, Delete)",
                                               target: nil, action: nil)
    private let statusIconCheckbox = NSButton(checkboxWithTitle: "Show icon in the menu bar", target: nil, action: nil)
    private let sizeCheckbox = NSButton(checkboxWithTitle: "Space calculates the size of folders",
                                        target: nil, action: nil)
    /// FTP/SFTP transfers at the same time: total, uploads, downloads (0 = the total).
    let transferFields = [NSTextField(), NSTextField(), NSTextField()]
    /// "Open terminal here": which app, and its arguments ({dir} = the folder).
    let terminalPopup = NSPopUpButton()
    let terminalArgumentsField = NSTextField()
    private let transferSteppers = [NSStepper(), NSStepper(), NSStepper()]
    private let moveDownCheckbox = NSButton(checkboxWithTitle: "Space moves the cursor down after selecting",
                                            target: nil, action: nil)
    private let shortcutsPage = ShortcutsPage()
    private let quickSearchPopup = NSPopUpButton()
    private let pageList = OptionsPageList(pages: ["Display", "Operation", "Quick Search", "Color", "Shortcuts"])
    private var pages: [NSView] = []
    private static let customTitle = "Custom"

    public init(store: SettingsStore) {
        self.store = store
        working = store.settings
        original = store.settings
        previewActive = PanelView(model: Self.previewModel(cursor: 4))
        previewInactive = PanelView(model: Self.previewModel(cursor: 2))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "Options"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
        sync()
        isLive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens the dialog on the currently saved settings, on the page used last.
    public func present() {
        isLive = false
        working = store.settings
        original = store.settings
        isLive = true
        sync()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Building the UI

    private func buildContent() -> NSView {
        let root = NSView()

        let sidebar = pageList
        pages = [buildDisplayPage(), buildOperationPage(), buildQuickSearchPage(), buildColorPage(), shortcutsPage]
        shortcutsPage.onChange = { [weak self] keys in self?.working.keys = keys }
        sidebar.onSelect = { [weak self] index in self?.showPage(index) }

        let ok = button("OK", action: #selector(okPressed), key: "\r")
        let cancel = button("Cancel", action: #selector(cancelPressed), key: "\u{1b}")
        let buttons = NSStackView(views: [ok, cancel])
        let exportButton = button("Export…", action: #selector(exportPressed), key: "")
        let importButton = button("Import…", action: #selector(importPressed), key: "")
        let fileButtons = NSStackView(views: [exportButton, importButton])
        fileButtons.spacing = 8
        fileButtons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(fileButtons)
        NSLayoutConstraint.activate([
            fileButtons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            fileButtons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        buttons.spacing = 8

        for v in [sidebar, buttons] + pages {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        for page in pages {
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
                page.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
                page.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
                page.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -12),
            ])
        }
        showPage(0)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            sidebar.widthAnchor.constraint(equalToConstant: 160),
            sidebar.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            ok.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            cancel.widthAnchor.constraint(equalTo: ok.widthAnchor),
        ])
        return root
    }

    /// Shows one page and hides the others; also used by the page list.
    func showPage(_ index: Int) {
        for (i, page) in pages.enumerated() {
            page.isHidden = i != index
        }
        pageList.select(index)
    }

    var visiblePageTitle: String? {
        pages.firstIndex { !$0.isHidden }.map { pageList.pages[$0] }
    }

    private func buildDisplayPage() -> NSView {
        let title = NSTextField(labelWithString: "Display")
        title.font = .boldSystemFont(ofSize: 15)
        bracketsCheckbox.target = self
        bracketsCheckbox.action = #selector(displayToggled)
        functionBarCheckbox.target = self
        functionBarCheckbox.action = #selector(displayToggled)
        statusIconCheckbox.target = self
        statusIconCheckbox.action = #selector(displayToggled)
        let stack = NSStackView(views: [title, bracketsCheckbox, functionBarCheckbox, statusIconCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func buildOperationPage() -> NSView {
        let title = NSTextField(labelWithString: "Operation")
        title.font = .boldSystemFont(ofSize: 15)
        let heading = NSTextField(labelWithString: "Selection with Space:")
        for box in [sizeCheckbox, moveDownCheckbox] {
            box.target = self
            box.action = #selector(operationToggled)
        }
        let transfersHeading = NSTextField(labelWithString: "FTP / SFTP transfers at the same time:")
        var rows: [[NSView]] = []
        for (i, name) in ["Total open transfers:", "Max uploads:", "Max downloads:"].enumerated() {
            let field = transferFields[i], stepper = transferSteppers[i]
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let formatter = NumberFormatter()
            formatter.minimum = i == 0 ? 1 : 0
            formatter.maximum = 32
            formatter.allowsFloats = false
            field.formatter = formatter
            field.target = self
            field.action = #selector(transfersChanged(_:))
            stepper.minValue = i == 0 ? 1 : 0
            stepper.maxValue = 32
            stepper.increment = 1
            stepper.valueWraps = false
            stepper.target = self
            stepper.action = #selector(transfersChanged(_:))
            rows.append([NSTextField(labelWithString: name), NSStackView(views: [field, stepper])])
        }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        let hint = NSTextField(wrappingLabelWithString: "0 uploads or downloads = up to the total. Applies to files that start next.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.preferredMaxLayoutWidth = 380
        terminalPopup.target = self
        terminalPopup.action = #selector(terminalChosen)
        terminalArgumentsField.placeholderString = "empty: open the folder with the app"
        terminalArgumentsField.target = self
        terminalArgumentsField.action = #selector(terminalArgumentsChanged)
        terminalArgumentsField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let terminalGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Terminal:"), terminalPopup],
            [NSTextField(labelWithString: "Arguments:"), terminalArgumentsField],
        ])
        terminalGrid.column(at: 0).xPlacement = .trailing
        terminalGrid.rowSpacing = 6
        let terminalHeading = NSTextField(labelWithString: "Open terminal here (⌃⇧T):")
        let terminalHint = NSTextField(wrappingLabelWithString: "{dir} is replaced by the folder, e.g. Alacritty: --working-directory {dir}")
        terminalHint.textColor = .secondaryLabelColor
        terminalHint.font = .systemFont(ofSize: 11)
        terminalHint.preferredMaxLayoutWidth = 380
        let stack = NSStackView(views: [title, heading, sizeCheckbox, moveDownCheckbox, transfersHeading, grid, hint,
                                        terminalHeading, terminalGrid, terminalHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: heading)
        stack.setCustomSpacing(8, after: sizeCheckbox)
        stack.setCustomSpacing(24, after: moveDownCheckbox)
        stack.setCustomSpacing(6, after: transfersHeading)
        stack.setCustomSpacing(6, after: grid)
        stack.setCustomSpacing(24, after: hint)
        stack.setCustomSpacing(6, after: terminalHeading)
        stack.setCustomSpacing(6, after: terminalGrid)
        return stack
    }

    private func buildQuickSearchPage() -> NSView {
        let title = NSTextField(labelWithString: "Quick Search")
        title.font = .boldSystemFont(ofSize: 15)
        quickSearchPopup.addItems(withTitles: QuickSearchOptions.Activation.allCases.map(\.label))
        quickSearchPopup.target = self
        quickSearchPopup.action = #selector(quickSearchChanged)
        let row = NSStackView(views: [NSTextField(labelWithString: "Start quick search with:"), quickSearchPopup])
        row.spacing = 8
        let help = NSTextField(wrappingLabelWithString: """
            Typing jumps to the first name starting with the text (* and ? are wildcards).
            In the box: ↓ or ⌃↩ next match, ↑ previous, ↩ open, Esc close.
            ⌃S opens Quick Filter (only matching names stay visible); ⌃S in the box switches mode.
            With “Letter alone”, keys that have a shortcut (h j k l, 5–8 …) keep their shortcut.
            """)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 560
        let stack = NSStackView(views: [title, row, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    @objc private func quickSearchChanged() {
        working.quickSearch.activation = QuickSearchOptions.Activation.allCases[max(0, quickSearchPopup.indexOfSelectedItem)]
    }

    private func buildColorPage() -> NSView {
        let title = NSTextField(labelWithString: "Color")
        title.font = .boldSystemFont(ofSize: 15)

        presetPopup.target = self
        presetPopup.action = #selector(presetChosen)
        let presetRow = NSStackView(views: [NSTextField(labelWithString: "Scheme:"), presetPopup])
        presetRow.spacing = 8

        // Two label/well pairs per row.
        let slots = ThemeSlot.allCases
        var rows: [[NSView]] = []
        for i in stride(from: 0, to: slots.count, by: 2) {
            var row: [NSView] = []
            for slot in slots[i..<min(i + 2, slots.count)] {
                let well = NSColorWell()
                well.target = self
                well.action = #selector(wellChanged(_:))
                well.translatesAutoresizingMaskIntoConstraints = false
                well.widthAnchor.constraint(equalToConstant: 44).isActive = true
                well.heightAnchor.constraint(equalToConstant: 22).isActive = true
                wells[slot] = well
                row.append(NSTextField(labelWithString: slot.label + ":"))
                row.append(well)
            }
            while row.count < 4 { row.append(NSGridCell.emptyContentView) }
            rows.append(row)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing
        grid.column(at: 2).leadingPadding = 24
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }

        let previewLabel = NSTextField(labelWithString: "Preview:")
        let preview = PreviewPair(active: previewActive, inactive: previewInactive)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 240).isActive = true

        let stack = NSStackView(views: [title, presetRow, grid, previewLabel, preview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: grid)
        stack.setCustomSpacing(6, after: previewLabel)
        preview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func button(_ title: String, action: Selector, key: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.keyEquivalent = key
        return b
    }

    // MARK: State

    /// Pushes `working` into the wells, the preset menu and the preview.
    private func sync() {
        bracketsCheckbox.state = working.display.showFolderBrackets ? .on : .off
        functionBarCheckbox.state = working.display.showFunctionKeyBar ? .on : .off
        statusIconCheckbox.state = working.display.showStatusBarIcon ? .on : .off
        quickSearchPopup.selectItem(at: QuickSearchOptions.Activation.allCases.firstIndex(of: working.quickSearch.activation) ?? 0)
        sizeCheckbox.state = working.operation.spaceCalculatesFolderSize ? .on : .off
        moveDownCheckbox.state = working.operation.spaceMovesCursorDown ? .on : .off
        reloadTerminalPopup()
        terminalArgumentsField.stringValue = working.operation.terminalArguments
        let values = [working.operation.maxTransfers, working.operation.maxUploads, working.operation.maxDownloads]
        for i in 0..<3 {
            transferFields[i].integerValue = values[i]
            transferSteppers[i].integerValue = values[i]
        }
        shortcutsPage.bindings = working.keys
        previewActive.display = working.display
        previewInactive.display = working.display
        for (slot, well) in wells {
            well.color = working.theme[slot].nsColor
        }
        presetPopup.removeAllItems()
        presetPopup.addItems(withTitles: Theme.presets.map(\.name))
        if let match = Theme.presets.first(where: { $0.theme == working.theme }) {
            presetPopup.selectItem(withTitle: match.name)
        } else {
            presetPopup.addItem(withTitle: Self.customTitle)
            presetPopup.selectItem(withTitle: Self.customTitle)
        }
        previewActive.theme = working.theme
        previewInactive.theme = working.theme
    }

    @objc private func wellChanged(_ sender: NSColorWell) {
        guard let slot = wells.first(where: { $0.value === sender })?.key else { return }
        working.theme[slot] = RGBColor(sender.color)
        // Only the menu and preview need refreshing; resetting the wells would fight the colour panel.
        let match = Theme.presets.first(where: { $0.theme == working.theme })
        if presetPopup.item(withTitle: Self.customTitle) == nil && match == nil {
            presetPopup.addItem(withTitle: Self.customTitle)
        }
        presetPopup.selectItem(withTitle: match?.name ?? Self.customTitle)
        previewActive.theme = working.theme
        previewInactive.theme = working.theme
    }

    @objc private func presetChosen() {
        guard let preset = Theme.presets.first(where: { $0.name == presetPopup.titleOfSelectedItem }) else { return }
        working.theme = preset.theme
        sync()
    }

    @objc private func displayToggled() {
        working.display.showFolderBrackets = bracketsCheckbox.state == .on
        working.display.showFunctionKeyBar = functionBarCheckbox.state == .on
        working.display.showStatusBarIcon = statusIconCheckbox.state == .on
        previewActive.display = working.display
        previewInactive.display = working.display
    }

    /// Installed terminals (and the chosen app, if it is another one), then "Other…".
    private func reloadTerminalPopup() {
        terminalPopup.removeAllItems()
        var paths: [String] = []
        for preset in TerminalLauncher.presets {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preset.bundleID) else { continue }
            terminalPopup.addItem(withTitle: preset.name)
            terminalPopup.lastItem?.representedObject = url.path
            paths.append(url.path)
        }
        let current = working.operation.terminalApp
        if !paths.contains(current) {
            terminalPopup.addItem(withTitle: FileManager.default.displayName(atPath: current))
            terminalPopup.lastItem?.representedObject = current
        }
        terminalPopup.menu?.addItem(.separator())
        terminalPopup.addItem(withTitle: "Other…")
        terminalPopup.selectItem(at: terminalPopup.indexOfItem(withRepresentedObject: current))
    }

    @objc func terminalChosen() {
        guard let path = terminalPopup.selectedItem?.representedObject as? String else { return chooseOtherTerminal() }
        useTerminal(path)
    }

    /// Picks the app and fills in the arguments a known terminal needs.
    func useTerminal(_ path: String) {
        working.operation.terminalApp = path
        let id = Bundle(path: path)?.bundleIdentifier
        working.operation.terminalArguments = TerminalLauncher.preset(forBundleID: id)?.arguments ?? ""
        terminalArgumentsField.stringValue = working.operation.terminalArguments
        reloadTerminalPopup()
    }

    private func chooseOtherTerminal() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose the terminal app to open folders with"
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = panel.url { self.useTerminal(url.path) } else { self.reloadTerminalPopup() }
        }
        if let window = window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    @objc func terminalArgumentsChanged() {
        working.operation.terminalArguments = terminalArgumentsField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    /// A field or its stepper changed: keep both in step and save (live).
    @objc func transfersChanged(_ sender: NSControl) {
        for i in 0..<3 where sender === transferFields[i] || sender === transferSteppers[i] {
            let v = min(32, max(i == 0 ? 1 : 0, sender.integerValue))
            transferFields[i].integerValue = v
            transferSteppers[i].integerValue = v
        }
        working.operation.maxTransfers = transferFields[0].integerValue
        working.operation.maxUploads = transferFields[1].integerValue
        working.operation.maxDownloads = transferFields[2].integerValue
    }

    @objc private func operationToggled() {
        working.operation.spaceCalculatesFolderSize = sizeCheckbox.state == .on
        working.operation.spaceMovesCursorDown = moveDownCheckbox.state == .on
    }

    // MARK: Export / import

    /// Writes every setting to a JSON file.
    @objc private func exportPressed() {
        shortcutsPage.stopRecording()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ClassicCommander Settings.json"
        panel.allowedContentTypes = [.json]
        guard let window = window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            do {
                try self.exportSettings(to: url)
            } catch {
                self.report("Could not export the settings: \(error.localizedDescription)")
            }
        }
    }

    /// Reads a JSON file and applies it at once (Cancel still restores the settings from before).
    @objc private func importPressed() {
        shortcutsPage.stopRecording()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard let window = window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            do {
                try self.importSettings(from: url)
            } catch let e as SearchValidationError {
                self.report(e.message)
            } catch {
                self.report("Could not read the file: \(error.localizedDescription)")
            }
        }
    }

    func exportSettings(to url: URL) throws {
        try SettingsFile.export(working).write(to: url, options: .atomic)
    }

    func importSettings(from url: URL) throws {
        let data = try Data(contentsOf: url)
        working = try SettingsFile.importing(data, onto: working)
        sync()
    }

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.informativeText = message
        if let window = window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc private func okPressed() {
        window?.close()
    }

    /// Undoes everything changed since the dialog opened.
    @objc private func cancelPressed() {
        shortcutsPage.stopRecording()
        isLive = false
        working = original
        store.save(original)
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        shortcutsPage.stopRecording()
        wells.values.forEach { $0.deactivate() }
        NSColorPanel.shared.orderOut(nil)
    }

    // MARK: Preview

    private static func previewModel(cursor: Int) -> PanelModel {
        let model = PanelModel(directory: URL(fileURLWithPath: "/Preview/dev"), lister: PreviewLister())
        model.setCursor(cursor, visibleRows: 20)
        return model
    }
}

/// Fixed sample entries for the preview panels.
private struct PreviewLister: DirectoryListing {
    func entries(in directory: URL) throws -> [FileEntry] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func file(_ name: String, _ size: Int64, _ days: Double) -> FileEntry {
            FileEntry(name: name, url: directory.appendingPathComponent(name), kind: .file, size: size,
                      modified: base.addingTimeInterval(-days * 86_400), permissions: 0o644)
        }
        func dir(_ name: String, _ days: Double) -> FileEntry {
            FileEntry(name: name, url: directory.appendingPathComponent(name), kind: .directory,
                      modified: base.addingTimeInterval(-days * 86_400), permissions: 0o755)
        }
        return [
            dir("inc", 300), dir("media", 420),
            file("1pix.gif", 43, 900), file("bg_main.jpg", 481, 500), file("header.jpg", 15_965, 480),
            file("index.php", 1_678, 40), file("menu.html", 16_531, 200), file("readme.txt", 16_531, 200),
        ]
    }
}

/// Two preview panels side by side: the left one drawn active, the right one inactive.
private final class PreviewPair: NSView {
    private let active: PanelView
    private let inactive: PanelView

    init(active: PanelView, inactive: PanelView) {
        self.active = active
        self.inactive = inactive
        super.init(frame: .zero)
        for p in [active, inactive] {
            p.showsVolumeInfo = false
            addSubview(p)
        }
        active.isActive = true
        inactive.isActive = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let gap: CGFloat = 6
        let half = floor((bounds.width - gap) / 2)
        active.frame = NSRect(x: 0, y: 0, width: half, height: bounds.height)
        inactive.frame = NSRect(x: half + gap, y: 0, width: bounds.width - half - gap, height: bounds.height)
    }

    // The preview is for looking at, not clicking.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The page list on the left of the Options dialog.
private final class OptionsPageList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let pages: [String]
    var onSelect: ((Int) -> Void)?
    private let table = NSTableView()

    init(pages: [String]) {
        self.pages = pages
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        documentView = table
        hasVerticalScroller = true
        borderType = .bezelBorder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func select(_ index: Int) {
        if table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: pages[row])
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0 { onSelect?(table.selectedRow) }
    }
}
