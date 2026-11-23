import AppKit

/// One file panel in Total Commander's layout, top to bottom:
///   drive bar   "[Macintosh HD]  76,5 G of 117,1 G free"        ~  \  ..
///   path bar    "/Users/me/*.*"   (highlighted when the panel is active)
///   headers     ↑Name | Ext | Size | Date | Attr   (click to sort)
///   rows        icon + name, ext, size, date, attributes; cursor bar
///   status      "0 b / 88,4 k in 0 / 11 files, 0 / 2 dir(s)"
/// It does not take keyboard focus; `CommanderView` routes keys to the active panel's model.
public final class PanelView: NSView {
    public let model: PanelModel
    public var theme: Theme = .standard {
        didSet { if theme != oldValue { palette = Palette(theme); needsDisplay = true } }
    }
    public var display: DisplayOptions = .standard {
        didSet { if display != oldValue { needsDisplay = true } }
    }
    public var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    /// Off for the Options preview, which has no real volume.
    public var showsVolumeInfo = true

    /// Called on any click inside the panel, so the container can move focus here.
    public var onActivate: (() -> Void)?
    /// Called on a double click on a row (the cursor is already on it).
    public var onOpen: (() -> Void)?
    /// Called on a click on the drive name, to open the location menu (like ⌥1 / ⌥2).
    public var onLocationMenu: (() -> Void)?
    /// Folders whose size is being worked out; they show "…" in the Size column meanwhile.
    public var pendingSizes: Set<String> = [] { didSet { needsDisplay = true } }

    /// Set while the panel shows an FTP server: drive bar text, address for the path bar, and
    /// whether the connection is unencrypted (shown in red).
    public var remote: (status: String, address: String, insecure: Bool)? { didSet { needsDisplay = true } }
    /// "Connecting…" / "Reading /path…" while a remote listing loads (shown in the status line).
    public var busyText: String? { didSet { needsDisplay = true } }
    /// Navigation from the ~ \ .. buttons, routed through the commander (so it works for FTP too).
    public var onNavigate: ((CommandAction) -> Void)?

    /// True while the quick search box covers the status line (the status text is not drawn then).
    public var isStatusCovered = false { didSet { needsDisplay = true } }

    /// The status line area, where the quick search box appears.
    public var statusRect: NSRect { layoutInfo.status }

    /// Where the location menu opens: just under the drive bar.
    public var menuAnchor: NSPoint { NSPoint(x: 2, y: barHeight) }

    private var palette = Palette(.standard)
    private let formatter = EntryFormatter.shared
    private var scrollRemainder: CGFloat = 0
    private var volumeCache: (directory: URL, text: String, icon: NSImage)?

    private let barHeight: CGFloat = 22
    private let headerHeight: CGFloat = 20
    private let rowHeight: CGFloat = 19
    private let iconSize: CGFloat = 16

    public init(model: PanelModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        model.ensureCursorVisible(visibleRows: visibleRows)
    }

    // MARK: Layout

    struct Column {
        let field: SortColumn?   // nil for Attr, which does not sort
        let title: String
        var x: CGFloat
        var width: CGFloat
        let alignment: NSTextAlignment
    }

    struct Layout {
        let driveBar: NSRect
        let homeButton: NSRect
        let rootButton: NSRect
        let upButton: NSRect
        let pathBar: NSRect
        let listFrame: NSRect   // white area with border, header included
        let header: NSRect
        let rows: NSRect
        let status: NSRect
        let columns: [Column]
    }

