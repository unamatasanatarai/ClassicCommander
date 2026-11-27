import AppKit
import UniformTypeIdentifiers

/// The Copy / Move dialog (5 / 6, and drops): target, "only files of type" with what that adds up
/// to, Verify, and OK (Return) to start now, Queue (⌃2) to line it up, or Cancel (Esc).
final class TransferDialogController: NSWindowController, NSComboBoxDelegate {
    static let ok = NSApplication.ModalResponse.OK
    static let queue = NSApplication.ModalResponse(rawValue: 1001)

    private let question: TransferQuestion
    private let defaults: UserDefaults
    private let sizeFormat: SizeFormat
    let targetField = NSComboBox()
    let maskField = NSComboBox()
    let statsLabel = NSTextField(labelWithString: "Counting…")
    let verifyBox = NSButton(checkboxWithTitle: "Verify (read each copy back and compare)", target: nil, action: nil)
    let okButton = NSButton(title: "OK", target: nil, action: nil)
    let queueButton = NSButton(title: "Queue (⌃2)", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var counting: CancelFlag?
    /// The newest stats shown (tests wait for them).
    private(set) var stats: TransferStats?

    private enum Key {
        static let targets = "copy.targetHistory"
        static let masks = "copy.maskHistory"
        static let verify = "copy.verify"
    }

    init(question: TransferQuestion, sizeFormat: SizeFormat, defaults: UserDefaults = .standard) {
        self.question = question
        self.defaults = defaults
        self.sizeFormat = sizeFormat
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = AppWindows.title(question.verb)
        AppWindows.style(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()
        AppWindows.setTabOrder([targetField, maskField, verifyBox, queueButton, cancelButton, okButton], in: window)
        recount()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() -> NSView {
        let message = NSTextField(labelWithString: question.message)
        targetField.stringValue = question.defaultTarget
        targetField.addItems(withObjectValues: defaults.stringArray(forKey: Key.targets) ?? [])
        maskField.placeholderString = "all files — or e.g. *.jpg;*.png"
        maskField.addItems(withObjectValues: defaults.stringArray(forKey: Key.masks) ?? [])
        maskField.delegate = self
        maskField.target = self
        maskField.action = #selector(maskChanged)
        verifyBox.state = defaults.bool(forKey: Key.verify) ? .on : .off
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.alignment = .right

        okButton.target = self
        okButton.action = #selector(okPressed)
        okButton.keyEquivalent = "\r"
        queueButton.target = self
        queueButton.action = #selector(queuePressed)
        queueButton.keyEquivalent = "2"
        queueButton.keyEquivalentModifierMask = .control
        queueButton.toolTip = "Add to the queue: runs after the queued jobs before it"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        for b in [okButton, queueButton, cancelButton] {
            b.bezelStyle = .rounded
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: AppWindows.Layout.buttonMinWidth).isActive = true
        }
        let typeLabel = NSTextField(labelWithString: "Only files of type:")
        typeLabel.setContentHuggingPriority(.required, for: .horizontal)
        typeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statsLabel.setContentHuggingPriority(.required, for: .horizontal)
        statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let typeSpacer = NSView()
        typeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let typeRow = NSStackView(views: [typeLabel, typeSpacer, statsLabel])
        typeRow.spacing = AppWindows.Layout.controlSpacing

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [queueButton, buttonSpacer, cancelButton, okButton])
        buttons.spacing = AppWindows.Layout.controlSpacing

        let m = AppWindows.Layout.margin
        let stack = NSStackView(views: [message, targetField, typeRow, maskField, verifyBox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AppWindows.Layout.controlSpacing
        stack.setCustomSpacing(AppWindows.Layout.sectionSpacing, after: targetField)
        stack.setCustomSpacing(AppWindows.Layout.margin, after: verifyBox)
        stack.edgeInsets = NSEdgeInsets(top: m, left: m, bottom: m, right: m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 480),
            targetField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            typeRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            maskField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
        ])
        return root
    }

    /// Shows the dialog until a button is pressed; nil for Cancel.
    func run() -> TransferAnswer? {
        guard let window = window else { return nil }
        AppWindows.place(window)
        let response = Modal.runWindow(window)
        window.orderOut(nil)
        counting?.cancel()
        guard response == Self.ok || response == Self.queue else { return nil }
        let answer = TransferAnswer(target: targetField.stringValue.trimmingCharacters(in: .whitespaces),
                                    mask: maskField.stringValue.trimmingCharacters(in: .whitespaces),
                                    verify: verifyBox.state == .on, queue: response == Self.queue)
        guard !answer.target.isEmpty else { return nil }
        remember(answer)
        return answer
    }

    /// Puts the target and mask at the top of their histories; Verify is remembered as set.
    private func remember(_ answer: TransferAnswer) {
        for (value, key) in [(answer.target, Key.targets), (answer.mask, Key.masks)] where !value.isEmpty {
            var history = defaults.stringArray(forKey: key) ?? []
            history.removeAll { $0 == value }
            history.insert(value, at: 0)
            defaults.set(Array(history.prefix(15)), forKey: key)
        }
        defaults.set(answer.verify, forKey: Key.verify)
    }

    @objc func okPressed() { NSApp.stopModal(withCode: Self.ok) }
    @objc func queuePressed() { NSApp.stopModal(withCode: Self.queue) }
    @objc func cancelPressed() { NSApp.stopModal(withCode: .cancel) }

    // MARK: What it adds up to

    @objc func maskChanged() { recount() }
    func controlTextDidChange(_ obj: Notification) { recount() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.recount() }
    }

