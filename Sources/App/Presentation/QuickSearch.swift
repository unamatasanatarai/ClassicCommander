import AppKit

/// Quick Search and Quick Filter: a small box over the active panel's status line.
///   Search mode: the cursor jumps to the first name starting with the typed text.
///   Filter mode (⌃S): only matching entries stay visible.
/// In the box: ↓ or ⌃↩ next match, ↑ previous, ↩ open (search) or keep filter (filter),
/// Esc close (and clear the filter), ⌃S switch mode. A character that leaves no match is refused.
public final class QuickSearchController: NSObject, NSTextFieldDelegate {
    public enum Mode { case search, filter }

    weak var commander: CommanderView?
    public let field = NSTextField()
    public private(set) var mode: Mode = .search
    public private(set) var isOpen = false
    /// The last text typed, for "Reopen last quick search" (⌃⇧S).
    public private(set) var lastText = ""
    private weak var panel: PanelView?
    private var acceptedText = ""
    private var monitor: Any?

    init(commander: CommanderView) {
        self.commander = commander
        super.init()
        field.delegate = self
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.bezelStyle = .squareBezel
        field.isBezeled = true
        // Opaque, so the status line underneath does not show through.
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .textColor
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    /// Opens the box on `panel`, optionally starting with some text (the letter that started it).
    public func open(in panel: PanelView, mode: Mode, text: String = "") {
        if isOpen { close(clearFilter: false) }
        self.panel = panel
        self.mode = mode
        isOpen = true
        acceptedText = ""
        field.stringValue = ""
        updatePlaceholder()
        panel.isStatusCovered = true
        panel.addSubview(field)
        field.frame = panel.statusRect.insetBy(dx: 1, dy: 0)
        panel.window?.makeFirstResponder(field)
        installMonitor()
        if !text.isEmpty {
            field.stringValue = text
            apply(text)
        }
        moveCaretToEnd()
    }

    /// Closes the box; in filter mode the filter is kept unless `clearFilter`.
    public func close(clearFilter: Bool) {
        guard isOpen else { return }
        isOpen = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if !acceptedText.isEmpty { lastText = acceptedText }
        if clearFilter, let panel = panel {
            panel.model.setQuickFilter(nil, visibleRows: panel.visibleRows)
            panel.needsDisplay = true
        }
        field.removeFromSuperview()
        panel?.isStatusCovered = false
        if let commander = commander { commander.window?.makeFirstResponder(commander) }
    }

    /// Types into the box programmatically (used by tests and by `open`).
    public func type(_ text: String) {
        field.stringValue = acceptedText + text
        apply(field.stringValue)
    }

    public func switchMode() {
        guard let panel = panel else { return }
        if mode == .filter {
            mode = .search
            panel.model.setQuickFilter(nil, visibleRows: panel.visibleRows)
        } else {
            mode = .filter
            if !acceptedText.isEmpty { panel.model.setQuickFilter(acceptedText, visibleRows: panel.visibleRows) }
        }
        updatePlaceholder()
        panel.needsDisplay = true
    }

    /// Next (or previous) match in search mode.
    public func jump(forward: Bool) {
        guard let panel = panel, !acceptedText.isEmpty else { return }
        let model = panel.model
        if let i = model.quickSearchIndex(acceptedText, from: model.cursor, forward: forward, includingStart: false) {
            model.setCursor(i, visibleRows: panel.visibleRows)
            panel.needsDisplay = true
        }
    }

    /// Takes the new text if anything matches it; otherwise beeps and keeps the old text.
    private func apply(_ text: String) {
        guard let panel = panel else { return }
        if text.isEmpty { clearFilter(in: panel); return }
        guard applyNonEmpty(text, to: panel) else { return reject() }
        acceptedText = text
        panel.needsDisplay = true
    }

    private func clearFilter(in panel: PanelView) {
        acceptedText = ""
        if mode == .filter { panel.model.setQuickFilter(nil, visibleRows: panel.visibleRows) }
        panel.needsDisplay = true
    }

    private func applyNonEmpty(_ text: String, to panel: PanelView) -> Bool {
        let model = panel.model
        switch mode {
        case .search:
            guard let i = model.quickSearchIndex(text, from: model.cursor) else { return false }
            model.setCursor(i, visibleRows: panel.visibleRows)
        case .filter:
            guard model.quickFilterCount(text) > 0 else { return false }
            model.setQuickFilter(text, visibleRows: panel.visibleRows)
        }
        return true
    }

    private func reject() {
        NSSound.beep()
        field.stringValue = acceptedText
        moveCaretToEnd()
    }

    private func moveCaretToEnd() {
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    private func updatePlaceholder() {
        field.placeholderString = mode == .search
            ? "Quick search  (↓ next · ↩ open · ⌃S filter · Esc)"
            : "Quick filter  (↩ keep filter · ⌃S search · Esc clears)"
    }

    /// ⌃S inside the box switches between search and filter.
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isOpen, self.handleMonitorKey(event) else { return event }
            return nil
        }
    }

    private func handleMonitorKey(_ event: NSEvent) -> Bool {
        let combo = KeyCombo(event)
        if combo == KeyCombo(KeyCode.s, .control) { switchMode(); return true }
        if combo == KeyCombo(KeyCode.returnKey, .control) { jump(forward: true); return true }
        return false
    }

    // MARK: NSTextFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        apply(field.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close(clearFilter: mode == .filter)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let opensEntry = mode == .search
            close(clearFilter: false)
            if opensEntry { commander?.perform(.open) }
            return true
        }
        return handleNavigationSelector(selector)
    }

    private func handleNavigationSelector(_ selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.insertLineBreak(_:)) {
            jump(forward: true); return true
        }
        if selector == #selector(NSResponder.moveUp(_:)) {
            jump(forward: false); return true
        }
        return false
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking elsewhere ends the search but keeps a filter, like pressing ↩ in filter mode.
        if isOpen { close(clearFilter: false) }
    }
}
