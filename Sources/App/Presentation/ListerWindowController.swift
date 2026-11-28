import AppKit
import Quartz

/// Lister — the file viewer opened with "3" / F3, like Total Commander's.
///   1 Text · 2 Binary · 3 Hex · 4 Preview (Quick Look) — the starting mode suits the file.
///   n / p next / previous file of the panel, w word wrap, ⌘F or 7 / F7 find, Esc or q close.
/// Text and Binary show the first 8 MB; Hex reads on demand, so any size opens instantly.
public final class ListerWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// The files `n` / `p` step through (the panel's files, in panel order).
    private let files: [URL]
    private(set) var index: Int
    var onClose: ((ListerWindowController) -> Void)?
    public var onNavigate: ((URL) -> Void)?

    public private(set) var mode: ListerMode = .text
    public private(set) var encoding: ListerEncoding = .auto
    /// The encoding used for the current text (after auto detection).
    public private(set) var shownEncoding: ListerEncoding = .utf8
    public private(set) var wrap = true

    let modeControl = NSSegmentedControl()
    let encodingPopup = NSPopUpButton()
    let wrapBox = NSButton(checkboxWithTitle: "Wrap (w)", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    let textView: NSTextView
    private let textScroll: NSScrollView
    let hexTable = NSTableView()
    private let hexScroll = NSScrollView()
    private var preview: QLPreviewView?
    private let container = NSView()

    private var sample = Data()
    private var truncated = false
    private var hexReader: HexReader?
    private var monitor: Any?

    public var url: URL { files[index] }

    public init(files: [URL], index: Int) {
        self.files = files
        self.index = max(0, min(index, files.count - 1))
        textScroll = NSTextView.scrollableTextView()
        textView = textScroll.documentView as! NSTextView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        AppWindows.style(window)
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.setFrameAutosaveName("Lister")
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func present() {
        if let window = window { AppWindows.place(window) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        focusContent()
        installMonitor()
    }

    // MARK: Building

    private func buildContent() -> NSView {
        modeControl.segmentCount = ListerMode.allCases.count
        for (i, m) in ListerMode.allCases.enumerated() {
            modeControl.setLabel("\(m.rawValue) \(m.title)", forSegment: i)
        }
        modeControl.trackingMode = .selectOne
        modeControl.target = self
        modeControl.action = #selector(modeClicked)
        encodingPopup.addItems(withTitles: ListerEncoding.allCases.map(\.title))
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChosen)
        wrapBox.target = self
        wrapBox.action = #selector(toggleWrap)
        wrapBox.state = .on
        let bar = NSStackView(views: [modeControl, NSTextField(labelWithString: "Encoding:"), encodingPopup, wrapBox])
        bar.spacing = 10

        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textScroll.hasHorizontalScroller = true

        let column = NSTableColumn(identifier: .init("hex"))
        column.width = 900
        hexTable.addTableColumn(column)
        hexTable.headerView = nil
        hexTable.rowHeight = 17
        hexTable.intercellSpacing = .zero
        hexTable.dataSource = self
        hexTable.delegate = self
        hexTable.allowsMultipleSelection = true
        hexScroll.documentView = hexTable
        hexScroll.hasVerticalScroller = true
        hexScroll.hasHorizontalScroller = true

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [bar, container, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            container.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
        ])
        container.setContentHuggingPriority(.defaultLow, for: .vertical)
        return root
    }

    // MARK: Loading and modes

    /// Reads the current file and picks the mode that suits it.
    private func load() {
        window?.title = AppWindows.title("Lister - [\(url.path)]")
        hexReader = try? HexReader(url: url)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            sample = try handle.read(upToCount: ListerContent.textLimit + 1) ?? Data()
            truncated = sample.count > ListerContent.textLimit
            if truncated { sample = sample.prefix(ListerContent.textLimit) }
        } catch {
            sample = Data()
            truncated = false
            show(mode: .text)
            textView.string = "Cannot read \(url.lastPathComponent):\n\(error.localizedDescription)"
            updateStatus()
            return
        }
        show(mode: ListerContent.defaultMode(for: url, sample: sample))
    }

    public func show(mode new: ListerMode) {
        mode = new
        modeControl.selectedSegment = new.rawValue - 1
        closePreview()
        container.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        switch new {
        case .text:
            let (text, used) = ListerContent.text(sample, encoding: encoding, cut: truncated)
            shownEncoding = used
            textView.string = text
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            applyWrap()
            content = textScroll
        case .binary:
            textView.string = ListerContent.binaryText(sample)
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            setWrap(false, update: false)
            content = textScroll
        case .hex:
            hexTable.reloadData()
            content = hexScroll
        case .preview:
            let view = QLPreviewView(frame: container.bounds, style: .normal)!
            view.autostarts = true
            view.previewItem = url as NSURL
            preview = view
            content = view
        }
        encodingPopup.isEnabled = new == .text
        wrapBox.isEnabled = new == .text
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        updateStatus()
        focusContent()
    }

    private func focusContent() {
        switch mode {
        case .text, .binary: window?.makeFirstResponder(textView)
        case .hex: window?.makeFirstResponder(hexTable)
        case .preview: window?.makeFirstResponder(preview)
        }
    }

    private func updateStatus() {
        let size = hexReader?.size ?? Int64(sample.count)
        let modeText = mode == .text ? "\(mode.title) · \(shownEncoding.title)" : mode.title
        statusLabel.stringValue = statusParts(size: size, modeText: modeText).joined(separator: "   ·   ")
    }

    private func statusParts(size: Int64, modeText: String) -> [String] {
        var parts = [url.lastPathComponent, "\(EntryFormatter.shared.grouped(size)) bytes", modeText]
        if truncated && (mode == .text || mode == .binary) {
            parts.append("first \(EntryFormatter.shared.compact(Int64(ListerContent.textLimit))) shown (Hex shows all)")
        }
        if files.count > 1 { parts.append("file \(index + 1) of \(files.count)  (n / p)") }
        return parts
    }

    @objc private func modeClicked() {
        show(mode: ListerMode(rawValue: modeControl.selectedSegment + 1) ?? .text)
    }

    @objc private func encodingChosen() {
        encoding = ListerEncoding.allCases[max(0, encodingPopup.indexOfSelectedItem)]
        if mode == .text { show(mode: .text) }
    }

    @objc private func toggleWrap() {
        setWrap(wrapBox.state == .on, update: true)
    }

    public func setWrap(_ on: Bool, update: Bool = true) {
        wrap = on
        wrapBox.state = on ? .on : .off
        if update { applyWrap() } else { applyWrap(on: false) }
    }

    private func applyWrap(on: Bool? = nil) {
        let wrapping = on ?? wrap
        let container = textView.textContainer!
        if wrapping {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: textScroll.contentSize.width, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = false
            textView.frame.size.width = textScroll.contentSize.width
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }

    /// n / p: the next or previous file of the panel; the mode is chosen again for it.
    public func step(_ delta: Int) {
        let next = index + delta
        guard files.indices.contains(next) else { return NSSound.beep() }
        index = next
        load()
        onNavigate?(url)
    }

    // MARK: Keys

    /// Handles Lister's single-key commands; returns false for keys it does not use.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        if handleSpecialKey(event) { return true }
        guard let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if let targetMode = Self.modeForKey(ch) { show(mode: targetMode); return true }
        return handleLetterKey(ch)
    }

    private func handleSpecialKey(_ event: NSEvent) -> Bool {
        if event.keyCode == KeyCode.escape { window?.performClose(nil); return true }
        if event.keyCode == KeyCode.f7 { showFind(); return true }
        if event.characters == "G" { scrollToBottom(); return true }
        return false
    }

    private static func modeForKey(_ ch: String) -> ListerMode? {
        guard let raw = Int(ch), (1...4).contains(raw) else { return nil }
        return ListerMode(rawValue: raw)
    }

    private func handleLetterKey(_ ch: String) -> Bool {
        let handlers: [String: () -> Void] = [
            "n": { self.step(1) },
            "p": { self.step(-1) },
            "w": { if self.mode == .text { self.setWrap(!self.wrap) } },
            "q": { self.window?.performClose(nil) },
            "7": { self.showFind() },
            "d": { self.scrollHalfPage(down: true) },
            "u": { self.scrollHalfPage(down: false) },
        ]
        guard let action = handlers[ch] else { return false }
        action()
        return true
    }

    private var activeScrollView: NSScrollView? {
        switch mode {
        case .text, .binary: return textScroll
        case .hex: return hexScroll
        case .preview: return nil
        }
    }

    private func scrollHalfPage(down: Bool) {
        scrollActiveView { currentY, maxY, height in
            let half = height / 2
            return down ? min(maxY, currentY + half) : max(0, currentY - half)
        }
    }

    private func scrollToBottom() {
        scrollActiveView { _, maxY, _ in maxY }
    }

    private func scrollActiveView(_ targetY: (CGFloat, CGFloat, CGFloat) -> CGFloat) {
        guard let scroll = activeScrollView else { return }
        let clip = scroll.contentView
        let docHeight = scroll.documentView?.bounds.height ?? 0
        let maxY = max(0, docHeight - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = targetY(origin.y, maxY, clip.bounds.height)
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func showFind() {
        if mode == .hex || mode == .preview { show(mode: .text) }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performFindPanelAction(item)
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            // Typing in the find bar is text, not commands.
            if let responder = self.window?.firstResponder as? NSTextView, responder !== self.textView { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func closePreview() {
        guard let p = preview else { return }
        if let responder = window?.firstResponder as? NSView, responder === p || responder.isDescendant(of: p) {
            window?.makeFirstResponder(nil)
        }
        p.previewItem = nil
        p.close()
        p.removeFromSuperview()
        preview = nil
    }

    public func windowWillClose(_ notification: Notification) {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        closePreview()
        onClose?(self)
    }

    // MARK: Hex table

    public func numberOfRows(in tableView: NSTableView) -> Int { hexReader?.lineCount ?? 0 }

    public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("hexline")
        let label = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let l = NSTextField(labelWithString: "")
            l.identifier = id
            l.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            return l
        }()
        label.stringValue = hexReader?.line(row) ?? ""
        return label
    }
}