    /// Counts in the background (local folders are walked), newest request wins.
    func recount() {
        counting?.cancel()
        let flag = CancelFlag()
        counting = flag
        let text = maskField.stringValue.trimmingCharacters(in: .whitespaces)
        let mask = text.isEmpty ? nil : FileMask(text)
        let count = question.count
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stats = count(mask, flag)
            DispatchQueue.main.async {
                guard !flag.isCancelled else { return }
                self?.show(stats)
            }
        }
    }

    func show(_ stats: TransferStats) {
        self.stats = stats
        let f = EntryFormatter.shared
        var text = "\(f.size(stats.bytes, as: sizeFormat)) · \(stats.files) file\(stats.files == 1 ? "" : "s")"
        if stats.folders > 0 { text += " · \(stats.folders) folder\(stats.folders == 1 ? "" : "s")" }
        if !stats.complete { text += " (server folders not counted)" }
        statsLabel.stringValue = text
    }
}

/// "Target file exists": both files with path, size and date, and Replace, Replace all, Skip,
/// Skip all, Replace all older, Rename… or Cancel.
final class ConflictDialogController: NSWindowController {
    static let buttons: [(String, ConflictDecision?)] = [
        ("Replace", .replace), ("Replace All", .replaceAll), ("Skip", .skip), ("Skip All", .skipAll),
        ("Replace All Older", .replaceAllOlder), ("Rename…", nil), ("Cancel", .cancel),
    ]
    static let renameCode = 1005

    private let conflict: TransferConflict
    private let sizeFormat: SizeFormat
    private(set) var buttons: [NSButton] = []

