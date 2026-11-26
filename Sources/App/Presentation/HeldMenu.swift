import AppKit

/// A context menu that opens while the mouse button is still held (long right click) and stays open
/// when the button is released.
///
/// An `NSMenu` opened with a button down always runs in "press, drag, release" mode: the release
/// either picks the item under the mouse or closes the menu, so it can never stay open. This shows
/// the same `NSMenu` items (titles, images, separators, disabled items, submenus) in panels that
/// look like a system menu, with its own tracking loop:
/// - releasing a button over an item picks it; anywhere else nothing happens (the menu stays open);
/// - clicking outside the menu, Esc or switching to another app closes it;
/// - ↑ ↓ move, → / ← open / close a submenu, Return / Enter / Space pick, letters jump to items.
/// The chosen item's action is sent after the menu has closed, exactly as `NSMenu` does.
final class HeldMenu {
    /// One open menu: the root, or a submenu opened from the root (or from another submenu).
    final class Level {
        let menu: NSMenu
        let items: [NSMenuItem]
        let window: NSPanel
        let view: HeldMenuView
        var highlighted: Int? { didSet { if highlighted != oldValue { view.highlighted = highlighted } } }

        init(menu: NSMenu, appearance: NSAppearance?) {
            menu.update()   // validates the items (autoenablesItems), as NSMenu does before showing
            self.menu = menu
            items = menu.items.filter { !$0.isHidden }
            view = HeldMenuView(items: items)
            window = NSPanel(contentRect: NSRect(origin: .zero, size: view.frame.size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            window.level = .popUpMenu
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            let effect = NSVisualEffectView(frame: view.frame)
            effect.material = .menu
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 6
            effect.layer?.masksToBounds = true
            effect.addSubview(view)
            window.contentView = effect
        }

        /// The item row at a point of the screen (nil over padding, separators or outside).
        func row(atScreen point: NSPoint) -> Int? {
            guard window.frame.contains(point) else { return nil }
            let local = view.convert(window.convertPoint(fromScreen: point), from: nil)
            return view.row(at: local)
        }

        /// A row's rectangle on the screen.
        func screenRect(ofRow row: Int) -> NSRect {
            window.convertToScreen(view.convert(view.rect(ofRow: row), to: nil))
        }

        func selectable(_ row: Int) -> Bool {
            items.indices.contains(row) && !items[row].isSeparatorItem && items[row].isEnabled
        }
    }

    private(set) var levels: [Level] = []
    /// The item picked; its action is sent when the menu closes.
    private(set) var chosen: NSMenuItem?
    /// The menu is closing (an item was picked or it was dismissed).
    private(set) var done = false
    /// Tests: whether the app is still frontmost (the menu closes when it is not).
    var isActive: () -> Bool = { NSApp.isActive }
    private let appearance: NSAppearance?
    private var lastMouse: NSPoint?

    /// `point` is in screen coordinates: the menu's top-left corner (the mouse position).
    init(_ menu: NSMenu, at point: NSPoint, appearance: NSAppearance? = nil) {
        self.appearance = appearance
        let root = Level(menu: menu, appearance: appearance)
        levels = [root]
        lastMouse = point
        place(root, topLeft: point, besides: nil)
    }

    /// Shows the menu, tracks it until an item is picked or it is dismissed, then sends the action.
    func run() {
        for level in levels { level.window.orderFront(nil) }
        while !done {
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 1.0 / 60),
                                           inMode: .eventTracking, dequeue: true) {
                handle(event)
            } else {
                // Panels that are not key may get no mouse-moved events: follow the mouse anyway.
                let mouse = NSEvent.mouseLocation
                if mouse != lastMouse { hover(at: mouse) }
            }
            if !isActive() { done = true }
        }
        close()
        perform()
    }

    // MARK: Events

