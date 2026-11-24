import AppKit

/// The tabs above a panel: click switches, middle-click closes, double-click on the empty part
/// opens a new tab. Drawn in classic tab style with an open bottom and a bright active tab.
final class TabBarView: NSView {
    static let height: CGFloat = 22

    var tabs = PanelTabs(folder: URL(fileURLWithPath: "/")) {
        didSet {
            cachedTabRects = nil
            hoveredCloseTab = nil
            ensureActiveTabVisible()
            needsDisplay = true
        }
    }
    var theme: Theme = .standard { didSet { needsDisplay = true } }
    /// The panel next to it is the active one (its active tab is drawn highlighted then).
    var isActive = false { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private var cachedTabRects: [NSRect]?
    private var scrollOffset: CGFloat = 0
    var hoveredCloseTab: Int? {
        didSet {
            if hoveredCloseTab != oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var hit: Int? = nil
        for i in tabs.tabs.indices {
            if let cr = closeRect(for: i), cr.insetBy(dx: -2, dy: -2).contains(point) {
                hit = i
                break
            }
        }
        hoveredCloseTab = hit
    }

    override func mouseExited(with event: NSEvent) {
        hoveredCloseTab = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cachedTabRects = nil
        clampScrollOffset()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 20
        let maxScroll = max(0, totalTabsWidth - bounds.width)
        let next = min(maxScroll, max(0, scrollOffset - delta * multiplier))
        if next != scrollOffset {
            scrollOffset = next
            cachedTabRects = nil
            needsDisplay = true
        }
    }

    private var totalTabsWidth: CGFloat {
        let hasClose = tabs.count > 1
        var total: CGFloat = 2
        for (i, tab) in tabs.tabs.enumerated() {
            let font = (i == tabs.active) ? PanelFont.bold : PanelFont.regular
            let titleWidth = ceil((tab.title as NSString).size(withAttributes: [.font: font]).width)
            let width = min(190, max(hasClose ? 70 : 60, titleWidth + (hasClose ? 36 : 24)))
            total += width + 2
        }
        return total
    }

    private func clampScrollOffset() {
        let maxScroll = max(0, totalTabsWidth - bounds.width)
        scrollOffset = min(maxScroll, max(0, scrollOffset))
    }

    private func ensureActiveTabVisible() {
        clampScrollOffset()
        let rects = tabRects
        guard rects.indices.contains(tabs.active), bounds.width > 0 else { return }
        let r = rects[tabs.active]
        if r.minX < 2 {
            scrollOffset = max(0, scrollOffset - (2 - r.minX))
            cachedTabRects = nil
        } else if r.maxX > bounds.width - 2 {
            scrollOffset = min(max(0, totalTabsWidth - bounds.width), scrollOffset + (r.maxX - (bounds.width - 2)))
            cachedTabRects = nil
        }
    }

    /// Where each tab is drawn.
    var tabRects: [NSRect] {
        if let cached = cachedTabRects { return cached }
        var x: CGFloat = 2 - scrollOffset
        let h = bounds.height
        let hasClose = tabs.count > 1
        let rects = tabs.tabs.indices.map { i -> NSRect in
            let tab = tabs.tabs[i]
            let font = (i == tabs.active) ? PanelFont.bold : PanelFont.regular
            let titleWidth = ceil((tab.title as NSString).size(withAttributes: [.font: font]).width)
            let width = min(190, max(hasClose ? 70 : 60, titleWidth + (hasClose ? 36 : 24)))
            defer { x += width + 2 }
            return NSRect(x: x, y: 0, width: width, height: h)
        }
        cachedTabRects = rects
        return rects
    }

    /// Close button rectangle on tab `i` (nil if only 1 tab exists).
    func closeRect(for i: Int) -> NSRect? {
        guard tabs.count > 1, tabRects.indices.contains(i) else { return nil }
        let r = tabRects[i]
        let size: CGFloat = 12
        return NSRect(x: r.maxX - size - 6, y: floor(r.midY - size / 2), width: size, height: size)
    }

    func tab(at point: NSPoint) -> Int? { tabRects.firstIndex { $0.contains(point) } }

    private static let tabTextStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        return style.copy() as! NSParagraphStyle
    }()

    /// Builds a tab outline: square bottom corners at maxY, rounded top corners at minY.
    private func tabPath(rect: NSRect, cornerRadius r: CGFloat = 3.5) -> NSBezierPath {
        let path = NSBezierPath()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        let radius = min(r, min(rect.width / 2, rect.height / 2))

        path.move(to: NSPoint(x: minX, y: maxY))
        path.line(to: NSPoint(x: minX, y: minY + radius))
        path.appendArc(from: NSPoint(x: minX, y: minY),
                       to: NSPoint(x: minX + radius, y: minY),
                       radius: radius)
        path.line(to: NSPoint(x: maxX - radius, y: minY))
        path.appendArc(from: NSPoint(x: maxX, y: minY),
                       to: NSPoint(x: maxX, y: minY + radius),
                       radius: radius)
        path.line(to: NSPoint(x: maxX, y: maxY))
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette(theme)
        palette.chrome.setFill()
        bounds.fill()

        // Continuous baseline along the bottom separating the tab strip from the path bar
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        baseline.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5))
        palette.chromeShadow.setStroke()
        baseline.lineWidth = 1
        baseline.stroke()

        let rects = tabRects
        let activeIndex = tabs.active

