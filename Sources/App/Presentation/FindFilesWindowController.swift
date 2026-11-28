import AppKit

/// Find Files (⌥7), laid out like Total Commander's dialog:
///   tabs General / Advanced, Start search / Cancel on the right,
///   "Search results:" list (first line is the summary), View / New search / Go to file /
///   Feed to listbox under it, and a status line at the bottom.
/// Searches run in the background and results appear as they are found; Cancel stops a running
/// search (and closes the dialog when nothing runs). Settings and histories are remembered.
public final class FindFilesWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate {

    struct Row {
        let item: SearchItem
        let group: Int?
    }

    /// What the results list shows: the summary line first, then files (with lines between duplicate groups).
    enum DisplayRow {
        case summary
        case item(Int)
        case separator
    }

    weak var commander: CommanderView?
    private let defaults: UserDefaults
    /// Tests run searches to completion inside `startSearch()`.
    var runSynchronously = false

    var config = FileSearchConfiguration()
    private(set) var rows: [Row] = []
    private(set) var displayRows: [DisplayRow] = [.summary]
    private(set) var isSearching = false
    private(set) var lastErrors: [String] = []
    private(set) var summary = ""
    private var cancelFlag: CancelFlag?
    private var pending: [SearchItem] = []
    private let pendingLock = NSLock()

    // General
    let searchFor = NSComboBox()
    let searchIn = NSComboBox()
    private let browseButton = NSButton(title: ">>", target: nil, action: nil)
    private let drivesButton = NSButton(title: "Drives", target: nil, action: nil)
    let regexBox = NSButton(checkboxWithTitle: "RegEx", target: nil, action: nil)
    let selectedOnlyBox = NSButton(checkboxWithTitle: "Only search in selected directories/files", target: nil, action: nil)
    let archivesBox = NSButton(checkboxWithTitle: "Search archives (zip, tar, …)", target: nil, action: nil)
    let depthPopup = NSPopUpButton()
    let findTextBox = NSButton(checkboxWithTitle: "Find text:", target: nil, action: nil)
    let findTextField = NSComboBox()
    let wholeWordsBox = NSButton(checkboxWithTitle: "Whole words only", target: nil, action: nil)
    let caseBox = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    let textRegexBox = NSButton(checkboxWithTitle: "RegEx (2)", target: nil, action: nil)
    let hexBox = NSButton(checkboxWithTitle: "Hex", target: nil, action: nil)
    let notBox = NSButton(checkboxWithTitle: "Find files NOT containing the text", target: nil, action: nil)
    private(set) var charsetBoxes: [ContentCharset: NSButton] = [:]

    // Advanced
    let dateBetweenBox = NSButton(checkboxWithTitle: "Date between:", target: nil, action: nil)
    let dateFromPicker = NSDatePicker()
    let dateToPicker = NSDatePicker()
    let dateFromButton = NSButton(title: ">>", target: nil, action: nil)
    private let dateToButton = NSButton(title: ">>", target: nil, action: nil)
    let notOlderBox = NSButton(checkboxWithTitle: "Not older than:", target: nil, action: nil)
    let notOlderField = NSTextField()
    private let notOlderStepper = NSStepper()
    let notOlderUnit = NSPopUpButton()
    let olderBox = NSButton(checkboxWithTitle: "Older than:", target: nil, action: nil)
    let olderField = NSTextField()
    private let olderStepper = NSStepper()
    let olderUnit = NSPopUpButton()
    let sizeBox = NSButton(checkboxWithTitle: "File size:", target: nil, action: nil)
    let sizeOperator = NSPopUpButton()
    let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    let sizeUnit = NSPopUpButton()
    let attributesBox = NSButton(checkboxWithTitle: "Attributes:", target: nil, action: nil)
    private(set) var attributeBoxes: [FileAttribute: NSButton] = [:]
    let duplicatesBox = NSButton(checkboxWithTitle: "Find duplicate files:", target: nil, action: nil)
    let sameNameBox = NSButton(checkboxWithTitle: "same name", target: nil, action: nil)
    let sameSizeBox = NSButton(checkboxWithTitle: "same size", target: nil, action: nil)
    let sameContentsBox = NSButton(checkboxWithTitle: "same contents", target: nil, action: nil)

