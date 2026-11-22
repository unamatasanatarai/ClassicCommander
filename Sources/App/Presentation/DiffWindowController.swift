import AppKit

/// Synchronize → View (3): two files side by side. Lines are aligned, differences highlighted,
/// and ◀ / ▶ (or p / n, ⌥↑ / ⌥↓) jump between blocks of differences. Identical files say so.
final class DiffWindowController: NSWindowController, NSWindowDelegate {
    private let leftTitle: String
    private let rightTitle: String
    let leftText = DiffTextView()
    let rightText = DiffTextView()
    private let leftScroll = NSScrollView()
    private let rightScroll = NSScrollView()
    let statusLabel = NSTextField(labelWithString: "Loading…")
    private let previousButton = NSButton(title: "◀ Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next ▶", target: nil, action: nil)
    private(set) var diff: TextDiff?
    /// The block shown last (index into diff.blocks).
    private(set) var currentBlock: Int?
    private var syncing = false
    /// Temporary downloads to remove when the window closes.
    var temporaryFiles: [URL] = []

    init(leftTitle: String, rightTitle: String) {
        self.leftTitle = leftTitle
        self.rightTitle = rightTitle
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = "Compare: " + (leftTitle as NSString).lastPathComponent
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 300)
        super.init(window: window)
        window.delegate = self
        window.contentView = build()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() -> NSView {
        for (view, scroll) in [(leftText, leftScroll), (rightText, rightScroll)] {
            view.isEditable = false
            view.isRichText = true
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.isHorizontallyResizable = true
            view.autoresizingMask = []
            view.owner = self
            scroll.documentView = view
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.borderType = .bezelBorder
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        for b in [previousButton, nextButton] {
            b.bezelStyle = .rounded
            b.target = self
        }
        previousButton.action = #selector(previousDifference)
        nextButton.action = #selector(nextDifference)
        previousButton.toolTip = "Previous difference (p or ⌥↑)"
        nextButton.toolTip = "Next difference (n or ⌥↓)"
        statusLabel.font = .boldSystemFont(ofSize: 13)
        statusLabel.lineBreakMode = .byTruncatingTail

        let lt = NSTextField(labelWithString: leftTitle), rt = NSTextField(labelWithString: rightTitle)
        for t in [lt, rt] {
            t.lineBreakMode = .byTruncatingMiddle
            t.textColor = .secondaryLabelColor
            t.toolTip = t.stringValue
        }
        let top = NSStackView(views: [previousButton, nextButton, statusLabel])
        top.spacing = 8
        let split = NSStackView(views: [leftScroll, rightScroll])
        split.distribution = .fillEqually
        split.spacing = 6
        let titles = NSStackView(views: [lt, rt])
        titles.distribution = .fillEqually
        titles.spacing = 6
        let stack = NSStackView(views: [top, titles, split])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            titles.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            split.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
        updateButtons()
        return root
    }

    // MARK: Content

    func showError(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        updateButtons()
    }

    func show(_ comparison: FileComparison) {
        switch comparison {
        case .binary(let identical, let first):
            diff = nil
            statusLabel.stringValue = identical ? "The files are identical."
                : "Binary files differ" + (first.map { " (first difference at byte \($0))" } ?? "") + "."
            statusLabel.textColor = identical ? .systemGreen : .systemRed
            leftText.textStorage?.setAttributedString(NSAttributedString(string: identical ? "" : "(binary file)"))
            rightText.textStorage?.setAttributedString(NSAttributedString(string: identical ? "" : "(binary file)"))
        case .text(let d):
            diff = d
            render(d)
            if d.isIdentical {
                statusLabel.stringValue = "The files are identical (\(d.rows.count) lines)."
                statusLabel.textColor = .systemGreen
            } else {
                statusLabel.textColor = .labelColor
                currentBlock = nil
                nextDifference()
            }
        }
        updateButtons()
    }

    private func render(_ d: TextDiff) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let numberWidth = String(max(d.rows.compactMap(\.leftNumber).max() ?? 0, d.rows.compactMap(\.rightNumber).max() ?? 0)).count
        func side(_ left: Bool) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for row in d.rows {
                let text = (left ? row.left : row.right) ?? ""
                let number = (left ? row.leftNumber : row.rightNumber).map { String($0) } ?? ""
                let pad = String(repeating: " ", count: max(0, numberWidth - number.count))
                var background: NSColor?
                switch row.kind {
                case .same: background = nil
                case .changed: background = NSColor.systemYellow.withAlphaComponent(0.28)
                case .removed: background = left ? NSColor.systemRed.withAlphaComponent(0.28) : NSColor.gray.withAlphaComponent(0.15)
                case .added: background = left ? NSColor.gray.withAlphaComponent(0.15) : NSColor.systemGreen.withAlphaComponent(0.28)
                }
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
                if let bg = background { attrs[.backgroundColor] = bg }
                out.append(NSAttributedString(string: pad + number + " ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
                out.append(NSAttributedString(string: text.replacingOccurrences(of: "\t", with: "    ") + "\n", attributes: attrs))
            }
            return out
        }
        leftText.textStorage?.setAttributedString(side(true))
        rightText.textStorage?.setAttributedString(side(false))
    }

    // MARK: Navigation

    @objc func nextDifference() {
        guard let d = diff, !d.blocks.isEmpty else { return NSSound.beep() }
        let next = currentBlock.map { $0 + 1 } ?? 0
        guard next < d.blocks.count else { return NSSound.beep() }
        go(to: next)
    }

    @objc func previousDifference() {
        guard let d = diff, let current = currentBlock, current > 0 else { return NSSound.beep() }
        go(to: current - 1)
        _ = d
    }

    private func go(to block: Int) {
        guard let d = diff else { return }
        currentBlock = block
        let row = d.blocks[block]
        statusLabel.stringValue = "Difference \(block + 1) of \(d.blocks.count)"
        for view in [leftText, rightText] { scroll(view, toLine: row) }
        updateButtons()
    }

    /// Scrolls so that line `row` (0-based) sits a few lines below the top, and selects it.
    private func scroll(_ view: NSTextView, toLine row: Int) {
        guard let layout = view.layoutManager, let container = view.textContainer else { return }
        let text = view.string as NSString
        var index = 0, line = 0
        while line < row && index < text.length {
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            line += 1
        }
        let lineRange = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let target = NSPoint(x: 0, y: max(0, rect.minY - 4 * rect.height))
        view.enclosingScrollView?.contentView.scroll(to: target)
        view.enclosingScrollView?.reflectScrolledClipView(view.enclosingScrollView!.contentView)
        view.setSelectedRange(NSRange(location: lineRange.location, length: 0))
    }

    private func updateButtons() {
        let count = diff?.blocks.count ?? 0
        nextButton.isEnabled = count > 0 && (currentBlock.map { $0 + 1 < count } ?? true)
        previousButton.isEnabled = (currentBlock ?? 0) > 0
    }

    /// Both sides scroll together (lines are aligned).
    @objc private func scrolled(_ note: Notification) {
        guard !syncing, let clip = note.object as? NSClipView else { return }
        syncing = true
        let other = clip === leftScroll.contentView ? rightScroll : leftScroll
        other.contentView.scroll(to: clip.bounds.origin)
        other.reflectScrolledClipView(other.contentView)
        syncing = false
    }

    /// n / p and ⌥↓ / ⌥↑ in either text view.
    func handleKey(_ event: NSEvent) -> Bool {
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let option = event.modifierFlags.contains(.option)
        if ch == "n" || (option && event.keyCode == 125) { nextDifference(); return true }
        if ch == "p" || (option && event.keyCode == 126) { previousDifference(); return true }
        if event.keyCode == 53 { window?.performClose(nil); return true }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        for f in temporaryFiles { try? FileManager.default.removeItem(at: f) }
        temporaryFiles = []
        NotificationCenter.default.removeObserver(self)
    }
}

final class DiffTextView: NSTextView {
    weak var owner: DiffWindowController?

    override func keyDown(with event: NSEvent) {
        if owner?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }
}