    func handle(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            hover(at: Self.screenLocation(of: event))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Inside: the item is picked on release. Outside: the click only closes the menu.
            let point = Self.screenLocation(of: event)
            if levels.contains(where: { $0.window.frame.contains(point) }) { hover(at: point) } else { done = true }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            release(at: Self.screenLocation(of: event))
        case .keyDown:
            key(event)
        case .appKitDefined where event.subtype == .applicationDeactivated:
            done = true
        case .keyUp, .flagsChanged, .scrollWheel, .cursorUpdate, .mouseEntered, .mouseExited:
            break
        default:
            NSApp.sendEvent(event)   // system and app-defined events keep working while the menu is open
        }
    }

    /// The mouse is over a point: highlight the row under it and open its submenu.
    func hover(at point: NSPoint) {
        lastMouse = point
        guard let depth = levels.lastIndex(where: { $0.window.frame.contains(point) }) else {
            // Outside every menu: the deepest menu loses its highlight (unless it leads to a submenu).
            if let last = levels.last, last.highlighted.map({ last.items[$0].submenu == nil }) ?? false {
                last.highlighted = nil
            }
            return
        }
        let level = levels[depth]
        let row = level.row(atScreen: point).flatMap { level.selectable($0) ? $0 : nil }
        if row == level.highlighted, depth + 1 < levels.count { return }   // still on the submenu's item
        closeLevels(after: depth)
        level.highlighted = row
        if let row = row, level.items[row].submenu != nil { openSubmenu(of: depth, row: row) }
    }

    /// A button released over the highlighted item (the mouse moved onto it or pressed on it) picks
    /// it; anywhere else the menu stays open. The release that ends the long click, with the mouse
    /// not moved, never picks: not even when the menu had to be moved under the mouse to fit.
    func release(at point: NSPoint) {
        guard let depth = levels.lastIndex(where: { $0.window.frame.contains(point) }),
              let row = levels[depth].row(atScreen: point), levels[depth].highlighted == row else { return }
        let item = levels[depth].items[row]
        if item.submenu == nil { choose(item) }
    }

    func key(_ event: NSEvent) {
        let depth = levels.count - 1
        let level = levels[depth]
        switch event.keyCode {
        case 53: done = true                                        // Esc
        case 125: level.highlighted = step(level, from: level.highlighted, by: 1)   // ↓
        case 126: level.highlighted = step(level, from: level.highlighted, by: -1)  // ↑
        case 124: enterSubmenu()                                    // →
        case 123: if depth > 0 { closeLevels(after: depth - 1) }    // ←
        case 36, 76, 49:                                            // Return, Enter, Space
            guard let row = level.highlighted else { return }
            if level.items[row].submenu != nil { enterSubmenu() } else { choose(level.items[row]) }
        default:
            typeSelect(event.charactersIgnoringModifiers ?? "", in: level)
        }
    }

    /// The next selectable row in a direction (from nothing: the first, or the last going up).
    func step(_ level: Level, from row: Int?, by delta: Int) -> Int? {
        let count = level.items.count
        var index = row ?? (delta > 0 ? -1 : count)
        repeat {
            index += delta
            if !level.items.indices.contains(index) { return row }
            if level.selectable(index) { return index }
        } while true
    }

    /// Opens the highlighted item's submenu (if it has one) and highlights its first item.
    func enterSubmenu() {
        let depth = levels.count - 1
        guard let row = levels[depth].highlighted, levels[depth].items[row].submenu != nil else { return }
        openSubmenu(of: depth, row: row)
        if let child = levels.last, depth + 1 < levels.count {
            child.highlighted = step(child, from: nil, by: 1)
        }
    }

    /// Letters jump to the next item whose title starts with them.
    func typeSelect(_ typed: String, in level: Level) {
        let prefix = typed.lowercased()
        guard !prefix.isEmpty, !level.items.isEmpty else { return }
        let start = (level.highlighted ?? -1) + 1
        let count = level.items.count
        for offset in 0..<count {
            let row = (start + offset) % count
            if level.selectable(row), level.items[row].title.lowercased().hasPrefix(prefix) {
                closeLevels(after: levels.count - 1)
                level.highlighted = row
                return
            }
        }
    }

    func choose(_ item: NSMenuItem) {
        chosen = item
        done = true
    }

    // MARK: Levels

    func openSubmenu(of depth: Int, row: Int) {
        guard let submenu = levels[depth].items[row].submenu else { return }
        closeLevels(after: depth)
        let child = Level(menu: submenu, appearance: appearance)
        levels.append(child)
        place(child, topLeft: .zero, besides: levels[depth].screenRect(ofRow: row))
        if !done { child.window.orderFront(nil) }
    }

    func closeLevels(after depth: Int) {
        while levels.count > depth + 1 { levels.removeLast().window.orderOut(nil) }
    }

    /// Puts a menu at `topLeft`, or (a submenu) beside the row it opens from, kept on the screen.
    func place(_ level: Level, topLeft: NSPoint, besides row: NSRect?) {
        let size = level.window.frame.size
        let anchor = row.map { NSPoint(x: $0.maxX, y: $0.maxY) } ?? topLeft
        let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5)
        let padding = HeldMenuView.padding
        var origin = row.map { NSPoint(x: $0.maxX + 5, y: $0.maxY + padding - size.height) }
            ?? NSPoint(x: topLeft.x, y: topLeft.y - size.height)
        if origin.x + size.width > visible.maxX {
            // No room on the right: a submenu opens to the left of its menu, a menu left of the mouse.
            origin.x = row.map { $0.minX - 5 - size.width } ?? topLeft.x - size.width
        }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        level.window.setFrameOrigin(origin)
    }

    func close() {
        closeLevels(after: -1)
    }

    /// Sends the chosen item's action (through its menu, so a nil target reaches the responder chain).
    func perform() {
        guard let item = chosen, let menu = item.menu else { return }
        let index = menu.index(of: item)
        if index >= 0 { menu.performActionForItem(at: index) }
    }

    static func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}