    // Frame
    let tabs = NSTabView()
    let startButton = NSButton(title: "Start search", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let table = ResultsTableView()
    let statusLabel = NSTextField(labelWithString: "")
    let viewButton = NSButton(title: "View", target: nil, action: nil)
    private let newSearchButton = NSButton(title: "New search", target: nil, action: nil)
    private let goToButton = NSButton(title: "Go to file", target: nil, action: nil)
    private let feedButton = NSButton(title: "Feed to listbox", target: nil, action: nil)
    private let calendarPopover = NSPopover()
    private let calendar = NSDatePicker()
    private weak var calendarTarget: NSDatePicker?

    private enum Key {
        static let config = "findFiles.configuration"
        static let forHistory = "findFiles.searchForHistory"
        static let inHistory = "findFiles.searchInHistory"
        static let textHistory = "findFiles.findTextHistory"
    }

    private static let depthChoices: [(String, SubdirectoryDepth)] =
        [("all (unlimited depth)", .all), ("current dir only", .currentOnly)]
        + (1...9).map { ("\($0) level\($0 == 1 ? "" : "s")", .limited($0)) }

    /// Total Commander's attribute grid: two rows.
    private static let attributeLayout: [[FileAttribute]] = [
        [.archive, .hidden, .directory, .encrypted],
        [.readOnly, .system, .compressed],
    ]

    init(commander: CommanderView, defaults: UserDefaults = .standard) {
        self.commander = commander
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = AppWindows.title("Find Files")
        AppWindows.style(window)
        window.minSize = NSSize(width: 700, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        if let data = defaults.data(forKey: Key.config),
           let saved = try? JSONDecoder().decode(FileSearchConfiguration.self, from: data) {
            config = saved
        }
        window.contentView = buildContent()
        window.center()
        searchFor.addItems(withObjectValues: defaults.stringArray(forKey: Key.forHistory) ?? [])
        searchIn.addItems(withObjectValues: defaults.stringArray(forKey: Key.inHistory) ?? [])
        findTextField.addItems(withObjectValues: defaults.stringArray(forKey: Key.textHistory) ?? [])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens the dialog, searching in the active panel's folder (like Total Commander).
    public func present() {
        // The View button shows the panel's View key ("3 View"), which also works in the results list.
        if let key = commander?.settings.keys.keys(for: .view).first {
            viewButton.title = "\(key.displayName) View"
        }
        if !isSearching, let panel = commander?.activeView {
            // A panel connected to a server searches that server (shown as its address).
            let path = panel.model.isRemote
                ? commander?.ftp.displayAddress(of: panel.model.directory) ?? FileManager.default.homeDirectoryForCurrentUser.path
                : panel.model.directory.path
            config.general.searchPaths = [path]
        }
        writeUI()
        updateEnabled()
        if let window = window { AppWindows.place(window) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchFor)
    }

    // MARK: Building

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func wire(_ controls: [NSControl], _ action: Selector) {
        for c in controls {
            c.target = self
            c.action = action
        }
    }

    private func buildContent() -> NSView {
        tabs.drawsBackground = false
        tabs.tabViewBorderType = .none

        for (title, view) in [("General", buildGeneral()), ("Advanced", buildAdvanced())] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            let container = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                view.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                view.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8),
            ])
            item.view = container
            tabs.addTabViewItem(item)
        }