    var layoutInfo: Layout {
        let b = bounds
        let driveBar = NSRect(x: 0, y: 0, width: b.width, height: barHeight)
        let upButton = NSRect(x: b.width - 24, y: 2, width: 22, height: barHeight - 4)
        let rootButton = upButton.offsetBy(dx: -24, dy: 0)
        let homeButton = rootButton.offsetBy(dx: -24, dy: 0)
        let pathBar = NSRect(x: 0, y: driveBar.maxY, width: b.width, height: barHeight - 2)
        let status = NSRect(x: 0, y: b.height - barHeight, width: b.width, height: barHeight)
        let listFrame = NSRect(x: 0, y: pathBar.maxY + 2, width: b.width,
                               height: max(0, status.minY - pathBar.maxY - 2))
        let inner = listFrame.insetBy(dx: 1, dy: 1)
        let header = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: headerHeight)
        let rows = NSRect(x: inner.minX, y: header.maxY, width: inner.width,
                          height: max(0, inner.maxY - header.maxY))
        return Layout(driveBar: driveBar, homeButton: homeButton, rootButton: rootButton, upButton: upButton, pathBar: pathBar,
                      listFrame: listFrame, header: header, rows: rows, status: status,
                      columns: columns(x: inner.minX, width: inner.width))
    }

    private static func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    private static let fixedColumns: [(SortColumn?, String, CGFloat, NSTextAlignment)] = {
        let pad: CGFloat = 12
        return [
            (.ext, "Ext", textWidth("jpeg", PanelFont.regular) + pad, .left),
            (.size, "Size", textWidth("0.000.000.000", PanelFont.digits) + pad, .right),
            (.date, "Date", textWidth("00.00.00 00:00", PanelFont.digits) + pad, .left),
            (nil, "Attr", textWidth("-0000", PanelFont.digits) + pad, .left),
        ]
    }()

    /// Width at which the Date column has room for the time as well.
    static let fullDateWidth = textWidth("00.00.00 00:00", PanelFont.digits) + 12
    /// The Date column never gets narrower than a date without the time.
    static let shortDateWidth = textWidth("00.00.00", PanelFont.digits) + 12
    /// Size never gets narrower than its short form ("999,9 M"), which it switches to when bytes don't fit.
    static let minimumSizeWidth = textWidth("999,9 M", PanelFont.digits) + 12

    /// Widths of Name, Ext, Size, Date and Attr for a list `total` points wide. All five are always shown.
    /// Name wants about a third of the panel; to make room, Size narrows first (down to its short form),
    /// then Date drops the time. Date and Attr are never cut; Name takes what is left.
    static func columnWidths(total: CGFloat) -> (name: CGFloat, ext: CGFloat, size: CGFloat, date: CGFloat, attr: CGFloat) {
        let natural = Dictionary(uniqueKeysWithValues: fixedColumns.map { ($0.1, $0.2) })
        let ext = natural["Ext"]!, attr = natural["Attr"]!
        var size = natural["Size"]!
        var date = fullDateWidth
        let nameWanted = max(90, floor(total * 0.34))
        var shortfall = nameWanted - (total - ext - size - date - attr)
        if shortfall > 0 {
            let give = min(shortfall, size - minimumSizeWidth)
            size -= give
            shortfall -= give
        }
        if shortfall > 0 {
            date = shortDateWidth
        }
        let name = max(0, total - ext - size - date - attr)
        return (name, ext, size, date, attr)
    }

    private func columns(x: CGFloat, width: CGFloat) -> [Column] {
        let w = Self.columnWidths(total: width)
        let widths: [String: CGFloat] = ["Ext": w.ext, "Size": w.size, "Date": w.date, "Attr": w.attr]
        var result = [Column(field: .name, title: "Name", x: x, width: w.name, alignment: .left)]
        var cursorX = x + w.name
        for (field, title, _, align) in Self.fixedColumns {
            let width = floor(widths[title]!)
            result.append(Column(field: field, title: title, x: cursorX, width: width, alignment: align))
            cursorX += width
        }
        return result
    }

    public var visibleRows: Int {
        max(1, Int(layoutInfo.rows.height / rowHeight))
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let l = layoutInfo
        palette.chrome.setFill()
        bounds.fill()
        drawDriveBar(l)
        drawPathBar(l)
        drawList(l)
        drawStatus(l)
    }

    private func drawDriveBar(_ l: Layout) {
        var x: CGFloat = 4
        if let remote = remote {
            let icon = NSImage(named: NSImage.networkName) ?? NSImage()
            icon.draw(in: NSRect(x: x, y: l.driveBar.midY - iconSize / 2, width: iconSize, height: iconSize),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconSize + 6
            let textRect = NSRect(x: x, y: l.driveBar.minY, width: max(0, l.homeButton.minX - x - 4), height: barHeight)
            drawText(remote.status, in: textRect, color: remote.insecure ? .systemRed : palette.chromeText, font: PanelFont.bold)
        } else if showsVolumeInfo {
            let volume = volumeDetails()
            volume.icon.draw(in: NSRect(x: x, y: l.driveBar.midY - iconSize / 2, width: iconSize, height: iconSize),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconSize + 6
            let textRect = NSRect(x: x, y: l.driveBar.minY, width: max(0, l.homeButton.minX - x - 4), height: barHeight)
            drawText(volume.text, in: textRect, color: palette.chromeText, font: PanelFont.regular)
        }
        for (rect, title) in [(l.homeButton, "~"), (l.rootButton, "\\"), (l.upButton, "..")] {
            drawText(title, in: rect, color: palette.chromeText, font: PanelFont.regular, alignment: .center)
        }
    }

    private func drawPathBar(_ l: Layout) {
        let bg = isActive ? palette.activePathBackground : palette.inactivePathBackground
        let fg = isActive ? palette.activePathText : palette.inactivePathText
        bg.setFill()
        l.pathBar.fill()
        var header = model.virtualTitle.map { "[\($0)]   (.. returns to \(model.directory.path))" }
            ?? EntryFormatter.header(for: model.directory)
        if let remote = remote { header = remote.address + EntryFormatter.header(for: model.directory) }
        if let filter = model.quickFilter { header += "    [filter: \(filter)]" }
        drawText(header, in: l.pathBar.insetBy(dx: 6, dy: 0),
                 color: fg, font: PanelFont.regular, truncation: .byTruncatingHead)
    }

    private func drawList(_ l: Layout) {
        // Sunken frame in the window's own grey: shadow on top/left, light on bottom/right.
        palette.chromeLight.setFill()
        l.listFrame.fill()
        palette.chromeShadow.setFill()
        NSRect(x: l.listFrame.minX, y: l.listFrame.minY, width: l.listFrame.width - 1, height: l.listFrame.height - 1).fill()
        palette.background.setFill()
        l.listFrame.insetBy(dx: 1, dy: 1).fill()

        // Column headers like Total Commander's (the Windows header control): a light gradient, grey
        // separators with a highlight next to them and a grey bottom edge — bevel shades of the window
        // colour, never the panel line colour. The sort column carries an arrow.
        palette.headerGradient.draw(in: l.header, angle: 90)
        palette.chromeShadow.setFill()
        NSRect(x: l.header.minX, y: l.header.maxY - 1, width: l.header.width, height: 1).fill()
        for (i, col) in l.columns.enumerated() {
            if i < l.columns.count - 1 {
                palette.chromeShadow.setFill()
                NSRect(x: col.x + col.width - 1, y: l.header.minY + 2, width: 1, height: headerHeight - 4).fill()
                palette.chromeLight.setFill()
                NSRect(x: col.x + col.width, y: l.header.minY + 2, width: 1, height: headerHeight - 4).fill()
            }
            var title = col.title
            if let field = col.field, field == model.sortOrder.column {
                title = (model.sortOrder.ascending ? "↑" : "↓") + title
            }
            let cell = NSRect(x: col.x + 5, y: l.header.minY, width: col.width - 10, height: headerHeight - 1)
            drawText(title, in: cell, color: palette.headerText, font: PanelFont.regular)
        }

        let entries = model.entries
        let first = model.scrollTop
        let last = min(entries.count, first + visibleRows)
        guard first < last else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: l.rows).addClip()
        for index in first..<last {
            let entry = entries[index]
            let y = l.rows.minY + CGFloat(index - first) * rowHeight
            let rowRect = NSRect(x: l.rows.minX, y: y, width: l.rows.width, height: rowHeight)
            let isCursor = index == model.cursor
            let onBar = isCursor && isActive

            if onBar {
                palette.cursorBackground.setFill()
                rowRect.fill()
            } else if index % 2 == 1 {
                palette.background2.setFill()
                rowRect.fill()
            }

            let marked = model.isMarked(entry)
            let markedOnBar = marked && onBar
            let textFont = markedOnBar ? PanelFont.bold : PanelFont.regular
            let digitFont = markedOnBar ? PanelFont.boldDigits : PanelFont.digits
            let color: NSColor
            if marked {
                color = onBar ? palette.markOnCursorText : palette.markText
            } else if onBar {
                color = palette.cursorText
            } else {
                color = entry.kind == .file ? palette.text : palette.directoryText
            }
            for col in l.columns {
                switch col.field {
                case .name?:
                    let icon = IconProvider.shared.icon(for: entry, tint: color)
                    icon.draw(in: NSRect(x: col.x + 3, y: y + (rowHeight - iconSize) / 2, width: iconSize, height: iconSize),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    let textX = col.x + 3 + iconSize + 4
                    drawText(formatter.name(entry, folderBrackets: display.showFolderBrackets), in: NSRect(x: textX, y: y, width: col.x + col.width - textX - 4, height: rowHeight),
                             color: color, font: markedOnBar ? PanelFont.bold : PanelFont.regular)
                case .ext?:
                    drawCell(EntryFormatter.visible(entry.displayExtension), col, y, color, textFont)
                case .size?:
                    var sizeText = pendingSizes.contains(entry.name) && entry.kind == .directory
                        ? "…" : formatter.size(entry, folderSize: model.folderSize(for: entry))
                    // Exact bytes when they fit, otherwise the short form ("5,3 G") rather than a cut-off number.
                    let bytes = entry.kind == .file ? entry.size : model.folderSize(for: entry)
                    if let bytes = bytes, Self.textWidth(sizeText, digitFont) > col.width - 10 {
                        sizeText = formatter.compact(bytes)
                    }
                    drawCell(sizeText, col, y, color, digitFont)
                case .date?:
                    // Too narrow for the time: show just the date rather than a cut-off time.
                    drawCell(formatter.date(entry, includeTime: col.width >= Self.fullDateWidth), col, y, color, digitFont)
                case .unsorted?:
                    break   // not a column
                case nil:
                    drawCell(formatter.attributes(entry), col, y, color, digitFont)
                }
            }

            if isCursor && !isActive {
                // Inactive panel: the cursor stays visible as a dotted frame in the cursor colour.
                palette.cursorBackground.setStroke()
                let path = NSBezierPath(rect: rowRect.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.setLineDash([1, 2], count: 2, phase: 0)
                path.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCell(_ text: String, _ col: Column, _ y: CGFloat, _ color: NSColor, _ font: NSFont) {
        drawText(text, in: NSRect(x: col.x + 5, y: y, width: col.width - 10, height: rowHeight),
                 color: color, font: font, alignment: col.alignment)
    }

    private func drawStatus(_ l: Layout) {
        guard !isStatusCovered else { return }
        var text = busyText ?? model.errorMessage ?? cachedSummary()
        if busyText == nil, model.errorMessage == nil, let filter = model.showFilter.label { text = "[Show: \(filter)]  " + text }
        drawText(text, in: l.status.insetBy(dx: 4, dy: 0), color: palette.chromeText, font: PanelFont.regular)
    }

    /// The totals line is O(n) over all entries: it is rebuilt only when the panel's revision changes,
    /// not on every redraw (cursor moves redraw constantly).
    private var summaryCache: (model: ObjectIdentifier, revision: Int, text: String)?

    private func cachedSummary() -> String {
        let id = ObjectIdentifier(model)
        if let c = summaryCache, c.model == id, c.revision == model.revision { return c.text }
        let text = formatter.summary(model.realEntries, selected: model.selectionTotals)
        summaryCache = (id, model.revision, text)
        return text
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, font: NSFont,
                          alignment: NSTextAlignment = .left, truncation: NSLineBreakMode = .byTruncatingTail) {
        guard rect.width > 0, !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = truncation
        let lineHeight = ceil(font.ascender - font.descender)
        let textRect = NSRect(x: rect.minX, y: rect.minY + floor((rect.height - lineHeight) / 2),
                              width: rect.width, height: lineHeight)
        (text as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    // MARK: Volume

    /// Forget the cached free space so the next redraw reads it again (e.g. on window refocus).
    public func invalidateVolumeInfo() {
        volumeCache = nil
    }

    /// Read once per directory change, not on every redraw.
    private func volumeDetails() -> (text: String, icon: NSImage) {
        if let cache = volumeCache, cache.directory == model.directory { return (cache.text, cache.icon) }
        let text = VolumeInfo.read(for: model.directory).map(formatter.volume) ?? ""
        let root = (try? model.directory.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? "/"
        let icon = NSWorkspace.shared.icon(forFile: root)
        volumeCache = (model.directory, text, icon)
        return (text, icon)
    }

    // MARK: Mouse

    private func row(at point: NSPoint) -> Int? {
        let rows = layoutInfo.rows
        guard rows.contains(point) else { return nil }
        let index = model.scrollTop + Int((point.y - rows.minY) / rowHeight)
        return index < model.entries.count ? index : nil
    }

    public override func mouseDown(with event: NSEvent) {
        // Control-click is the Mac's right click: select like a right click instead of a menu.
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        onActivate?()
        let point = convert(event.locationInWindow, from: nil)
        let l = layoutInfo
        defer { needsDisplay = true }

        if l.homeButton.contains(point) {
            if let nav = onNavigate { nav(.goHome) } else if case .failed = model.goHome(visibleRows: visibleRows) { NSSound.beep() }
            return
        }
        if l.rootButton.contains(point) {
            if let nav = onNavigate { nav(.goRoot) } else { model.goToRoot(visibleRows: visibleRows) }
            return
        }
        if l.upButton.contains(point) {
            if let nav = onNavigate { nav(.parentFolder) } else { model.goUp(visibleRows: visibleRows) }
            return
        }
        if l.driveBar.contains(point) {
            onLocationMenu?()
            return
        }
        if l.header.contains(point) {
            if let col = l.columns.first(where: { point.x >= $0.x && point.x < $0.x + $0.width }), let field = col.field {
                model.sort(by: field, visibleRows: visibleRows)
            }
            return
        }
        guard let index = row(at: point) else { return }
        if event.modifierFlags.contains(.shift) {
            model.markRange(toRow: index, visibleRows: visibleRows)
            return
        }
        model.setCursor(index, visibleRows: visibleRows)
        if event.clickCount == 2 {
            onOpen?()
        }
    }

    // MARK: Right-click selection

    /// true = the current right-drag marks rows, false = it unmarks them, nil = not decided yet.
    private var dragMarks: Bool?
    private var lastDragRow: Int?

    public override func rightMouseDown(with event: NSEvent) {
        onActivate?()
        let point = convert(event.locationInWindow, from: nil)
        guard let index = row(at: point) else { return }
        beginRightSelection(atRow: index)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        dragSelection(to: convert(event.locationInWindow, from: nil))
    }

    public override func mouseDragged(with event: NSEvent) {
        // Control-drag continues a control-click selection.
        if lastDragRow != nil { dragSelection(to: convert(event.locationInWindow, from: nil)) }
    }

    public override func rightMouseUp(with event: NSEvent) { endRightSelection() }

    public override func mouseUp(with event: NSEvent) {
        if lastDragRow != nil { endRightSelection() }
    }

    /// Right click on a row: toggle its mark; the result decides what a following drag does.
    func beginRightSelection(atRow index: Int) {
        dragMarks = nil
        lastDragRow = index
        model.setCursor(index, visibleRows: visibleRows)
        applyDragMark(to: index)
        needsDisplay = true
    }

    /// Drag to a row: every row between the last one and this one gets the same treatment.
    func continueRightSelection(toRow index: Int) {
        guard let last = lastDragRow, index != last else { return }
        let step = index > last ? 1 : -1
        var i = last + step
        while true {
            applyDragMark(to: i)
            if i == index { break }
            i += step
        }
        lastDragRow = index
        model.setCursor(index, visibleRows: visibleRows)
        needsDisplay = true
    }

    func endRightSelection() {
        dragMarks = nil
        lastDragRow = nil
    }

    private func applyDragMark(to index: Int) {
        guard model.entries.indices.contains(index), model.entries[index].kind != .parent else { return }
        if dragMarks == nil {
            dragMarks = !model.isMarked(model.entries[index])
        }
        model.setMark(dragMarks!, at: index)
    }

    /// Maps a drag point to a row; beyond the top or bottom of the list it scrolls one row.
    private func dragSelection(to point: NSPoint) {
        guard lastDragRow != nil, !model.entries.isEmpty else { return }
        let rows = layoutInfo.rows
        let index: Int
        if point.y < rows.minY {
            model.scroll(by: -1, visibleRows: visibleRows)
            index = model.scrollTop
        } else if point.y >= rows.maxY {
            model.scroll(by: 1, visibleRows: visibleRows)
            index = min(model.entries.count - 1, model.scrollTop + visibleRows - 1)
        } else {
            index = min(model.entries.count - 1, model.scrollTop + Int((point.y - rows.minY) / rowHeight))
        }
        continueRightSelection(toRow: index)
    }

    public override func scrollWheel(with event: NSEvent) {
        let rows: Int
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += event.scrollingDeltaY / rowHeight
            rows = Int(scrollRemainder)
            scrollRemainder -= CGFloat(rows)
        } else {
            rows = event.scrollingDeltaY > 0 ? 3 : (event.scrollingDeltaY < 0 ? -3 : 0)
        }
        guard rows != 0 else { return }
        model.scroll(by: -rows, visibleRows: visibleRows)
        needsDisplay = true
    }
}