    init(conflict: TransferConflict, sizeFormat: SizeFormat) {
        self.conflict = conflict
        self.sizeFormat = sizeFormat
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = AppWindows.title("Target file exists")
        AppWindows.style(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()
        // Visual reading order: Row 1 (Replace, Replace All, Replace All Older), Row 2 (Skip, Skip All, Rename…), Cancel.
        AppWindows.setTabOrder([buttons[0], buttons[1], buttons[4], buttons[2], buttons[3], buttons[5], buttons[6]], in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "2,1 MB, 22.05.2015 22:38:58" (or "size unknown").
    static func describe(_ size: Int64?, _ date: Date?, format: SizeFormat) -> String {
        let s = size.map { EntryFormatter.shared.size($0, as: format) } ?? "size unknown"
        let d = date.map { dateFormatter.string(from: $0) } ?? "date unknown"
        return "\(s), \(d)"
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private func build() -> NSView {
        let title = NSTextField(labelWithString: "The target file exists")
        title.font = .systemFont(ofSize: 14, weight: .bold)

        func block(_ heading: String, _ path: String, _ details: String) -> NSView {
            let ext = (path as NSString).pathExtension.lowercased()
            let type = UTType(filenameExtension: ext) ?? .data
            let icon = NSWorkspace.shared.icon(for: ext.isEmpty ? .data : type)
            icon.size = NSSize(width: 32, height: 32)
            let iconView = NSImageView(image: icon)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 32).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 32).isActive = true

            let h = NSTextField(labelWithString: heading)
            h.textColor = .secondaryLabelColor
            h.font = .systemFont(ofSize: 11, weight: .bold)

            let p = NSTextField(labelWithString: path)
            p.lineBreakMode = .byTruncatingMiddle
            p.font = .systemFont(ofSize: 12, weight: .medium)
            p.toolTip = path

            let d = NSTextField(labelWithString: details)
            d.textColor = .secondaryLabelColor
            d.font = .systemFont(ofSize: 11)

            let textStack = NSStackView(views: [h, p, d])
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 2

            let row = NSStackView(views: [iconView, textStack])
            row.alignment = NSLayoutConstraint.Attribute.centerY
            row.spacing = 10
            return row
        }

        let replace = block("Replace:", conflict.target.displayPath,
                            Self.describe(conflict.targetSize, conflict.targetDate, format: sizeFormat))
        let with = block("With:", conflict.source.displayPath,
                         Self.describe(conflict.sourceSize, conflict.sourceDate, format: sizeFormat))

        buttons = Self.buttons.enumerated().map { i, entry in
            let b = NSButton(title: entry.0, target: self, action: #selector(pressed(_:)))
            b.bezelStyle = .rounded
            b.tag = 1000 + i
            return b
        }
        buttons[0].keyEquivalent = "\r"
        buttons[1].keyEquivalent = "a"
        buttons[1].keyEquivalentModifierMask = []
        buttons[2].keyEquivalent = "s"
        buttons[2].keyEquivalentModifierMask = []
        buttons[3].keyEquivalent = "k"
        buttons[3].keyEquivalentModifierMask = []
        buttons[4].keyEquivalent = "o"
        buttons[4].keyEquivalentModifierMask = []
        buttons[5].keyEquivalent = "n"
        buttons[5].keyEquivalentModifierMask = []
        buttons[6].keyEquivalent = "\u{1b}"
        buttons[6].keyEquivalentModifierMask = []

        func underline(_ button: NSButton, at index: Int) {
            let attr = NSMutableAttributedString(string: button.title, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            ])
            attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: index, length: 1))
            button.attributedTitle = attr
        }
        underline(buttons[1], at: 8)  // Replace [A]ll
        underline(buttons[2], at: 0)  // [S]kip
        underline(buttons[3], at: 1)  // S[k]ip All
        underline(buttons[4], at: 12) // Replace All [O]lder
        underline(buttons[5], at: 2)  // Re[n]ame…

        // 3-column equal-width action rows (Overwrite row, Skip/Rename row) with Cancel at bottom-right.
        let row1 = NSStackView(views: [buttons[0], buttons[1], buttons[4]])
        let row2 = NSStackView(views: [buttons[2], buttons[3], buttons[5]])
        for row in [row1, row2] {
            row.distribution = .fillEqually
            row.spacing = AppWindows.Layout.controlSpacing
        }
        buttons[6].widthAnchor.constraint(greaterThanOrEqualToConstant: AppWindows.Layout.buttonMinWidth).isActive = true

        let sep = NSBox()
        sep.boxType = .separator

        let bottomBar = NSStackView(views: [NSView(), buttons[6]])
        bottomBar.spacing = AppWindows.Layout.controlSpacing

        let m = AppWindows.Layout.margin
        let stack = NSStackView(views: [title, replace, with, row1, row2, sep, bottomBar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AppWindows.Layout.controlSpacing
        stack.setCustomSpacing(AppWindows.Layout.sectionSpacing, after: title)
        stack.setCustomSpacing(AppWindows.Layout.sectionSpacing, after: with)
        stack.setCustomSpacing(AppWindows.Layout.sectionSpacing, after: row2)
        stack.edgeInsets = NSEdgeInsets(top: m, left: m, bottom: m, right: m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 480),
            replace.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -m * 2),
            with.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -m * 2),
            row1.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            row2.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            bottomBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
        ])
        return root
    }

    @objc func pressed(_ sender: NSButton) { NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag)) }

    /// Asks until there is an answer (Rename asks for the new name; cancelling that asks again).
    func run(askName: (String) -> String?) -> ConflictDecision {
        guard let window = window else { return .cancel }
        AppWindows.place(window)
        defer { window.orderOut(nil) }
        while true {
            let code = Modal.runWindow(window).rawValue - 1000
            guard Self.buttons.indices.contains(code) else { return .cancel }
            if let decision = Self.buttons[code].1 { return decision }
            if let name = askName(Self.suggestedName(for: conflict.target.name)) { return .rename(name) }
        }
    }

    /// "photo.jpg" → "photo (2).jpg".
    static func suggestedName(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base) (2)" : "\(base) (2).\(ext)"
    }
}