        let allButtons = [startButton, cancelButton, viewButton, newSearchButton, goToButton, feedButton,
                          browseButton, drivesButton]
        wire(allButtons, #selector(buttonPressed(_:)))
        for b in allButtons { b.bezelStyle = .rounded }
        startButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        let side = NSStackView(views: [startButton, cancelButton])
        side.orientation = .vertical
        side.spacing = 6
        for b in [startButton, cancelButton] { b.widthAnchor.constraint(equalToConstant: 128).isActive = true }

        // Results: one column of paths, the summary as the first line (as in Total Commander).
        let column = NSTableColumn(identifier: .init("path"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(goToFile)
        table.onKey = { [weak self] event in self?.handleResultsKey(event) ?? false }
        table.rowHeight = 18
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let resultButtons = NSStackView(views: [viewButton, newSearchButton, goToButton, feedButton])
        resultButtons.distribution = .fillEqually
        resultButtons.spacing = 8
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.stringValue = "Ready"
        let statusBox = NSBox()
        statusBox.boxType = .custom
        statusBox.borderColor = .separatorColor
        statusBox.borderWidth = 1
        statusBox.cornerRadius = 0
        statusBox.contentViewMargins = NSSize(width: 4, height: 2)
        statusBox.contentView = statusLabel

        let root = NSView()
        let resultsLabel = label("Search results:")
        for v in [tabs, side, resultsLabel, scroll, resultButtons, statusBox] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            tabs.trailingAnchor.constraint(equalTo: side.leadingAnchor, constant: -10),
            tabs.heightAnchor.constraint(equalToConstant: 365),
            side.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            side.topAnchor.constraint(equalTo: tabs.topAnchor, constant: 30),

            resultsLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            resultsLabel.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: resultsLabel.bottomAnchor, constant: 4),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

            resultButtons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            resultButtons.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            resultButtons.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.82),

            statusBox.topAnchor.constraint(equalTo: resultButtons.bottomAnchor, constant: 8),
            statusBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            statusBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            statusBox.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            statusBox.heightAnchor.constraint(equalToConstant: 24),
        ])

        calendar.datePickerStyle = .clockAndCalendar
        calendar.datePickerElements = .yearMonthDay
        calendar.target = self
        calendar.action = #selector(calendarPicked)
        let calendarController = NSViewController()
        calendarController.view = calendar
        calendarPopover.contentViewController = calendarController
        calendarPopover.behavior = .transient
        return root
    }

    private func buildGeneral() -> NSView {
        searchFor.completes = true
        searchIn.completes = true
        findTextField.completes = true
        searchFor.placeholderString = "*.txt;*.jpg     (| excludes: *.log | old*)"
        searchIn.placeholderString = "folders, separated by ;"
        depthPopup.addItems(withTitles: Self.depthChoices.map(\.0))
        archivesBox.isEnabled = false
        archivesBox.toolTip = "Searching inside archives is not available yet."
        wire([regexBox, selectedOnlyBox, findTextBox, wholeWordsBox, caseBox, textRegexBox, hexBox, notBox],
             #selector(controlChanged))

        var charsetViews: [NSView] = []
        for cs in ContentCharset.allCases {
            let b = NSButton(checkboxWithTitle: cs.label, target: self, action: #selector(controlChanged))
            charsetBoxes[cs] = b
            charsetViews.append(b)
        }
        let leftOptions = NSStackView(views: [wholeWordsBox, caseBox, textRegexBox, hexBox, notBox])
        let rightOptions = NSStackView(views: charsetViews)
        for s in [leftOptions, rightOptions] {
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 5
        }
        let options = NSStackView(views: [leftOptions, rightOptions])
        options.alignment = .top
        options.distribution = .fillEqually
        options.spacing = 16

        let depthRow = NSStackView(views: [label("Search in subdirectories:"), NSView(), depthPopup])
        let searchInRow = NSStackView(views: [searchIn, browseButton, drivesButton])
        searchInRow.spacing = 6
        browseButton.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let grid = NSGridView(views: [
            [label("Search for:"), searchFor],
            [label("Search in:"), searchInRow],
            [regexBox, selectedOnlyBox],
            [NSGridCell.emptyContentView, archivesBox],
            [NSGridCell.emptyContentView, depthRow],
            [separator(), separator()],
            [findTextBox, findTextField],
            [NSGridCell.emptyContentView, options],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        return grid
    }

    private func buildAdvanced() -> NSView {
        for (p, b) in [(dateFromPicker, dateFromButton), (dateToPicker, dateToButton)] {
            p.datePickerStyle = .textField
            p.datePickerElements = .yearMonthDay
            p.dateValue = Date()
            b.bezelStyle = .rounded
            b.target = self
            b.action = #selector(showCalendar(_:))
        }
        for (field, stepper) in [(notOlderField, notOlderStepper), (olderField, olderStepper), (sizeField, sizeStepper)] {
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            stepper.minValue = 0
            stepper.maxValue = 1_000_000
            stepper.increment = 1
            stepper.valueWraps = false
            stepper.target = self
            stepper.action = #selector(stepped(_:))
        }
        for u in [notOlderUnit, olderUnit] { u.addItems(withTitles: AgeUnit.allCases.map(\.label)) }
        sizeOperator.addItems(withTitles: ComparisonOperator.allCases.map(\.rawValue))
        sizeUnit.addItems(withTitles: SizeUnit.allCases.map(\.label))
        wire([dateBetweenBox, notOlderBox, olderBox, sizeBox, attributesBox, duplicatesBox], #selector(controlChanged))

        // Three-state attribute boxes: "–" ignore, ✓ must have, empty must not have.
        var attrRows: [[NSView]] = []
        for row in Self.attributeLayout {
            var views: [NSView] = []
            for attribute in row {
                let b = NSButton(checkboxWithTitle: attribute.label, target: nil, action: nil)
                b.allowsMixedState = true
                b.state = .mixed
                b.toolTip = attribute.macMeaning + "\n– = ignore,  ✓ = must have,  empty = must not have"
                attributeBoxes[attribute] = b
                views.append(b)
            }
            while views.count < 4 { views.append(NSGridCell.emptyContentView) }
            attrRows.append(views)
        }
        let attrGrid = NSGridView(views: attrRows)
        attrGrid.columnSpacing = 18
        attrGrid.rowSpacing = 6

        func row(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.spacing = 6
            return s
        }
        let grid = NSGridView(views: [
            [dateBetweenBox, row([dateFromPicker, dateFromButton, label("   and   "), dateToPicker, dateToButton])],
            [notOlderBox, row([notOlderField, notOlderStepper, NSView(), notOlderUnit])],
            [olderBox, row([olderField, olderStepper, NSView(), olderUnit])],
            [separator(), separator()],
            [sizeBox, row([sizeOperator, sizeField, sizeStepper, sizeUnit])],
            [separator(), separator()],
            [attributesBox, attrGrid],
            [separator(), separator()],
            [duplicatesBox, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, row([sameNameBox, sameSizeBox, sameContentsBox])],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .leading
        return grid
    }

    // MARK: UI <-> configuration

    /// Fills the controls from `config`.
    func writeUI() {
        writeGeneralUI()
        writeAdvancedUI()
    }

    private func setCheck(_ button: NSButton, _ on: Bool) {
        button.state = on ? .on : .off
    }

    private func writeGeneralUI() {
        let g = config.general, c = g.content
        searchFor.stringValue = g.filenamePattern
        searchIn.stringValue = g.searchPaths.joined(separator: "; ")
        setCheck(regexBox, g.useRegex)
        setCheck(selectedOnlyBox, g.selectedItemsOnly)
        depthPopup.selectItem(at: Self.depthChoices.firstIndex { $0.1 == g.depth } ?? 0)
        setCheck(findTextBox, c.enabled)
        findTextField.stringValue = c.expression
        setCheck(wholeWordsBox, c.wholeWordsOnly)
        setCheck(caseBox, c.caseSensitive)
        setCheck(textRegexBox, c.useRegex)
        setCheck(hexBox, c.hexadecimal)
        setCheck(notBox, c.invertMatch)
        for (cs, box) in charsetBoxes { setCheck(box, c.charsets.contains(cs)) }
    }

    private func writeAdvancedUI() {
        let a = config.advanced
        setCheck(dateBetweenBox, a.dateBetweenEnabled)
        dateFromPicker.dateValue = a.dateFrom ?? Date()
        dateToPicker.dateValue = a.dateTo ?? Date()
        for (box, field, stepper, unit, age) in [(notOlderBox, notOlderField, notOlderStepper, notOlderUnit, a.notOlderThan),
                                                 (olderBox, olderField, olderStepper, olderUnit, a.olderThan)] {
            setCheck(box, age.enabled)
            field.stringValue = String(age.value)
            stepper.integerValue = age.value
            unit.selectItem(at: AgeUnit.allCases.firstIndex(of: age.unit) ?? 0)
        }
        setCheck(sizeBox, a.fileSize.enabled)
        sizeOperator.selectItem(at: ComparisonOperator.allCases.firstIndex(of: a.fileSize.comparison) ?? 0)
        sizeField.stringValue = a.fileSize.value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int64(a.fileSize.value)) : String(a.fileSize.value)
        sizeStepper.doubleValue = a.fileSize.value
        sizeUnit.selectItem(at: SizeUnit.allCases.firstIndex(of: a.fileSize.unit) ?? 0)
        setCheck(attributesBox, a.attributesEnabled)
        for (attribute, box) in attributeBoxes {
            switch a.state(of: attribute) {
            case .ignored: box.state = .mixed
            case .required: box.state = .on
            case .excluded: box.state = .off
            }
        }
        setCheck(duplicatesBox, a.duplicates.enabled)
        setCheck(sameNameBox, a.duplicates.sameName)
        setCheck(sameSizeBox, a.duplicates.sameSize)
        setCheck(sameContentsBox, a.duplicates.sameContents)
    }

    /// Reads the controls into `config`. Number fields that do not parse are reported, not guessed.
    @discardableResult
    func readUI() -> SearchValidationError? {
        var c = config
        c.general.filenamePattern = searchFor.stringValue.isEmpty ? "*" : searchFor.stringValue
        c.general.searchPaths = FileSearchConfiguration.parsePaths(searchIn.stringValue)
        c.general.useRegex = regexBox.state == .on
        c.general.selectedItemsOnly = selectedOnlyBox.state == .on
        c.general.depth = Self.depthChoices[max(0, depthPopup.indexOfSelectedItem)].1
        c.general.content.enabled = findTextBox.state == .on
        c.general.content.expression = findTextField.stringValue
        c.general.content.wholeWordsOnly = wholeWordsBox.state == .on
        c.general.content.caseSensitive = caseBox.state == .on
        c.general.content.useRegex = textRegexBox.state == .on
        c.general.content.hexadecimal = hexBox.state == .on
        c.general.content.invertMatch = notBox.state == .on
        c.general.content.charsets = ContentCharset.allCases.filter { charsetBoxes[$0]?.state == .on }

        c.advanced.dateBetweenEnabled = dateBetweenBox.state == .on
        c.advanced.dateFrom = dateFromPicker.dateValue
        c.advanced.dateTo = dateToPicker.dateValue
        var problem: SearchValidationError?
        func int(_ field: NSTextField, _ name: String, active: Bool) -> Int {
            if let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), v >= 0 { return v }
            if active && problem == nil { problem = SearchValidationError(message: "“\(name)” needs a whole number of 0 or more.") }
            return 1
        }
        c.advanced.notOlderThan = AgeFilter(enabled: notOlderBox.state == .on,
                                            value: int(notOlderField, "Not older than", active: notOlderBox.state == .on),
                                            unit: AgeUnit.allCases[max(0, notOlderUnit.indexOfSelectedItem)])
        c.advanced.olderThan = AgeFilter(enabled: olderBox.state == .on,
                                         value: int(olderField, "Older than", active: olderBox.state == .on),
                                         unit: AgeUnit.allCases[max(0, olderUnit.indexOfSelectedItem)])
        let sizeText = sizeField.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let sizeValue = Double(sizeText)
        if sizeBox.state == .on && (sizeValue == nil || sizeValue! < 0) && problem == nil {
            problem = SearchValidationError(message: "“File size” needs a number of 0 or more.")
        }
        c.advanced.fileSize = SizeFilter(enabled: sizeBox.state == .on,
                                         comparison: ComparisonOperator.allCases[max(0, sizeOperator.indexOfSelectedItem)],
                                         value: sizeValue ?? 1,
                                         unit: SizeUnit.allCases[max(0, sizeUnit.indexOfSelectedItem)])
        c.advanced.attributesEnabled = attributesBox.state == .on
        var attrs: [FileAttribute: TriState] = [:]
        for (attribute, box) in attributeBoxes where attribute.isAvailable {
            switch box.state {
            case .on: attrs[attribute] = .required
            case .off: attrs[attribute] = .excluded
            default: break
            }
        }
        c.advanced.attributes = attrs
        c.advanced.duplicates = DuplicateSearchConfiguration(enabled: duplicatesBox.state == .on,
                                                             sameName: sameNameBox.state == .on,
                                                             sameSize: sameSizeBox.state == .on,
                                                             sameContents: sameContentsBox.state == .on)
        config = c
        return problem
    }

    @objc private func controlChanged() {
        updateEnabled()
    }

    @objc private func stepped(_ sender: NSStepper) {
        let field = sender === notOlderStepper ? notOlderField : sender === olderStepper ? olderField : sizeField
        field.stringValue = String(sender.integerValue)
    }

    /// Greys out controls whose section is switched off, as in Total Commander.
    private func updateEnabled() {
        let text = findTextBox.state == .on
        let hex = hexBox.state == .on
        findTextField.isEnabled = text
        for b in [wholeWordsBox, caseBox, textRegexBox] { b.isEnabled = text && !hex }
        hexBox.isEnabled = text
        notBox.isEnabled = text
        for b in charsetBoxes.values { b.isEnabled = text && !hex }
        let hasSelection = !(commander?.activeView.model.marked.isEmpty ?? true)
        selectedOnlyBox.isEnabled = hasSelection || selectedOnlyBox.state == .on
        searchIn.isEnabled = selectedOnlyBox.state != .on
        browseButton.isEnabled = searchIn.isEnabled
        drivesButton.isEnabled = searchIn.isEnabled
        let dates = dateBetweenBox.state == .on
        for v in [dateFromPicker, dateToPicker, dateFromButton, dateToButton] as [NSControl] { v.isEnabled = dates }
        for v in [notOlderField, notOlderStepper, notOlderUnit] as [NSControl] { v.isEnabled = notOlderBox.state == .on }
        for v in [olderField, olderStepper, olderUnit] as [NSControl] { v.isEnabled = olderBox.state == .on }
        for v in [sizeOperator, sizeField, sizeStepper, sizeUnit] as [NSControl] { v.isEnabled = sizeBox.state == .on }
        for (attribute, box) in attributeBoxes {
            box.isEnabled = attributesBox.state == .on && attribute.isAvailable
        }
        for b in [sameNameBox, sameSizeBox, sameContentsBox] { b.isEnabled = duplicatesBox.state == .on }
        startButton.isEnabled = !isSearching
        let enabled = Self.resultButtons(hasResults: !rows.isEmpty, searching: isSearching)
        viewButton.isEnabled = enabled.view
        goToButton.isEnabled = enabled.goTo
        feedButton.isEnabled = enabled.feed
    }

    /// View and Go to file work as soon as there are results, also while the search runs;
    /// Feed to listbox waits for the complete list.
    static func resultButtons(hasResults: Bool, searching: Bool) -> (view: Bool, goTo: Bool, feed: Bool) {
        (hasResults, hasResults, hasResults && !searching)
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        let actions: [(NSButton, () -> Void)] = [
            (startButton, startSearch),
            (cancelButton, cancelPressed),
            (viewButton, { _ = self.viewFile() }),
            (newSearchButton, newSearch),
            (goToButton, goToFile),
            (feedButton, feedToListbox),
            (browseButton, browse),
            (drivesButton, showDrives),
        ]
        actions.first { $0.0 === sender }?.1()
    }

    // MARK: Searching

    @objc func startSearch() {
        guard !isSearching else { return }
        if let problem = readUI() { return show(problem) }
        // "Only search in selected": the marked entries of the active panel.
        let selected = commander.map { c in c.activeView.model.realEntries.filter { c.activeView.model.isMarked($0) }.map(\.url) } ?? []
        let base = commander?.activeView.model.directory ?? FileManager.default.homeDirectoryForCurrentUser
        let flag = CancelFlag()
        let search: FileSearch
        do {
            search = try FileSearch(
                config: config, selectedItems: selected, base: base,
                isCancelled: { flag.isCancelled },
                onFound: { [weak self] item in self?.enqueue(item) },
                onProgress: { [weak self] count, folder in
                    DispatchQueue.main.async {
                        guard let self = self, self.isSearching else { return }
                        self.setSummary("Searching…  \(count) items checked")
                        self.statusLabel.stringValue = folder
                    }
                },
                sessions: commander?.ftp.sessionLookup ?? { _ in nil },
                remoteAddress: { [weak self] text in self?.commander?.ftp.location(fromAddress: text) })
        } catch let error as SearchValidationError {
            return show(error)
        } catch {
            return show(SearchValidationError(message: error.localizedDescription))
        }
        remember()
        rows = []
        rebuildDisplayRows()
        cancelFlag = flag
        isSearching = true
        setSummary("Searching…")
        cancelButton.title = "Stop"
        updateEnabled()

        if runSynchronously {
            finish(search.run())
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let report = search.run()
                DispatchQueue.main.async { [weak self] in self?.finish(report) }
            }
        }
    }

    private func setSummary(_ text: String) {
        summary = text
        table.reloadData(forRowIndexes: IndexSet(integer: 0), columnIndexes: IndexSet(integer: 0))
    }

    private func rebuildDisplayRows() {
        var list: [DisplayRow] = [.summary]
        var lastGroup: Int?
        for (i, r) in rows.enumerated() {
            if let g = r.group, let last = lastGroup, g != last { list.append(.separator) }
            lastGroup = r.group
            list.append(.item(i))
        }
        displayRows = list
        table.reloadData()
    }

    /// Results arrive on the search thread; they are shown in batches, a few times a second.
    private func enqueue(_ item: SearchItem) {
        if runSynchronously {
            rows.append(Row(item: item, group: nil))
            return
        }
        pendingLock.lock()
        pending.append(item)
        let first = pending.count == 1
        pendingLock.unlock()
        if first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        pendingLock.lock()
        let batch = pending
        pending = []
        pendingLock.unlock()
        guard !batch.isEmpty else { return }
        rows += batch.map { Row(item: $0, group: nil) }
        rebuildDisplayRows()
        updateEnabled()   // View / Go to file become usable with the first results
    }

    private func finish(_ report: FileSearch.Report) {
        flush()
        isSearching = false
        cancelFlag = nil
        if let groups = report.duplicateGroups {
            rows = groups.flatMap { g in g.items.map { Row(item: $0, group: g.id) } }
        } else if runSynchronously {
            rows = report.found.map { Row(item: $0, group: nil) }
        }
        lastErrors = report.errors
        var text: String
        if let groups = report.duplicateGroups {
            text = "[\(rows.count) duplicate files in \(groups.count) group\(groups.count == 1 ? "" : "s") found]"
        } else {
            text = "[\(report.fileCount) files and \(report.directoryCount) directories found]"
        }
        if report.cancelled { text += " - search aborted" }
        summary = text
        rebuildDisplayRows()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        statusLabel.stringValue = report.errors.isEmpty
            ? text : "\(text)  ·  \(report.errors.count) could not be read (hover for details)"
        statusLabel.toolTip = report.errors.isEmpty ? nil : report.errors.prefix(30).joined(separator: "\n")
        cancelButton.title = "Cancel"
        updateEnabled()
    }

    private func cancelPressed() {
        if isSearching {
            cancelFlag?.cancel()
        } else {
            window?.performClose(nil)
        }
    }

    private func newSearch() {
        guard !isSearching else { return }
        rows = []
        summary = ""
        rebuildDisplayRows()
        statusLabel.stringValue = ""
        tabs.selectTabViewItem(at: 0)
        updateEnabled()
        window?.makeFirstResponder(searchFor)
    }

    /// The result on the selected (or double-clicked) line, if it is a file line.
    private var chosenRow: Row? {
        let line = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard displayRows.indices.contains(line), case .item(let i) = displayRows[line] else { return nil }
        return rows[i]
    }

    /// Shows the selected result in the active panel and closes the dialog.
    @objc func goToFile() {
        guard let row = chosenRow else { return NSSound.beep() }
        commander?.reveal(row.item.url)
        window?.performClose(nil)
    }

    /// Puts all results into the active panel as a listing (marks, copy, delete work there).
    func feedToListbox() {
        guard !rows.isEmpty, let panel = commander?.activeView else { return NSSound.beep() }
        if rows.contains(where: { $0.item.url.isRemoteLocation }) {
            return show(SearchValidationError(message: "Feed to listbox works for files on this Mac. Use Go to file for results on a server."))
        }
        panel.model.showSearchResults(rows.map(\.item.url), title: "Search results: \(config.general.filenamePattern)",
                                      visibleRows: panel.visibleRows)
        panel.needsDisplay = true
        window?.performClose(nil)
        commander?.window?.makeKeyAndOrderFront(nil)
        if let c = commander { c.window?.makeFirstResponder(c) }
    }

    /// "View" (and the View key, "3" / F3, in the results list): Lister on the selected result;
    /// n / p in Lister step through the found files.
    @discardableResult
    func viewFile() -> ListerWindowController? {
        guard let row = chosenRow, !row.item.isDirectory, let commander = commander else { NSSound.beep(); return nil }
        if row.item.url.isRemoteLocation {
            commander.ftp.viewRemote(row.item.url, size: row.item.size)
            return nil
        }
        let files = rows.filter { !$0.item.isDirectory && !$0.item.url.isRemoteLocation }.map(\.item.url)
        let index = files.firstIndex(of: row.item.url) ?? 0
        return commander.openLister(files: files, index: index, onNavigate: { [weak self] url in
            guard let self = self else { return }
            if let idx = self.rows.firstIndex(where: { $0.item.url == url }) {
                self.table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                self.table.scrollRowToVisible(idx)
            }
        })
    }

    /// Keys in the results list: the View shortcut opens Lister, Return goes to the file.
    func handleResultsKey(_ event: NSEvent) -> Bool {
        let combo = KeyCombo(event)
        if let keys = commander?.settings.keys, keys.action(for: combo) == .view {
            viewFile()
            return true
        }
        if combo == KeyCombo(KeyCode.returnKey) || combo == KeyCombo(KeyCode.keypadEnter) {
            goToFile()
            return true
        }
        return false
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Search Here"
        Modal.choose(panel, for: window) { [weak self] urls in
            guard !urls.isEmpty, let self = self else { return }
            self.searchIn.stringValue = urls.map(\.path).joined(separator: "; ")
        }
    }

    /// "Drives": pick a mounted volume to search; ⌥ adds it to the folders already there.
    private func showDrives() {
        let menu = NSMenu()
        for drive in LocationMenu.mountedDrives() {
            let item = NSMenuItem(title: LocationMenu.title(for: drive), action: #selector(driveChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = drive.url.path
            let icon = NSWorkspace.shared.icon(forFile: drive.url.path).copy() as! NSImage
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        Modal.popUp(menu, at: NSPoint(x: 0, y: drivesButton.bounds.height + 2), in: drivesButton)
    }

    @objc private func driveChosen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        if NSEvent.modifierFlags.contains(.option), !searchIn.stringValue.isEmpty {
            searchIn.stringValue += "; " + path
        } else {
            searchIn.stringValue = path
        }
    }

    @objc private func showCalendar(_ sender: NSButton) {
        calendarTarget = sender === dateFromButton ? dateFromPicker : dateToPicker
        calendar.dateValue = calendarTarget?.dateValue ?? Date()
        calendarPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func calendarPicked() {
        calendarTarget?.dateValue = calendar.dateValue
    }

    private func show(_ error: SearchValidationError) {
        if runSynchronously {
            statusLabel.stringValue = error.message
            return
        }
        let alert = NSAlert()
        alert.messageText = "Find Files"
        alert.informativeText = error.message
        Modal.sheet(alert, for: window)
    }

    /// Saves the settings and puts the current texts at the top of the histories.
    private func remember() {
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: Key.config) }
        for (box, key) in [(searchFor, Key.forHistory), (searchIn, Key.inHistory), (findTextField, Key.textHistory)] {
            let value = box.stringValue
            guard !value.isEmpty, box !== findTextField || findTextBox.state == .on else { continue }
            var history = defaults.stringArray(forKey: key) ?? []
            history.removeAll { $0 == value }
            history.insert(value, at: 0)
            history = Array(history.prefix(15))
            defaults.set(history, forKey: key)
            box.removeAllItems()
            box.addItems(withObjectValues: history)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        // Cancel keeps the configuration (remembered), and stops any running search.
        cancelFlag?.cancel()
        calendarPopover.close()
        readUI()
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: Key.config) }
    }

    // MARK: Tables

    public func numberOfRows(in tableView: NSTableView) -> Int {
        displayRows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let label: NSTextField
        switch displayRows[row] {
        case .summary:
            label = NSTextField(labelWithString: summary)
            label.font = .boldSystemFont(ofSize: 13)
        case .separator:
            label = NSTextField(labelWithString: String(repeating: "–", count: 60))
            label.textColor = .tertiaryLabelColor
        case .item(let i):
            let url = rows[i].item.url
            let shown = url.isRemoteLocation ? commander?.ftp.displayAddress(of: url) ?? url.path : url.path
            label = NSTextField(labelWithString: EntryFormatter.visible(shown) + (rows[i].item.isDirectory ? "/" : ""))
            label.lineBreakMode = .byTruncatingMiddle
        }
        return AppWindows.centeredCell(label)
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .separator = displayRows[row] { return false }
        return true
    }
}

/// The results list: passes keys to the dialog first (View shortcut, Return).
public final class ResultsTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?

    public override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}
