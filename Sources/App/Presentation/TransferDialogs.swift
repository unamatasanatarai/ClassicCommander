import AppKit

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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 210), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = AppWindows.title(question.verb)
        AppWindows.style(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()
        window.initialFirstResponder = targetField
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

        let okButton = NSButton(title: "OK", target: self, action: #selector(okPressed))
        okButton.keyEquivalent = "\r"
        let queueButton = NSButton(title: "Queue (⌃2)", target: self, action: #selector(queuePressed))
        queueButton.keyEquivalent = "2"
        queueButton.keyEquivalentModifierMask = .control
        queueButton.toolTip = "Add to the queue: runs after the queued jobs before it"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.keyEquivalent = "\u{1b}"
        for b in [okButton, queueButton, cancelButton] {
            b.bezelStyle = .rounded
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        }
        let typeRow = NSStackView(views: [NSTextField(labelWithString: "Only files of type:"), NSView(), statsLabel])
        let buttons = NSStackView(views: [okButton, queueButton, NSView(), cancelButton])
        let stack = NSStackView(views: [message, targetField, typeRow, maskField, verifyBox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: targetField)
        stack.setCustomSpacing(14, after: verifyBox)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            targetField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            typeRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            maskField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 220), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = AppWindows.title("Target file exists")
        AppWindows.style(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()
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
        title.font = .boldSystemFont(ofSize: 14)
        func block(_ heading: String, _ path: String, _ details: String) -> NSView {
            let h = NSTextField(labelWithString: heading)
            h.textColor = .secondaryLabelColor
            let p = NSTextField(labelWithString: path)
            p.lineBreakMode = .byTruncatingMiddle
            p.font = .systemFont(ofSize: 13, weight: .medium)
            p.toolTip = path
            let d = NSTextField(labelWithString: details)
            let stack = NSStackView(views: [h, p, d])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            return stack
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
        buttons[buttons.count - 1].keyEquivalent = "\u{1b}"
        let row1 = NSStackView(views: [buttons[0], buttons[1], buttons[4]])
        row1.spacing = 8
        let row2 = NSStackView(views: [buttons[2], buttons[3], buttons[5], buttons[6]])
        row2.spacing = 8
        let buttonStack = NSStackView(views: [row1, row2])
        buttonStack.orientation = .vertical
        buttonStack.alignment = .leading
        buttonStack.spacing = 8
        let stack = NSStackView(views: [title, replace, with, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            replace.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            with.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
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
