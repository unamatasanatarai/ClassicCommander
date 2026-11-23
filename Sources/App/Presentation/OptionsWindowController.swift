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
        didSet {
            guard isLive && working != oldValue else { return }
            // Quick locations are saved from the panels, also while this dialog is open: keep
            // the latest list unless this change is to the list itself (an import).
            var new = working
            if new.quickLocations == oldValue.quickLocations { new.quickLocations = store.settings.quickLocations }
            store.save(new)
        }
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
    let hiddenFilesCheckbox = NSButton(checkboxWithTitle: "Show hidden files (names starting with a dot)  ⌘⇧.", target: nil, action: nil)
    /// Sizes in the Copy / Move dialogs and the queue: bytes or readable.
    let sizeFormatPopup = NSPopUpButton()
    /// The tab bar: with two or more tabs, or always.
    let tabBarPopup = NSPopUpButton()
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
    /// Select group / same extension / Compare directories: also hide what they didn't select.
    let hideOthersCheckbox = NSButton(checkboxWithTitle: "Selecting by mask, extension or comparison hides all other files (Esc shows them)",
                                      target: nil, action: nil)
    /// + / − also select folders (off: files only).
    let maskFoldersCheckbox = NSButton(checkboxWithTitle: "+ / − select folders too (off: files only)", target: nil, action: nil)
    /// ⇧6 preselects the extension too.
    let renameExtensionCheckbox = NSButton(checkboxWithTitle: "⇧6 Rename preselects the extension too (off: only the name)",
                                           target: nil, action: nil)
    /// Long right-click: seconds until the context menu opens.
    let holdField = NSTextField()
    /// Refresh automatically: off, on create/delete/rename, or on every change.
    let autoRefreshPopup = NSPopUpButton()
    /// Finder's "Open With → ClassicCommander": left or right panel.
    let finderPanelPopup = NSPopUpButton()
    private let holdStepper = NSStepper()
    let shortcutsPage = ShortcutsPage()
    private let quickSearchPopup = NSPopUpButton()
    private let pageList = OptionsPageList(pages: ["Display", "Operation", "Quick Search", "Color", "Shortcuts"])
    /// Searches every setting: the page list keeps the pages that mention it, matches are highlighted.
    let searchField = NSSearchField()
    private let noMatchLabel = NSTextField(wrappingLabelWithString: "No setting matches.")
    /// Controls highlighted by the current search.
    private(set) var highlighted: [NSView] = []
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
        window.title = AppWindows.title("Options")
        AppWindows.style(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
        sync()
        isLive = true
        // Settings changed elsewhere (View menu toggles) show up here and are not overwritten.
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: SettingsStore.didChange, object: store)
    }

    @objc private func storeChanged() {
        guard store.settings != working else { return }
        isLive = false
        working = store.settings
        isLive = true
        sync()
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
        if let window = window { AppWindows.place(window) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Building the UI

    private func buildContent() -> NSView {
        let root = NSView()

        let sidebar = pageList
        pages = [buildDisplayPage(), buildOperationPage(), buildQuickSearchPage(), buildColorPage(), shortcutsPage]
        searchField.placeholderString = "Search settings"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        noMatchLabel.textColor = .secondaryLabelColor
        noMatchLabel.isHidden = true
        for v in [searchField, noMatchLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
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
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            searchField.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
            noMatchLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            noMatchLabel.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            noMatchLabel.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            sidebar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
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

    // MARK: Search

    /// Texts of a control a search can match (labels, checkbox and button titles, menu choices).
    static func searchableText(of view: NSView) -> String? {
        switch view {
        case let popup as NSPopUpButton: return popup.itemTitles.joined(separator: " ")
        case let button as NSButton: return button.title
        case let field as NSTextField where !field.isEditable: return field.stringValue
        default: return nil
        }
    }

    /// Every view below `root` (depth first).
    static func allViews(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }

    /// All words of the query appear in the text (any case).
    static func matches(_ text: String, _ words: [String]) -> Bool {
        let t = text.lowercased()
        return words.allSatisfy { t.contains($0) }
    }

    /// Filters the page list to pages with a match, highlights the matching settings, and passes
    /// the search to the Shortcuts page (commands and keys).
    @objc func searchChanged() {
        for view in highlighted { view.layer?.backgroundColor = nil }
        highlighted = []
        let words = searchField.stringValue.lowercased().split(separator: " ").map(String.init)
        shortcutsPage.filterField.stringValue = words.isEmpty ? "" : searchField.stringValue
        shortcutsPage.filterChanged()
        guard !words.isEmpty else {
            pageList.show(Array(pages.indices))
            noMatchLabel.isHidden = true
            return
        }
        var found: [Int] = []
        for (i, page) in pages.enumerated() {
            let hits = Self.allViews(in: page).filter { Self.searchableText(of: $0).map { Self.matches($0, words) } ?? false }
            let commandHit = page === shortcutsPage && !shortcutsPage.actions.isEmpty
            if !hits.isEmpty || commandHit { found.append(i) }
            for view in hits where page !== shortcutsPage {
                view.wantsLayer = true
                view.layer?.cornerRadius = 3
                view.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
                highlighted.append(view)
            }
        }
        pageList.show(found)
        noMatchLabel.isHidden = !found.isEmpty
        if let first = found.first, !found.contains(where: { !pages[$0].isHidden }) { showPage(first) }
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
        hiddenFilesCheckbox.target = self
        hiddenFilesCheckbox.action = #selector(displayToggled)
        sizeFormatPopup.addItems(withTitles: SizeFormat.allCases.map(\.label))
        sizeFormatPopup.target = self
        sizeFormatPopup.action = #selector(displayToggled)
        let sizeRow = NSStackView(views: [NSTextField(labelWithString: "Sizes in copy dialogs and the queue:"), sizeFormatPopup])
        tabBarPopup.addItems(withTitles: TabBarMode.allCases.map(\.label))
        tabBarPopup.target = self
        tabBarPopup.action = #selector(displayToggled)
        let tabRow = NSStackView(views: [NSTextField(labelWithString: "Show the tab bar (⌃T new tab, middle-click closes):"), tabBarPopup])
        let stack = NSStackView(views: [title, bracketsCheckbox, functionBarCheckbox, statusIconCheckbox, hiddenFilesCheckbox, sizeRow, tabRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func buildOperationPage() -> NSView {
        let title = NSTextField(labelWithString: "Operation")
        title.font = .boldSystemFont(ofSize: 15)
        let heading = NSTextField(labelWithString: "Selection with Space:")
        for box in [sizeCheckbox, moveDownCheckbox, hideOthersCheckbox, maskFoldersCheckbox, renameExtensionCheckbox] {
            box.target = self
            box.action = #selector(operationToggled)
        }
        let selectionHeading = NSTextField(labelWithString: "Select menu and mouse:")
        let holdFormatter = NumberFormatter()
        holdFormatter.minimum = NSNumber(value: OperationOptions.contextMenuHoldRange.lowerBound)
        holdFormatter.maximum = NSNumber(value: OperationOptions.contextMenuHoldRange.upperBound)
        holdFormatter.maximumFractionDigits = 1
        holdFormatter.minimumFractionDigits = 0
        holdField.formatter = holdFormatter
        holdField.alignment = .right
        holdField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        holdStepper.minValue = OperationOptions.contextMenuHoldRange.lowerBound
        holdStepper.maxValue = OperationOptions.contextMenuHoldRange.upperBound
        holdStepper.increment = 0.5
        holdStepper.valueWraps = false
        for control in [holdField, holdStepper] as [NSControl] {
            control.target = self
            control.action = #selector(holdChanged(_:))
        }
        let holdRow = NSStackView(views: [NSTextField(labelWithString: "Hold the right mouse button"), holdField, holdStepper,
                                          NSTextField(labelWithString: "seconds for the context menu")])
        holdRow.spacing = 6
        finderPanelPopup.addItems(withTitles: FinderPanel.allCases.map(\.label))
        finderPanelPopup.target = self
        finderPanelPopup.action = #selector(finderPanelChosen)
        let finderRow = NSStackView(views: [NSTextField(labelWithString: "Finder's Open With → ClassicCommander opens in the"), finderPanelPopup])
        autoRefreshPopup.addItems(withTitles: AutoRefresh.allCases.map(\.label))
        autoRefreshPopup.target = self
        autoRefreshPopup.action = #selector(autoRefreshChosen)
        let refreshRow = NSStackView(views: [NSTextField(labelWithString: "Refresh automatically:"), autoRefreshPopup])
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
        let stack = NSStackView(views: [title, heading, sizeCheckbox, moveDownCheckbox, selectionHeading, maskFoldersCheckbox, hideOthersCheckbox, renameExtensionCheckbox, holdRow,
                                        finderRow, refreshRow, transfersHeading, grid, hint, terminalHeading, terminalGrid, terminalHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: heading)
        stack.setCustomSpacing(8, after: sizeCheckbox)
        stack.setCustomSpacing(24, after: moveDownCheckbox)
        stack.setCustomSpacing(6, after: selectionHeading)
        stack.setCustomSpacing(8, after: hideOthersCheckbox)
        stack.setCustomSpacing(8, after: maskFoldersCheckbox)
        stack.setCustomSpacing(8, after: renameExtensionCheckbox)
        stack.setCustomSpacing(24, after: refreshRow)
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
        hiddenFilesCheckbox.state = working.display.showHiddenFiles ? .on : .off
        sizeFormatPopup.selectItem(at: SizeFormat.allCases.firstIndex(of: working.display.sizeFormat) ?? 0)
        tabBarPopup.selectItem(at: TabBarMode.allCases.firstIndex(of: working.display.tabBar) ?? 0)
        quickSearchPopup.selectItem(at: QuickSearchOptions.Activation.allCases.firstIndex(of: working.quickSearch.activation) ?? 0)
        sizeCheckbox.state = working.operation.spaceCalculatesFolderSize ? .on : .off
        moveDownCheckbox.state = working.operation.spaceMovesCursorDown ? .on : .off
        hideOthersCheckbox.state = working.operation.selectionHidesOthers ? .on : .off
        maskFoldersCheckbox.state = working.operation.maskSelectsFolders ? .on : .off
        renameExtensionCheckbox.state = working.operation.renameSelectsExtension ? .on : .off
        holdField.doubleValue = working.operation.contextMenuHold
        holdStepper.doubleValue = working.operation.contextMenuHold
        finderPanelPopup.selectItem(at: FinderPanel.allCases.firstIndex(of: working.operation.finderOpensIn) ?? 0)
        autoRefreshPopup.selectItem(at: AutoRefresh.allCases.firstIndex(of: working.operation.autoRefresh) ?? 1)
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
        working.display.showHiddenFiles = hiddenFilesCheckbox.state == .on
        working.display.tabBar = tabBarPopup.indexOfSelectedItem == 1 ? .always : .whenSeveral
        working.display.sizeFormat = SizeFormat.allCases.indices.contains(sizeFormatPopup.indexOfSelectedItem)
            ? SizeFormat.allCases[sizeFormatPopup.indexOfSelectedItem] : .readable
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
        Modal.choose(panel, for: window) { [weak self] urls in
            guard let self = self else { return }
            if let url = urls.first { self.useTerminal(url.path) } else { self.reloadTerminalPopup() }
        }
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
        working.operation.selectionHidesOthers = hideOthersCheckbox.state == .on
        working.operation.maskSelectsFolders = maskFoldersCheckbox.state == .on
        working.operation.renameSelectsExtension = renameExtensionCheckbox.state == .on
    }

    @objc func autoRefreshChosen() {
        let i = autoRefreshPopup.indexOfSelectedItem
        working.operation.autoRefresh = AutoRefresh.allCases.indices.contains(i) ? AutoRefresh.allCases[i] : .structure
    }

    @objc func finderPanelChosen() {
        working.operation.finderOpensIn = finderPanelPopup.indexOfSelectedItem == 1 ? .right : .left
    }

    /// The hold field or its stepper changed: keep both in step and save (live).
    @objc func holdChanged(_ sender: NSControl) {
        let range = OperationOptions.contextMenuHoldRange
        let value = min(range.upperBound, max(range.lowerBound, (sender.doubleValue * 10).rounded() / 10))
        holdField.doubleValue = value
        holdStepper.doubleValue = value
        working.operation.contextMenuHold = value
    }

    // MARK: Export / import

    /// Writes every setting to a JSON file.
    @objc private func exportPressed() {
        shortcutsPage.stopRecording()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ClassicCommander Settings.json"
        panel.allowedContentTypes = [.json]
        Modal.choose(panel, for: window) { [weak self] urls in
            guard let url = urls.first, let self = self else { return }
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
        Modal.choose(panel, for: window) { [weak self] urls in
            guard let url = urls.first, let self = self else { return }
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
        var imported = try SettingsFile.importing(data, onto: working)
        // The terminal command starts a program: a settings file from elsewhere may only change it
        // after the user has seen exactly what would run.
        let ops = imported.operation, current = working.operation
        if ops.terminalApp != current.terminalApp || ops.terminalArguments != current.terminalArguments {
            let command = ops.terminalApp + (ops.terminalArguments.isEmpty ? "" : "  " + ops.terminalArguments)
            if !confirmTerminalChange(command) {
                imported.operation.terminalApp = current.terminalApp
                imported.operation.terminalArguments = current.terminalArguments
            }
        }
        working = imported
        sync()
    }

    /// Asks before an imported file changes "Open terminal here". Replaceable in tests.
    var confirmTerminalChange: (String) -> Bool = { command in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Use the terminal from the imported settings?"
        alert.informativeText = "Open Terminal Here (⌃⇧T) would start:\n\n\(command)\n\nOnly accept this if you trust where the settings file came from."
        alert.addButton(withTitle: "Keep My Terminal")
        alert.addButton(withTitle: "Use Imported Terminal")
        return Modal.run(alert) == .alertSecondButtonReturn
    }

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.informativeText = message
        Modal.sheet(alert, for: window)
    }

    @objc private func okPressed() {
        window?.close()
    }

    /// Undoes everything changed since the dialog opened.
    @objc private func cancelPressed() {
        shortcutsPage.stopRecording()
        isLive = false
        working = original
        var back = original
        back.quickLocations = store.settings.quickLocations   // Cancel is about this dialog's options
        store.save(back)
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
    /// The pages listed (a search leaves out the others), as indexes into `pages`.
    private(set) var shown: [Int]

    init(pages: [String]) {
        self.pages = pages
        shown = Array(pages.indices)
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
        guard let row = shown.firstIndex(of: index), table.selectedRow != row else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// Lists only these pages (keeping the selected one selected when it is among them).
    func show(_ indexes: [Int]) {
        let selected = shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil
        shown = indexes
        table.allowsEmptySelection = true
        table.reloadData()
        if let s = selected, let row = shown.firstIndex(of: s) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        table.allowsEmptySelection = shown.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: pages[shown[row]])
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if shown.indices.contains(table.selectedRow) { onSelect?(shown[table.selectedRow]) }
    }
}
