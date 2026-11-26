import AppKit
import UniformTypeIdentifiers

/// Synchronize → View (3): two files side by side. Lines are aligned, differences highlighted,
/// and ↑ / ↓ (or p / n, ⌥↑ / ⌥↓) jump between blocks of differences. Identical files say so.
final class DiffWindowController: NSWindowController, NSWindowDelegate {
    private let leftTitle: String
    private let rightTitle: String
    let leftText = DiffTextView()
    let rightText = DiffTextView()
    private let leftScroll = NSScrollView()
    private let rightScroll = NSScrollView()
    let statusLabel = NSTextField(labelWithString: "…")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private(set) var diff: TextDiff?
    /// The block shown last (index into diff.blocks).
    private(set) var currentBlock: Int?
    private var syncing = false
    /// Temporary downloads to remove when the window closes.
    var temporaryFiles: [URL] = []

    init(leftTitle: String, rightTitle: String) {
        self.leftTitle = leftTitle
        self.rightTitle = rightTitle
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = AppWindows.title("Compare: " + (leftTitle as NSString).lastPathComponent)
        AppWindows.style(window)
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

        // Configure arrow up and down navigation buttons
        for b in [previousButton, nextButton] {
            b.bezelStyle = .regularSquare
            b.isBordered = true
            b.showsBorderOnlyWhileMouseInside = false
            b.controlSize = .small
            b.target = self
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        if let upImg = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Previous difference") {
            previousButton.image = upImg
            previousButton.imagePosition = .imageOnly
        } else {
            previousButton.title = "↑"
        }
        previousButton.action = #selector(previousDifference)
        previousButton.toolTip = "Previous difference (⌥↑ or p)"

        if let downImg = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Next difference") {
            nextButton.image = downImg
            nextButton.imagePosition = .imageOnly
        } else {
            nextButton.title = "↓"
        }
        nextButton.action = #selector(nextDifference)
        nextButton.toolTip = "Next difference (⌥↓ or n)"

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .center
        statusLabel.textColor = .labelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Vertical navigation cluster in the center divider
        let navStack = NSStackView(views: [previousButton, statusLabel, nextButton])
        navStack.orientation = .vertical
        navStack.alignment = .centerX
        navStack.spacing = 6
        navStack.translatesAutoresizingMaskIntoConstraints = false

        // File badge helpers for left and right files
        func makeFileBadge(for path: String) -> NSView {
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false

            let ext = (path as NSString).pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            let icon = NSWorkspace.shared.icon(for: type)
            icon.size = NSSize(width: 16, height: 16)
            let iconView = NSImageView(image: icon)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true

            let filename = (path as NSString).lastPathComponent
            let nameLabel = NSTextField(labelWithString: filename)
            nameLabel.font = .systemFont(ofSize: 13, weight: .bold)
            nameLabel.textColor = .labelColor
            nameLabel.lineBreakMode = .byTruncatingMiddle

            let pathLabel = NSTextField(labelWithString: path)
            pathLabel.font = .systemFont(ofSize: 10)
            pathLabel.textColor = .secondaryLabelColor
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.toolTip = path

            let textCol = NSStackView(views: [nameLabel, pathLabel])
            textCol.orientation = .vertical
            textCol.alignment = .leading
            textCol.spacing = 1
            textCol.translatesAutoresizingMaskIntoConstraints = false

            let row = NSStackView(views: [iconView, textCol])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 7
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)

            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                row.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4),
                row.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
                row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            ])
            return container
        }

        let leftBadge = makeFileBadge(for: leftTitle)
        let rightBadge = makeFileBadge(for: rightTitle)

        let topBar = DiffTopBarView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(leftBadge)
        topBar.addSubview(rightBadge)

        // Middle vertical divider with vertical navigation stack
        let dividerView = DiffDividerView()
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        dividerView.addSubview(navStack)

        NSLayoutConstraint.activate([
            navStack.centerXAnchor.constraint(equalTo: dividerView.centerXAnchor),
            navStack.topAnchor.constraint(equalTo: dividerView.topAnchor, constant: 14),
            navStack.widthAnchor.constraint(lessThanOrEqualTo: dividerView.widthAnchor, constant: -4),
        ])

        leftScroll.translatesAutoresizingMaskIntoConstraints = false
        rightScroll.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(topBar)
        root.addSubview(leftScroll)
        root.addSubview(dividerView)
        root.addSubview(rightScroll)

        NSLayoutConstraint.activate([
            topBar.heightAnchor.constraint(equalToConstant: 44),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: root.topAnchor),

            leftScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            leftScroll.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            leftScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),

            dividerView.leadingAnchor.constraint(equalTo: leftScroll.trailingAnchor, constant: 4),
            dividerView.topAnchor.constraint(equalTo: leftScroll.topAnchor),
            dividerView.bottomAnchor.constraint(equalTo: leftScroll.bottomAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: 38),

            rightScroll.leadingAnchor.constraint(equalTo: dividerView.trailingAnchor, constant: 4),
            rightScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            rightScroll.topAnchor.constraint(equalTo: leftScroll.topAnchor),
            rightScroll.bottomAnchor.constraint(equalTo: leftScroll.bottomAnchor),

            leftScroll.widthAnchor.constraint(equalTo: rightScroll.widthAnchor),

            leftBadge.leadingAnchor.constraint(equalTo: leftScroll.leadingAnchor, constant: 4),
            leftBadge.trailingAnchor.constraint(equalTo: leftScroll.trailingAnchor, constant: -4),
            leftBadge.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            rightBadge.leadingAnchor.constraint(equalTo: rightScroll.leadingAnchor, constant: 4),
            rightBadge.trailingAnchor.constraint(equalTo: rightScroll.trailingAnchor, constant: -4),
            rightBadge.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
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
                case .changed: background = NSColor.systemYellow.withAlphaComponent(0.20)
                case .removed: background = left ? NSColor.systemRed.withAlphaComponent(0.20) : NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
                case .added: background = left ? NSColor.quaternaryLabelColor.withAlphaComponent(0.06) : NSColor.systemGreen.withAlphaComponent(0.22)
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
        statusLabel.stringValue = "\(block + 1)/\(d.blocks.count)"
        statusLabel.toolTip = "Difference \(block + 1) of \(d.blocks.count)"
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

    /// Deletes downloaded copies (also used when the window closed before they arrived).
    static func removeTemporaryFiles(_ files: [URL]) {
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    func windowWillClose(_ notification: Notification) {
        Self.removeTemporaryFiles(temporaryFiles)
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

final class DiffTopBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0.5))
        path.line(to: NSPoint(x: bounds.width, y: 0.5))
        path.lineWidth = 1.0
        path.stroke()
    }
}

final class DiffDividerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }
}