/// Draws a menu's items like a system menu.
final class HeldMenuView: NSView {
    static let rowHeight: CGFloat = 22, separatorHeight: CGFloat = 11, padding: CGFloat = 5
    static let font = NSFont.menuFont(ofSize: 0)

    let items: [NSMenuItem]
    var highlighted: Int? { didSet { needsDisplay = true } }
    private let rows: [NSRect]
    private let textX: CGFloat

    init(items: [NSMenuItem]) {
        self.items = items
        let hasImages = items.contains { $0.image != nil }
        textX = hasImages ? 42 : 20
        let textWidth = items.map { ($0.title as NSString).size(withAttributes: [.font: Self.font]).width }.max() ?? 0
        let width = max(160, ceil(textX + textWidth + 36))
        var y = Self.padding
        var rows: [NSRect] = []
        for item in items {
            let height = item.isSeparatorItem ? Self.separatorHeight : Self.rowHeight
            rows.append(NSRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: y + Self.padding))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func rect(ofRow row: Int) -> NSRect { rows[row] }

    /// The item row at a point of this view (nil over padding and separators).
    func row(at point: NSPoint) -> Int? {
        guard let row = rows.firstIndex(where: { $0.contains(point) }), !items[row].isSeparatorItem else { return nil }
        return row
    }

    override func draw(_ dirtyRect: NSRect) {
        for (row, item) in items.enumerated() {
            let rect = rows[row]
            if item.isSeparatorItem {
                NSColor.separatorColor.setFill()
                NSRect(x: 10, y: rect.midY - 0.5, width: rect.width - 20, height: 1).fill()
                continue
            }
            let lit = row == highlighted && item.isEnabled
            if lit {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
            }
            let color: NSColor = !item.isEnabled ? .disabledControlTextColor : lit ? .selectedMenuItemTextColor : .labelColor
            if let image = item.image {
                image.draw(in: NSRect(x: 20, y: rect.midY - 8, width: 16, height: 16), from: .zero,
                           operation: .sourceOver, fraction: item.isEnabled ? 1 : 0.5, respectFlipped: true, hints: nil)
            }
            let title = item.title as NSString
            let size = title.size(withAttributes: [.font: Self.font])
            title.draw(at: NSPoint(x: textX, y: rect.midY - size.height / 2),
                       withAttributes: [.font: Self.font, .foregroundColor: color])
            if item.submenu != nil {
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: rect.maxX - 18, y: rect.midY - 4))
                arrow.line(to: NSPoint(x: rect.maxX - 14, y: rect.midY))
                arrow.line(to: NSPoint(x: rect.maxX - 18, y: rect.midY + 4))
                arrow.lineWidth = 1.5
                arrow.lineCapStyle = .round
                arrow.lineJoinStyle = .round
                color.setStroke()
                arrow.stroke()
            }
        }
    }
}