        // 1. Draw inactive tabs first
        for (i, r) in rects.enumerated() where i != activeIndex {
            let tabRect = NSRect(x: r.minX, y: 3.5, width: r.width, height: bounds.height - 3.5)
            let fillPath = tabPath(rect: tabRect, cornerRadius: 3.0)
            fillPath.line(to: NSPoint(x: tabRect.minX, y: tabRect.maxY))
            fillPath.close()

            palette.chrome.setFill()
            fillPath.fill()

            let strokePath = tabPath(rect: tabRect.insetBy(dx: 0.5, dy: 0), cornerRadius: 3.0)
            strokePath.line(to: NSPoint(x: tabRect.minX + 0.5, y: tabRect.maxY))
            strokePath.close()
            palette.chromeShadow.setStroke()
            strokePath.lineWidth = 1
            strokePath.stroke()

            let title = EntryFormatter.visible(tabs.tabs[i].title) as NSString
            let font = PanelFont.regular
            let textHeight = ceil(font.ascender - font.descender)
            let rightPad: CGFloat = (tabs.count > 1) ? 22 : 6
            let textRect = NSRect(x: tabRect.minX + 6,
                                  y: tabRect.minY + floor((tabRect.height - textHeight) / 2),
                                  width: max(0, tabRect.width - 6 - rightPad),
                                  height: textHeight)
            title.draw(in: textRect,
                       withAttributes: [.font: font, .foregroundColor: palette.chromeText, .paragraphStyle: Self.tabTextStyle])
            if let cr = closeRect(for: i) {
                drawCloseButton(in: cr, isHovered: hoveredCloseTab == i, isActiveTab: false, palette: palette)
            }
        }

        // 2. Draw active tab on top
        if rects.indices.contains(activeIndex) {
            let r = rects[activeIndex]
            // Active tab is taller and reaches all the way to the bottom edge, covering the baseline
            let tabRect = NSRect(x: r.minX, y: 1.5, width: r.width, height: bounds.height - 1.5)
            let fillPath = tabPath(rect: tabRect, cornerRadius: 3.5)
            fillPath.line(to: NSPoint(x: tabRect.minX, y: tabRect.maxY))
            fillPath.close()

            // Configurable active tab color (default bright white, not teal)
            let activeBg = isActive ? palette.activeTabBackground : (palette.chromeLight.blended(withFraction: 0.6, of: palette.activeTabBackground) ?? palette.activeTabBackground)
            activeBg.setFill()
            fillPath.fill()

            // Stroke left, top-left, top, top-right, right (bottom is open to merge with the panel below)
            let strokePath = tabPath(rect: tabRect.insetBy(dx: 0.5, dy: 0), cornerRadius: 3.5)
            palette.chromeShadow.setStroke()
            strokePath.lineWidth = 1
            strokePath.stroke()

            let title = EntryFormatter.visible(tabs.tabs[activeIndex].title) as NSString
            let font = PanelFont.bold
            let textHeight = ceil(font.ascender - font.descender)
            let rightPad: CGFloat = (tabs.count > 1) ? 22 : 6
            let textRect = NSRect(x: tabRect.minX + 6,
                                  y: tabRect.minY + floor((tabRect.height - textHeight) / 2),
                                  width: max(0, tabRect.width - 6 - rightPad),
                                  height: textHeight)
            let textColor = isActive ? palette.activeTabText : palette.chromeText
            title.draw(in: textRect,
                       withAttributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: Self.tabTextStyle])
            if let cr = closeRect(for: activeIndex) {
                drawCloseButton(in: cr, isHovered: hoveredCloseTab == activeIndex, isActiveTab: true, palette: palette)
            }
        }
    }

    private func drawCloseButton(in cr: NSRect, isHovered: Bool, isActiveTab: Bool, palette: Palette) {
        if isHovered {
            let bg = NSBezierPath(ovalIn: cr.insetBy(dx: -1, dy: -1))
            let hoverBg = (isActiveTab && isActive)
                ? palette.activeTabText.withAlphaComponent(0.18)
                : palette.chromeText.withAlphaComponent(0.18)
            hoverBg.setFill()
            bg.fill()
        }
        let cross = NSBezierPath()
        let pad: CGFloat = 3.0
        cross.move(to: NSPoint(x: cr.minX + pad, y: cr.minY + pad))
        cross.line(to: NSPoint(x: cr.maxX - pad, y: cr.maxY - pad))
        cross.move(to: NSPoint(x: cr.minX + pad, y: cr.maxY - pad))
        cross.line(to: NSPoint(x: cr.maxX - pad, y: cr.minY + pad))
        let strokeColor: NSColor
        if isHovered {
            strokeColor = (isActiveTab && isActive) ? palette.activeTabText : palette.chromeText
        } else {
            strokeColor = ((isActiveTab && isActive) ? palette.activeTabText : palette.chromeText).withAlphaComponent(0.65)
        }
        strokeColor.setStroke()
        cross.lineWidth = 1.3
        cross.lineCapStyle = .round
        cross.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let i = tab(at: point) {
            if let cr = closeRect(for: i), cr.insetBy(dx: -3, dy: -3).contains(point) {
                onClose?(i)
                return
            }
            onSelect?(i)
        } else if event.clickCount == 2 {
            onNew?()
        }
    }

    /// Middle-click closes the tab under the mouse.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        middleClick(at: convert(event.locationInWindow, from: nil))
    }

    func middleClick(at point: NSPoint) {
        if let i = tab(at: point) { onClose?(i) }
    }
}
