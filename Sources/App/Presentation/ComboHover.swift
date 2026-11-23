import AppKit

/// Combo box lists (the history under Search for / Search in, the Synchronize paths, …) highlight the
/// row under the mouse, like menus do. The highlight is drawn over the row; the field's text only
/// changes when a row is clicked.
final class ComboHover: NSResponder {
    private static var trackers: [ObjectIdentifier: ComboHover] = [:]
    private static var installed = false

    /// Starts watching every combo box in the app (once).
    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(self, selector: #selector(willPopUp(_:)),
                                               name: NSComboBox.willPopUpNotification, object: nil)
    }

    /// The list appears right after this notification, so it is looked up on the next turn.
    @objc static func willPopUp(_ note: Notification) {
        guard let combo = note.object as? NSComboBox else { return }
        DispatchQueue.main.async { attach(to: combo) }
    }

    /// Adds the hover highlight to the combo box's list (found by its data source, the combo's cell).
    @discardableResult
    static func attach(to combo: NSComboBox) -> ComboHover? {
        guard let cell = combo.cell else { return nil }
        let tables = NSApp.windows.compactMap(\.contentView).flatMap(tableViews)
        guard let table = tables.first(where: { $0.dataSource === cell }) else { return nil }
        if let existing = trackers[ObjectIdentifier(table)] {
            existing.highlight.isHidden = true   // the list is reused; nothing is under the mouse yet
            return existing
        }
        let tracker = ComboHover(table: table)
        trackers[ObjectIdentifier(table)] = tracker
        return tracker
    }

    static func tableViews(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tableViews)
    }

    let table: NSTableView
    let highlight = HighlightView()

    init(table: NSTableView) {
        self.table = table
        super.init()
        highlight.isHidden = true
        table.addSubview(highlight)
        table.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                             owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The row under a point of the table (-1 when none).
    func show(at point: NSPoint) {
        let row = table.row(at: point)
        highlight.isHidden = row < 0
        if row >= 0 { highlight.frame = table.rect(ofRow: row) }
    }

    override func mouseMoved(with event: NSEvent) { show(at: table.convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { highlight.isHidden = true }

    /// The highlight never takes clicks; they go to the row under it.
    final class HighlightView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            bounds.fill()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
