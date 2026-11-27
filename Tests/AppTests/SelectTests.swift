import Cocoa

/// The Select menu, copying names to the clipboard, comparing folders, the long right-click menu
/// and the directory hotlist (quick locations).
enum SelectTests {
    typealias Fail = CommanderTests.TestFailure
    static func expect(_ c: @autoclosure () throws -> Bool, _ m: String) throws {
        if try !c() { throw Fail(description: m) }
    }

    static func entry(_ name: String, _ kind: FileEntry.Kind = .file, size: Int64? = nil, modified: Date? = nil) -> FileEntry {
        FileEntry(name: name, url: URL(fileURLWithPath: "/x/" + name), kind: kind, size: size, modified: modified, permissions: 0o644)
    }

    /// A commander on two temporary folders, in a window, with dialogs answered by `prompts`.
    static func commander(_ left: URL, _ right: URL) -> (CommanderView, StubPrompts, NSWindow) {
        let view = CommanderView(model: CommanderModel(left: PanelModel(directory: left), right: PanelModel(directory: right)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = window.contentView!.bounds
        view.layout()
        let prompts = StubPrompts()
        view.fileCommands.prompts = prompts
        view.fileCommands.runInBackground = false
        return (view, prompts, window)
    }

    static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("Select: all / none, same extension, restore, show selected only") {
            let root = try CommanderTests.makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let p = PanelModel(directory: root)
            p.markAll(true)
            try expect(p.marked == Set(p.entries.filter { $0.kind != .parent }.map(\.name)), "all marked, .. never")
            p.markAll(false)
            try expect(p.marked.isEmpty, "none marked")
            try expect(p.restoreMarks() == p.entries.count - 1, "restore brings the full selection back")
            p.clearMarks()
            p.focus(name: "file2.txt", visibleRows: 20)
            try expect(p.setMarksWithCurrentExtension(true) == 2 && p.marked == ["file2.txt", "file10.txt"], "same extension: \(p.marked)")
            try expect(p.setMarksWithCurrentExtension(false) == 2 && p.marked.isEmpty, "unselect same extension")
            p.focus(name: "alpha", visibleRows: 20)
            try expect(p.setMarksWithCurrentExtension(true) == nil, "not on a folder")
            p.setMarks(["file10.txt", "gone.txt"])
            try expect(p.marked == ["file10.txt"], "only names in the folder")
            p.showMarkedOnly(true, visibleRows: 20)
            try expect(p.showsMarkedOnly && p.entries.map(\.name) == ["..", "file10.txt"] && p.currentEntry?.name == "file10.txt",
                       "only the selection shown: \(p.entries.map(\.name))")
            p.showMarkedOnly(false, visibleRows: 20)
            try expect(p.entries.count > 2, "everything again")
            p.showMarkedOnly(true, visibleRows: 20)
            p.focus(name: "..", visibleRows: 20)
            p.goUp(visibleRows: 20)
            try expect(!p.showsMarkedOnly, "another folder shows everything")
        }

        testRunner("Compare directories: missing, newer, size; folders by name; tolerance") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let left = [entry("..", .parent), entry("same", size: 1, modified: now), entry("newer", size: 1, modified: now + 60),
                        entry("older", size: 1, modified: now), entry("sized", size: 1, modified: now), entry("onlyL", size: 1),
                        entry("dirL", .directory), entry("both", .directory), entry("kind", .directory), entry("close", size: 1, modified: now)]
            let right = [entry("same", size: 1, modified: now), entry("newer", size: 1, modified: now),
                         entry("older", size: 1, modified: now + 60), entry("sized", size: 2, modified: now),
                         entry("onlyR", size: 1), entry("both", .directory), entry("kind", size: 1), entry("close", size: 1, modified: now + 1)]
            let byDate = PanelComparison.compare(left: left, right: right, by: .date)
            try expect(byDate.left == ["newer", "sized", "onlyL", "dirL", "kind"], "left: \(byDate.left)")
            try expect(byDate.right == ["older", "sized", "onlyR", "kind"], "right: \(byDate.right)")
            let bySize = PanelComparison.compare(left: left, right: right, by: .size)
            try expect(bySize.left == ["sized", "onlyL", "dirL", "kind"] && bySize.right == ["sized", "onlyR", "kind"], "size: \(bySize)")
            let tight = PanelComparison.compare(left: left, right: right, by: .date, tolerance: 0)
            try expect(tight.right.contains("close"), "no tolerance: a second counts")
            try expect(PanelComparison.compare(left: [entry("a", size: 1)], right: [entry("a", size: 1)], by: .date).isIdentical, "identical")
        }

        testRunner("Copy names to the clipboard: names, paths, tables with details") {
            let date = Date(timeIntervalSince1970: 0)
            let items = [entry("a.txt", size: 12, modified: date), entry("docs", .directory, modified: date)]
            let path: (FileEntry) -> String = { "/x/" + $0.name }
            try expect(SelectionClipboard.text(items, format: .names, path: path) == "a.txt\ndocs\n", "names")
            try expect(SelectionClipboard.text(items, format: .paths, path: path) == "/x/a.txt\n/x/docs\n", "paths")
            let table = SelectionClipboard.text(items, format: .namesWithDetails, path: path)
            let stamp = SelectionClipboard.dateFormatter.string(from: date)
            try expect(table == "Name\tSize\tDate\tAttributes\na.txt\t12\t\(stamp)\t-644\ndocs\t<DIR>\t\(stamp)\td644\n", table)
            let withPaths = SelectionClipboard.text(items, format: .pathsWithDetails, path: path, folderSize: { _ in 99 })
            try expect(withPaths.hasPrefix("Path\t") && withPaths.contains("/x/docs\t99\t"), withPaths)
            let bare = FileEntry(name: "n", url: URL(fileURLWithPath: "/n"), kind: .file)
            try expect(SelectionClipboard.text([bare], format: .namesWithDetails, path: path) == "Name\tSize\tDate\tAttributes\nn\t\t\t\n", "unknowns empty")
            try expect(SelectionClipboard.text([], format: .names, path: path).isEmpty, "nothing")
        }

        testRunner("Select menu commands in the commander: hide others, compare, clipboard, ⌘A, Esc") {
            let left = try CoverageTests.tempDir("SelectLeft"), right = try CoverageTests.tempDir("SelectRight")
            defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
            for name in ["a.txt", "b.txt", "c.md"] { try Data(name.utf8).write(to: left.appendingPathComponent(name)) }
            try Data("a.txt".utf8).write(to: right.appendingPathComponent("a.txt"))
            let (view, prompts, window) = commander(left, right)
            defer { window.close() }
            let panel = view.leftView
            var settings = view.settings
            settings.operation.selectionHidesOthers = true
            view.settings = settings

            prompts.answer = "*.txt"
            view.perform(.selectByMask)
            try expect(panel.model.marked == ["a.txt", "b.txt"] && panel.model.showsMarkedOnly, "selected and the rest hidden")
            view.keyDown(with: CoverageTests.key(KeyCode.escape, "\u{1b}"))
            try expect(!panel.model.showsMarkedOnly && panel.model.entries.count == 4, "Esc shows everything")
            view.perform(.showMarkedOnly)
            try expect(panel.model.showsMarkedOnly, "toggle on")
            view.perform(.showMarkedOnly)
            view.perform(.deselectAll)
            try expect(panel.model.marked.isEmpty, "unselect all")
            view.perform(.showMarkedOnly)
            view.perform(.deselectAll)
            try expect(!panel.model.showsMarkedOnly, "nothing selected: everything shown")
            view.selectAll(nil)
            try expect(panel.model.marked.count == 3, "⌘A selects all")
            view.perform(.restoreSelection)
            try expect(panel.model.marked == ["a.txt", "b.txt"], "restore brings back the last selection: \(panel.model.marked)")
            panel.model.clearMarks()
            panel.model.markAll(false)
            view.perform(.restoreSelection)
            panel.model.markAll(false)
            panel.model.focus(name: "c.md", visibleRows: 20)
            view.perform(.selectSameExtension)
            try expect(panel.model.marked == ["c.md"] && panel.model.showsMarkedOnly, "same extension, others hidden")
            view.perform(.deselectSameExtension)
            panel.model.showMarkedOnly(false, visibleRows: 20)
            panel.model.focus(name: "..", visibleRows: 20)
            view.perform(.selectSameExtension)   // on ..: beep

            var copied = ""
            Modal.copied = { copied = $0 }
            defer { Modal.copied = { _ in } }
            panel.model.focus(name: "b.txt", visibleRows: 20)
            view.perform(.copyNames)
            try expect(copied == "b.txt\n", "name of the file under the cursor: \(copied)")
            view.perform(.copyPaths)
            try expect(copied == left.appendingPathComponent("b.txt").path + "\n", "full path")
            view.perform(.copyNamesWithDetails)
            try expect(copied.hasPrefix("Name\tSize"), "table")
            view.perform(.copyPathsWithDetails)
            try expect(copied.hasPrefix("Path\tSize"), "table with paths")
            panel.model.focus(name: "..", visibleRows: 20)
            copied = ""
            view.perform(.copyNames)
            try expect(copied.isEmpty, "nothing to copy on ..")

            view.perform(.compareByDate)
            try expect(panel.model.marked == ["b.txt", "c.md"] || panel.model.marked == ["a.txt", "b.txt", "c.md"], "missing on the right: \(panel.model.marked)")
            try expect(panel.model.showsMarkedOnly, "differences only")
            view.perform(.compareBySize)
            try expect(panel.model.marked == ["b.txt", "c.md"] && view.rightView.model.marked.isEmpty, "same size a.txt: \(panel.model.marked)")
            settings.operation.selectionHidesOthers = false
            view.settings = settings
            try FileManager.default.removeItem(at: left.appendingPathComponent("b.txt"))
            try FileManager.default.removeItem(at: left.appendingPathComponent("c.md"))
            panel.model.reload(visibleRows: 20)
            view.perform(.compareBySize)
            try expect(panel.model.marked.isEmpty, "identical folders")
        }

        testRunner("Long right-click: the bar fills, menu opens immediately without selecting; early release selects") {
            let left = try CoverageTests.tempDir("HoldLeft")
            defer { try? FileManager.default.removeItem(at: left) }
            try Data("x".utf8).write(to: left.appendingPathComponent("file.txt"))
            let (view, _, window) = commander(left, left)
            defer { window.close() }
            let panel = view.leftView
            var menu: NSMenu?
            Modal.poppedUp = { menu = $0 }
            defer { Modal.poppedUp = { _ in } }
            guard let row = panel.model.entries.firstIndex(where: { $0.name == "file.txt" }) else { throw Fail(description: "no row") }
            let y = panel.layoutInfo.rows.minY + CGFloat(row - panel.model.scrollTop) * 19 + 9
            let point = NSPoint(x: panel.layoutInfo.rows.minX + 40, y: y)

            panel.rightMouseDown(with: CoverageTests.mouse(.rightMouseDown, at: point, in: panel))
            try expect(panel.holdRow == row && panel.model.marked.isEmpty, "held row, not marked yet on down")
            panel.contextMenuHold = 3
            panel.holdTick(now: Date().addingTimeInterval(1.5))
            try expect(panel.holdProgress > 0.4 && panel.holdProgress < 0.6 && menu == nil, "half full: \(panel.holdProgress)")
            panel.display()
            panel.rightMouseUp(with: CoverageTests.mouse(.rightMouseUp, at: point, in: panel))
            try expect(panel.holdRow == nil && menu == nil && panel.model.marked == ["file.txt"], "released early: marked on release, no menu")
            panel.model.clearMarks()

            panel.rightMouseDown(with: CoverageTests.mouse(.rightMouseDown, at: point, in: panel))
            panel.rightMouseDragged(with: CoverageTests.mouse(.rightMouseDragged, at: NSPoint(x: point.x, y: y + 40), in: panel))
            try expect(panel.holdRow == nil, "moving to another row cancels")
            panel.rightMouseUp(with: CoverageTests.mouse(.rightMouseUp, at: point, in: panel))
            panel.model.clearMarks()
            panel.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: point, in: panel, flags: .control))
            panel.mouseDragged(with: CoverageTests.mouse(.leftMouseDragged, at: NSPoint(x: point.x, y: y + 40), in: panel))
            try expect(panel.holdRow == nil, "control-drag cancels too")
            panel.mouseUp(with: CoverageTests.mouse(.leftMouseUp, at: point, in: panel))
            panel.model.clearMarks()
            panel.holdTick(now: Date())   // nothing held

            // The real timer: full bar opens the menu immediately (without waiting for release) and never selects.
            var settings = view.settings
            settings.operation.contextMenuHold = 0.2
            view.settings = settings
            try expect(panel.contextMenuHold == 0.2, "setting reaches the panel")
            panel.rightMouseDown(with: CoverageTests.mouse(.rightMouseDown, at: point, in: panel))
            CoverageTests.wait(3) { panel.holdReady }
            try expect(panel.holdReady && menu != nil, "full: menu opened immediately without release")
            try expect(panel.model.marked.isEmpty, "long right-click does not select file")
            panel.rightMouseUp(with: CoverageTests.mouse(.rightMouseUp, at: point, in: panel))
            try expect(panel.model.marked.isEmpty, "releasing after menu opened still leaves file unselected")
            try expect(menu?.items.map(\.title).contains("Copy File Path") == true, "menu opened")
            var copied = ""
            Modal.copied = { copied = $0 }
            defer { Modal.copied = { _ in } }
            if let item = menu?.items.first(where: { $0.title == "Copy File Path" }) { view.contextCommand(item) }
            try expect(copied == left.appendingPathComponent("file.txt").path + "\n", "file path copied: \(copied)")

            // Left-click does not start a hold or open context menu (only right-click / control-click does).
            menu = nil
            panel.model.clearMarks()
            panel.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: point, in: panel))
            try expect(panel.holdRow == nil, "left-click does not hold")
            panel.holdTick(now: Date().addingTimeInterval(5))
            try expect(menu == nil, "long left-click does not open context menu")
            panel.mouseUp(with: CoverageTests.mouse(.leftMouseUp, at: point, in: panel))
            try expect(panel.model.marked.isEmpty, "still unselected on mouseUp")

            // Control-click held works the same way: opens menu immediately, does not select.
            menu = nil
            panel.model.clearMarks()
            panel.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: point, in: panel, flags: .control))
            panel.holdTick(now: Date().addingTimeInterval(5))
            try expect(menu != nil, "control-click held opens it immediately")
            try expect(panel.model.marked.isEmpty, "control-click held does not select file")
            panel.mouseUp(with: CoverageTests.mouse(.leftMouseUp, at: point, in: panel))
            try expect(panel.model.marked.isEmpty, "still unselected on mouseUp")

            // Open With: the apps for the file (default first), and Other…
            guard let openWith = menu?.items.first(where: { $0.title == "Open With" })?.submenu else { throw Fail(description: "no Open With") }
            try expect(openWith.items.last?.title == "Other…", "Other… at the end: \(openWith.items.map(\.title))")
            var openedWith: ([URL], URL)?
            Modal.openedWith = { openedWith = ($0, $1) }
            defer { Modal.openedWith = { _, _ in } }
            if let app = openWith.items.first(where: { $0.action == #selector(CommanderView.openWithChosen(_:)) }) {
                view.openWithChosen(app)
                try expect(openedWith?.0.first?.lastPathComponent == "file.txt", "opened with the chosen app")
            }
            Modal.answerPanel = { _ in [URL(fileURLWithPath: "/System/Applications/TextEdit.app")] }
            defer { CoverageTests.resetAnswers() }
            view.openWithOther(openWith.items.last!)
            try expect(openedWith?.1.lastPathComponent == "TextEdit.app", "Other… picks any app")
            view.openWithChosen(NSMenuItem())
            try expect(view.openWithMenu(for: []).items.isEmpty, "nothing to open")
            view.contextCommand(NSMenuItem())   // no command: ignored
            let remoteless = view.contextMenu(for: view.rightView)
            try expect(remoteless.items.contains { $0.title == "Open in Finder" }, "local folder: Finder and Terminal offered")
        }

        testRunner("One button style everywhere: push buttons only, groups share a width, tabs, key windows, alerts") {
            func push(_ t: String) -> NSButton { NSButton(title: t, target: nil, action: nil) }
            let small = push("A"), wide = push("A much longer title")
            small.controlSize = .small
            small.bezelStyle = .texturedRounded
            wide.font = .boldSystemFont(ofSize: 15)
            let check = NSButton(checkboxWithTitle: "Check", target: nil, action: nil)
            let popUp = NSPopUpButton()
            let stack = NSStackView(views: [small, wide, check, popUp])
            let g1 = push("x"), g2 = push("Column mate")
            let grid = NSGridView(views: [[g1], [g2]])
            let coloured = push("→")
            coloured.attributedTitle = NSAttributedString(string: "→", attributes: [.foregroundColor: NSColor.systemGreen,
                                                                                   .font: NSFont.boldSystemFont(ofSize: 16)])
            let tabs = NSTabView()
            let shown = NSTabViewItem(identifier: "a"), hidden = NSTabViewItem(identifier: "b")
            shown.view = NSView()
            let onHiddenTab = push("On another tab")
            let page = NSView()
            page.addSubview(onHiddenTab)
            hidden.view = page
            tabs.addTabViewItem(shown)
            tabs.addTabViewItem(hidden)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            for v in [stack, grid, coloured, tabs] { root.addSubview(v) }

            AppWindows.styleButtons(in: root)
            AppWindows.styleButtons(in: root)   // again: nothing doubles
            try expect(small.bezelStyle == .rounded && small.controlSize == .regular, "small textured button made regular")
            try expect(wide.font == .systemFont(ofSize: NSFont.systemFontSize), "bold title made regular")
            try expect(check.bezelStyle != .rounded && !(AppWindows.isPushButton(check)) && !AppWindows.isPushButton(popUp), "checkbox and pop-up left alone")
            let widths = { (b: NSButton) in b.constraints.filter { $0.identifier == AppWindows.equalWidthID } }
            try expect(widths(small).count == 1 && widths(small)[0].constant == wide.intrinsicContentSize.width, "stack mates as wide as the widest")
            try expect(widths(g1).count == 1 && widths(g1)[0].constant == g2.intrinsicContentSize.width, "grid column mates too")
            try expect(widths(coloured).isEmpty && AppWindows.groupKey(of: coloured) == nil, "a lone button keeps its width")
            try expect(coloured.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemGreen,
                       "coloured title kept")
            try expect(onHiddenTab.bezelStyle == .rounded, "buttons on other tabs too")

            // A window becoming key gets the style (windows built anywhere, buttons added later).
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            defer { window.close() }
            let later = push("Later")
            later.controlSize = .mini
            window.contentView?.addSubview(later)
            AppWindows.styleButtonsWhenShown()
            AppWindows.styleButtonsWhenShown()
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            try expect(later.controlSize == .regular, "styled when the window became key")

            // Alerts: the same buttons, drawn as plain push buttons on the alert's background.
            let alert = NSAlert()
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            Modal.style(alert)
            try expect(alert.buttons.allSatisfy { $0.appearance != nil && $0.bezelStyle == .rounded }, "alert buttons styled")

            // Spatial button navigation with arrows and hjkl.
            let navWin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            let b1 = push("One"); let b2 = push("Two"); let b3 = push("Three"); let b4 = push("Four")
            let navGrid = NSGridView(views: [[b1, b2], [b3, b4]])
            navGrid.translatesAutoresizingMaskIntoConstraints = false
            navWin.contentView?.addSubview(navGrid)
            navWin.layoutIfNeeded()
            navWin.makeFirstResponder(b1)
            try expect(AppWindows.moveButtonFocus(from: b1, in: navWin, direction: (1, 0)) && navWin.firstResponder === b2, "right -> b2")
            try expect(AppWindows.moveButtonFocus(from: b2, in: navWin, direction: (0, -1)) && navWin.firstResponder === b4, "down -> b4")
            try expect(AppWindows.moveButtonFocus(from: b4, in: navWin, direction: (-1, 0)) && navWin.firstResponder === b3, "left -> b3")
            try expect(AppWindows.moveButtonFocus(from: b3, in: navWin, direction: (0, 1)) && navWin.firstResponder === b1, "up -> b1")
        }

        testRunner("Held context menu: stays open on release, hover, submenus, keys, pick on release over an item") {
            final class Target: NSObject {
                var picked: [String] = []
                @objc func pick(_ sender: NSMenuItem) { picked.append(sender.title) }
            }
            let target = Target()
            func item(_ title: String) -> NSMenuItem {
                let item = NSMenuItem(title: title, action: #selector(Target.pick(_:)), keyEquivalent: "")
                item.target = target
                return item
            }
            func move(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            func key(_ code: UInt16, _ chars: String = "") -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                 characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            }
            func center(_ r: NSRect) -> NSPoint { NSPoint(x: r.midX, y: r.midY) }
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(item("Open"))
            let off = item("Disabled")
            off.isEnabled = false
            off.image = NSImage(named: NSImage.folderName)
            menu.addItem(off)
            menu.addItem(.separator())
            let sub = NSMenu()
            sub.autoenablesItems = false
            let app = item("App")
            app.image = NSImage(named: NSImage.folderName)
            sub.addItem(app)
            sub.addItem(item("Other"))
            let with = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            with.submenu = sub
            menu.addItem(with)
            menu.addItem(item("Copy"))
            let hidden = item("Hidden")
            hidden.isHidden = true
            menu.addItem(hidden)

            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
            let start = NSPoint(x: screen.minX + 100, y: screen.maxY - 100)
            let held = HeldMenu(menu, at: start)
            let root = held.levels[0]
            try expect(root.items.map(\.title) == ["Open", "Disabled", "", "Open With", "Copy"], "hidden left out: \(root.items.map(\.title))")
            try expect(abs(root.window.frame.minX - start.x) < 1 && abs(root.window.frame.maxY - start.y) < 1, "top-left at the mouse")

            // The release that ends the long click, and a release over an item the mouse never moved onto: still open.
            held.handle(move(.rightMouseUp, start))
            held.handle(move(.rightMouseUp, center(root.screenRect(ofRow: 0))))
            try expect(!held.done && held.chosen == nil, "release does not close the menu")

            // Hover: disabled and separator rows do not light up; a submenu row opens its submenu.
            held.handle(move(.mouseMoved, center(root.screenRect(ofRow: 1))))
            try expect(root.highlighted == nil, "disabled not highlighted")
            held.handle(move(.rightMouseDragged, center(root.screenRect(ofRow: 0))))
            try expect(root.highlighted == 0, "dragging onto Open highlights it")
            held.handle(move(.mouseMoved, center(root.screenRect(ofRow: 3))))
            held.handle(move(.mouseMoved, center(root.screenRect(ofRow: 3))))
            try expect(held.levels.count == 2 && root.highlighted == 3, "submenu opened once")
            let child = held.levels[1]
            try expect(child.window.frame.minX >= root.window.frame.maxX, "submenu to the right")
            held.handle(move(.mouseMoved, center(child.screenRect(ofRow: 0))))
            try expect(child.highlighted == 0 && held.levels.count == 2, "submenu item highlighted, submenu stays")
            held.handle(move(.mouseMoved, NSPoint(x: screen.maxX + 5000, y: screen.maxY + 5000)))
            try expect(child.highlighted == nil && root.highlighted == 3, "outside: the submenu item loses its highlight")
            held.handle(move(.mouseMoved, center(root.screenRect(ofRow: 0))))
            try expect(held.levels.count == 1 && root.highlighted == 0, "back on Open: submenu closed")

            // Keys.
            held.handle(key(125))
            try expect(root.highlighted == 3, "↓ skips disabled and separator")
            held.handle(key(124))
            try expect(held.levels.count == 2 && held.levels[1].highlighted == 0, "→ enters the submenu")
            held.handle(key(123))
            try expect(held.levels.count == 1, "← leaves it")
            held.handle(key(126))
            held.handle(key(126))
            try expect(root.highlighted == 0, "↑ stops at the first")
            held.handle(key(124))
            try expect(held.levels.count == 1, "→ without a submenu does nothing")
            held.handle(key(125))
            held.handle(key(36))
            try expect(held.levels.count == 2, "Return on a submenu item opens it")
            held.handle(key(0, "o"))
            try expect(held.levels.count == 2 && held.levels[1].highlighted == 1, "typing selects in the submenu: Other")
            held.handle(key(123))
            held.handle(key(0, "c"))
            try expect(held.levels.count == 1 && root.highlighted == 4, "typing selects Copy")
            held.handle(key(0, "z"))
            held.handle(key(0, ""))
            try expect(root.highlighted == 4, "no match: unchanged")
            held.handle(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0)!)
            held.handle(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                           context: nil, subtype: 0, data1: 0, data2: 0)!)
            try expect(!held.done, "other events keep it open")

            // Drawing (highlighted, disabled with image, separator, submenu arrow).
            root.view.highlighted = 3
            for view in [root.view, child.view] {
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
            }

            // Click on Copy: press highlights, release picks; the action is sent after closing.
            let copy = center(root.screenRect(ofRow: 4))
            held.handle(move(.leftMouseDown, copy))
            held.handle(move(.leftMouseUp, copy))
            try expect(held.done && held.chosen?.title == "Copy", "clicked Copy")
            held.close()
            held.perform()
            try expect(target.picked == ["Copy"] && held.levels.isEmpty, "Copy performed")

            // Return picks; Space with nothing highlighted does nothing; ↑ from nothing goes to the last.
            let keys = HeldMenu(menu, at: start)
            keys.handle(key(49))
            keys.handle(key(126))
            try expect(keys.levels[0].highlighted == 4 && !keys.done, "↑ from nothing: last")
            keys.handle(key(36))
            keys.run()   // already done: closes and performs
            try expect(target.picked == ["Copy", "Copy"], "Return picked Copy")

            // Dismissing: Esc, a click outside, the app deactivating; nothing is performed.
            let esc = HeldMenu(menu, at: start)
            esc.handle(key(53))
            let outside = HeldMenu(menu, at: start)
            outside.handle(move(.rightMouseDown, NSPoint(x: screen.maxX + 5000, y: 0)))
            let away = HeldMenu(menu, at: start)
            away.handle(NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: NSEvent.EventSubtype.applicationDeactivated.rawValue, data1: 0, data2: 0)!)
            try expect(esc.done && outside.done && away.done, "dismissed")
            esc.perform()
            try expect(target.picked.count == 2, "nothing performed")

            // Near the bottom-right corner: kept on the screen; the submenu opens to the left.
            let corner = HeldMenu(menu, at: NSPoint(x: screen.maxX - 10, y: screen.minY + 10))
            let frame = corner.levels[0].window.frame
            try expect(screen.contains(frame), "on the screen: \(frame) in \(screen)")
            corner.handle(move(.mouseMoved, center(corner.levels[0].screenRect(ofRow: 3))))
            try expect(corner.levels.count == 2 && corner.levels[1].window.frame.maxX <= frame.minX, "submenu to the left")
            corner.close()

            // The real loop: ends on a queued Esc, and when the app is not frontmost.
            let loop = HeldMenu(menu, at: start)
            loop.isActive = { true }
            NSApp.postEvent(key(53, "\u{1b}"), atStart: true)
            loop.run()
            try expect(loop.done && loop.levels.isEmpty, "Esc ended the loop")
            let inactive = HeldMenu(menu, at: start)
            inactive.isActive = { false }
            inactive.run()
            try expect(inactive.done, "inactive app: closed")

            // Modal: the hook, no window, and the real menu (closed by a queued Esc).
            let saved = Modal.poppedUp
            defer { Modal.poppedUp = saved }
            Modal.poppedUp = nil
            Modal.popUpHeld(menu, at: .zero, in: NSView())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            defer { window.close() }
            NSApp.postEvent(key(53, "\u{1b}"), atStart: true)
            Modal.popUpHeld(menu, at: NSPoint(x: 10, y: 10), in: window.contentView!)
            try expect(target.picked.count == 2, "real menu dismissed")
        }

        testRunner("Quick locations: ▼ / ⌃D menu, save current location, go there, rename, remove") {
            let left = try CoverageTests.tempDir("HotLeft"), right = try CoverageTests.tempDir("HotRight")
            defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
            let (view, prompts, window) = commander(left, right)
            defer { window.close() }
            var saved: [Settings] = []
            view.onSettingsChange = { saved.append($0) }
            var menu: NSMenu?
            Modal.poppedUp = { menu = $0 }
            defer { Modal.poppedUp = { _ in } }

            view.perform(.directoryHotlist)
            try expect(menu?.items.map(\.title) == ["Save Current Location…"], "empty hotlist: \(String(describing: menu?.items.map(\.title)))")
            prompts.answer = "Work"
            if let add = menu?.items.first { view.saveHotlistLocation(add) }
            try expect(view.settings.quickLocations == [QuickLocation(name: "Work", path: left.path)] && saved.count == 1, "saved")
            view.showHotlist(for: .right)
            if let add = menu?.items.first(where: { $0.title == "Save Current Location…" }) { view.saveHotlistLocation(add) }
            try expect(view.settings.quickLocations.map(\.path) == [left.path, right.path], "right folder saved with its own name")
            try expect(view.settings.quickLocations[1].name == right.lastPathComponent, "default name is the folder's")
            prompts.answer = "Renamed"
            view.saveHotlistLocation(menu!.items.first { $0.title == "Save Current Location…" }!)
            try expect(view.settings.quickLocations.count == 2 && view.settings.quickLocations[1].name == "Renamed", "same folder: renamed")
            prompts.answer = nil
            view.fileCommands.prompts = CancelPrompts()
            view.saveHotlistLocation(menu!.items.first { $0.title == "Save Current Location…" }!)
            try expect(view.settings.quickLocations.count == 2, "cancelled: nothing saved")

            view.showHotlist(for: .right)
            guard let work = menu?.items.first(where: { $0.title == "Work" }) else { throw Fail(description: "Work missing") }
            try expect(work.toolTip == left.path && work.keyEquivalent == "1", "path as tooltip, digit key")
            view.hotlistChosen(work)
            try expect(view.rightView.model.directory.path == left.path && view.model.activeSide == .right, "right panel went to Work")
            view.hotlistChosen(NSMenuItem())
            guard let remove = menu?.items.first(where: { $0.title == "Remove" })?.submenu?.items.first else { throw Fail(description: "no Remove") }
            view.removeHotlistLocation(remove)
            try expect(view.settings.quickLocations.map(\.name) == ["Renamed"], "removed")
            let bad = NSMenuItem()
            bad.tag = 9
            view.removeHotlistLocation(bad)
            try expect(view.settings.quickLocations.count == 1, "unknown entry ignored")
        }

        testRunner("Finder's Open With: a folder is shown, files in their folder (marked), app packages as files") {
            let dir = try CoverageTests.tempDir("FinderOpen")
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
            for name in ["a.txt", "b.txt"] { try Data(name.utf8).write(to: dir.appendingPathComponent(name)) }
            let (view, _, window) = commander(FileManager.default.temporaryDirectory, FileManager.default.temporaryDirectory)
            defer { window.close() }
            view.show([dir.appendingPathComponent("sub")], in: .right)
            try expect(view.rightView.model.directory.lastPathComponent == "sub" && view.model.activeSide == .right, "folder shown in the right panel")
            view.show([dir.appendingPathComponent("b.txt")], in: .left)
            try expect(view.leftView.model.directory.path == dir.path && view.leftView.model.currentEntry?.name == "b.txt"
                       && view.leftView.model.marked.isEmpty, "file: its folder, cursor on it")
            view.show([dir.appendingPathComponent("a.txt"), dir.appendingPathComponent("b.txt")], in: .left)
            try expect(view.leftView.model.marked == ["a.txt", "b.txt"] && view.leftView.model.currentEntry?.name == "a.txt", "several: marked")
            view.show([dir.appendingPathComponent("Tool.app")], in: .left)
            try expect(view.leftView.model.directory.path == dir.path && view.leftView.model.currentEntry?.name == "Tool.app", "an app is a file here")
            view.show([], in: .left)

            // Through the app delegate, in the panel chosen in Options.
            let suite = "FinderOpen-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            var s = store.settings
            s.operation.finderOpensIn = .right
            store.save(s)
            let app = AppDelegate(settings: store, windowAutosaveName: "")
            app.activatesApp = false
            let savedMenu = NSApp.mainMenu
            defer { NSApp.mainMenu = savedMenu }
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            app.application(NSApp, open: [dir.appendingPathComponent("sub")])
            try expect(app.commanderView?.rightView.model.directory.lastPathComponent == "sub", "opened in the right panel")
            app.commanderView?.window?.close()
            try expect(try JSONDecoder().decode(OperationOptions.self, from: Data("{}".utf8)).finderOpensIn == .left, "left by default")
            try expect(FinderPanel.right.label == "Right panel", "label")
        }

        testRunner("⇧6 rename in place, ⇧8 delete permanently, 2 refresh, letters-only Quick Search, +/− files only") {
            let dir = try CoverageTests.tempDir("RenameInPlace")
            defer { try? FileManager.default.removeItem(at: dir) }
            for name in ["photo.jpg", "other.txt", "Case.txt"] { try Data(name.utf8).write(to: dir.appendingPathComponent(name)) }
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder.d"), withIntermediateDirectories: true)
            let (view, prompts, window) = commander(dir, dir)
            defer { window.close() }
            let panel = view.leftView

            // ⇧6: the name without its extension is selected; Return renames.
            panel.model.focus(name: "photo.jpg", visibleRows: 20)
            view.perform(.renameInPlace)
            guard let field = panel.renameField else { throw Fail(description: "no editor") }
            try expect(field.stringValue == "photo.jpg" && field.currentEditor()?.selectedRange == NSRange(location: 0, length: 5), "name selected")
            field.stringValue = "holiday.jpg"
            _ = field.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("holiday.jpg").path)
                       && panel.model.currentEntry?.name == "holiday.jpg" && panel.renameField == nil, "renamed, cursor follows")
            // With the option: the whole name; Esc cancels; other commands pass through.
            var s = view.settings
            s.operation.renameSelectsExtension = true
            view.settings = s
            view.perform(.renameInPlace)
            try expect(panel.renameField?.currentEditor()?.selectedRange.length == 11, "extension selected too")
            try expect(panel.renameField?.control(panel.renameField!, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))) == false, "other keys edit")
            _ = panel.renameField?.control(panel.renameField!, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            try expect(panel.renameField == nil && FileManager.default.fileExists(atPath: dir.appendingPathComponent("holiday.jpg").path), "Esc cancels")
            view.perform(.renameInPlace)
            panel.renameField?.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
            try expect(panel.renameField == nil, "leaving the field cancels")
            view.perform(.renameInPlace)
            view.perform(.renameInPlace)   // a second editor replaces the first
            panel.renameField?.finish(nil)
            // Problems: bad names, taken names; a case change is fine; folders select everything.
            let holiday = panel.model.currentEntry!
            view.rename(holiday, to: "a/b", in: panel)
            view.rename(holiday, to: "other.txt", in: panel)
            try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("holiday.jpg").path), "not renamed onto another file")
            view.rename(holiday, to: "holiday.jpg", in: panel)
            panel.model.focus(name: "Case.txt", visibleRows: 20)
            view.rename(panel.model.currentEntry!, to: "case.txt", in: panel)
            try expect(panel.model.entries.contains { $0.name == "case.txt" }, "case change")
            view.rename(FileEntry(name: "gone", url: dir.appendingPathComponent("gone"), kind: .file), to: "new", in: panel)
            panel.model.focus(name: "folder.d", visibleRows: 20)
            s.operation.renameSelectsExtension = false
            view.settings = s
            view.perform(.renameInPlace)
            try expect(panel.renameField?.currentEditor()?.selectedRange.length == 8, "a folder's whole name")
            panel.renameField?.finish(nil)
            panel.model.focus(name: "..", visibleRows: 20)
            view.perform(.renameInPlace)   // ..: beep
            panel.beginRename(selectingExtension: false) { name in try? expect(name == nil, "nothing to rename") }

            // ⇧8: permanently, after a warning.
            var removed: [URL] = []
            view.fileCommands.remove = { urls in removed = urls; return OperationReport() }
            panel.model.focus(name: "other.txt", visibleRows: 20)
            prompts.confirmAnswer = false
            view.perform(.deletePermanently)
            try expect(removed.isEmpty && prompts.lastMessage.contains("can't be restored"), "warned, declined")
            prompts.confirmAnswer = true
            view.perform(.deletePermanently)
            try expect(removed.map(\.lastPathComponent) == ["other.txt"], "deleted permanently")
            let real = dir.appendingPathComponent("real.tmp")
            try Data().write(to: real)
            try expect(FileCommandsCore.remove([real]).done == 1 && !FileManager.default.fileExists(atPath: real.path), "really removed")
            try expect(FileCommandsCore.remove([real]).errors.count == 1, "missing reported")

            // 2 refreshes.
            try Data("n".utf8).write(to: dir.appendingPathComponent("new.txt"))
            view.keyDown(with: CoverageTests.key(KeyCode.two, "2"))
            try expect(panel.model.entries.contains { $0.name == "new.txt" }, "2 re-read the folder")

            // Letters alone: h starts Quick Search instead of moving like a shortcut.
            s.quickSearch.activation = .lettersOnly
            view.settings = s
            view.keyDown(with: CoverageTests.key(4, "h"))
            try expect(view.quickSearch.isOpen && view.quickSearch.field.stringValue == "h", "letter searches")
            try expect(view.quickSearch.mode == .filter, "defaults to filter mode")
            view.quickSearch.close(clearFilter: true)
            s.quickSearch.filterByDefault = false
            view.settings = s
            view.keyDown(with: CoverageTests.key(4, "h"))
            try expect(view.quickSearch.isOpen && view.quickSearch.mode == .search, "search mode when filterByDefault is false")
            view.quickSearch.close(clearFilter: true)
            s.quickSearch.filterByDefault = true
            try expect(!CommanderView.isPlainLetter(CoverageTests.key(4, "h", .control)) && !CommanderView.isPlainLetter(CoverageTests.key(19, "2")),
                       "not plain letters")
            s.quickSearch.activation = .controlOption
            view.settings = s

            // + / −: files only when folders are switched off.
            s.operation.maskSelectsFolders = false
            view.settings = s
            prompts.answer = "*.*"
            view.perform(.selectByMask)
            try expect(!panel.model.marked.contains("folder.d") && panel.model.marked.contains("new.txt"), "files only: \(panel.model.marked)")
        }

        testRunner("Refresh automatically: new and removed files appear; size changes only with the second option") {
            let dir = try CoverageTests.tempDir("AutoRefresh")
            defer { try? FileManager.default.removeItem(at: dir) }
            let sizeFile = dir.appendingPathComponent("grow.txt")
            try Data("a".utf8).write(to: sizeFile)
            let (view, _, window) = commander(dir, dir)
            defer { window.close() }
            let panel = view.leftView
            try expect(view.watchers[.left]?.folder.path == FileSystemLister.realPath(of: dir).path, "watching the folder")
            try Data("n".utf8).write(to: dir.appendingPathComponent("new.txt"))
            CoverageTests.wait(10) { panel.model.entries.contains { $0.name == "new.txt" } }
            try expect(panel.model.entries.contains { $0.name == "new.txt" }, "a new file appears by itself")
            try FileManager.default.removeItem(at: dir.appendingPathComponent("new.txt"))
            CoverageTests.wait(10) { !panel.model.entries.contains { $0.name == "new.txt" } }
            try expect(!panel.model.entries.contains { $0.name == "new.txt" }, "a deleted file disappears")

            var s = view.settings
            s.operation.autoRefresh = .everything
            view.settings = s
            try Data("bigger".utf8).write(to: sizeFile)
            CoverageTests.wait(10) { panel.model.entries.first { $0.name == "grow.txt" }?.size == 6 }
            try expect(panel.model.entries.first { $0.name == "grow.txt" }?.size == 6, "size change shown")

            // The rules for which events count.
            let structure = DirectoryWatcher(folder: dir, mode: .structure) {}!
            let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            let root = FileSystemLister.realPath(of: dir).path
            try expect(structure.relevant(root + "/x", created) && !structure.relevant(root + "/x", modified), "structure: created only")
            try expect(!structure.relevant(root + "/sub/x", created), "subfolders aren't watched")
            try expect(DirectoryWatcher(folder: dir, mode: .everything) {}!.relevant(root + "/x", modified), "everything: modified too")
            try expect(DirectoryWatcher(folder: dir, mode: .off) {} == nil && DirectoryWatcher(folder: URL(string: "ccftp://s/x")!, mode: .structure) {} == nil,
                       "off / servers: no watcher")
            var called = false
            let w = DirectoryWatcher(folder: dir, mode: .structure) { called = true }!
            w.handle([(root + "/y", created)])
            w.stop()
            w.stop()
            try expect(called, "handled")
            try expect(AutoRefresh.off.label.hasPrefix("Off"), "label")

            s.operation.autoRefresh = .off
            view.settings = s
            try expect(view.watchers[.left] == nil, "off: not watching")
            view.folderChanged(nil)
        }

        testRunner("Divider between the panels: drag, minimum width, snaps to 50 %, double-click, remembered") {
            let (view, _, window) = commander(FileManager.default.temporaryDirectory, FileManager.default.temporaryDirectory)
            defer { window.close() }
            let total: CGFloat = 1000 - 2 * CommanderView.margin - CommanderView.gap
            try expect(CommanderView.ratio(forDividerAt: 2 + 3 + 500 + 5, total: total) == 0.5, "near the middle: snaps")
            let r = CommanderView.ratio(forDividerAt: 700, total: total)
            try expect(r > 0.6 && r < 0.75, "dragged right: \(r)")
            let tight = CommanderView.ratio(forDividerAt: 5, total: total)
            try expect(abs(CommanderView.leftWidth(ratio: tight, total: total) - PanelView.minimumWidth) <= 1, "never narrower than the minimum")
            try expect(CommanderView.leftWidth(ratio: 0.99, total: total) <= total - PanelView.minimumWidth, "the right panel keeps its minimum")
            try expect(CommanderView.ratio(forDividerAt: 0, total: 0) == 0.5 && CommanderView.leftWidth(ratio: 0.1, total: 100) == 50, "tiny windows")
            try expect(PanelView.minimumWidth > 200 && PanelView.minimumWidth < 420, "minimum: \(PanelView.minimumWidth)")

            var saved: CGFloat?
            view.onSplitChange = { saved = $0 }
            let divider = NSPoint(x: view.dividerRect.midX, y: 100)
            view.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: divider, in: view))
            view.mouseDragged(with: CoverageTests.mouse(.leftMouseDragged, at: NSPoint(x: 650, y: 100), in: view))
            view.mouseUp(with: CoverageTests.mouse(.leftMouseUp, at: NSPoint(x: 650, y: 100), in: view))
            try expect(view.leftView.frame.width > 600 && saved == view.splitRatio, "dragged and reported: \(view.leftView.frame.width)")
            view.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: NSPoint(x: view.dividerRect.midX, y: 100), in: view, clicks: 2))
            view.layoutSubtreeIfNeeded()
            try expect(view.splitRatio == 0.5 && saved == 0.5, "double-click: halves")
            // Elsewhere: not the divider.
            view.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: NSPoint(x: 5, y: 5), in: view))
            view.mouseDragged(with: CoverageTests.mouse(.leftMouseDragged, at: NSPoint(x: 900, y: 5), in: view))
            view.mouseUp(with: CoverageTests.mouse(.leftMouseUp, at: NSPoint(x: 900, y: 5), in: view))
            try expect(view.splitRatio == 0.5, "no drag outside the divider")
            view.resetCursorRects()

            let suite = "Split-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            try expect(store.splitRatio == 0.5, "halves by default")
            store.splitRatio = 0.3
            try expect(SettingsStore(defaults: defaults).splitRatio == 0.3, "remembered")
            let app = AppDelegate(settings: store, windowAutosaveName: "")
            app.activatesApp = false
            let savedMenu = NSApp.mainMenu
            defer { NSApp.mainMenu = savedMenu }
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            try expect(app.commanderView?.splitRatio == 0.3, "the app opens with it")
            app.commanderView?.onSplitChange?(0.6)
            try expect(store.splitRatio == 0.6, "the app saves changes")
            app.commanderView?.window?.close()
        }

        testRunner("Tabs: model — add, select, close (never the last), neighbours, saved folders") {
            let a = URL(fileURLWithPath: "/tmp"), b = URL(fileURLWithPath: "/usr"), c = URL(fileURLWithPath: "/")
            var t = PanelTabs(folder: a)
            t.add(folder: b, focus: "bin")
            t.add(folder: c, focus: nil)
            try expect(t.count == 3 && t.active == 2 && t.current.title == "/" && t.tabs[1].title == "usr", "added after the active one")
            try expect(t.neighbour(1) == 0 && t.neighbour(-1) == 1, "wraps around")
            t.select(0)
            try expect(t.close(2) == false && t.active == 0 && t.count == 2, "closing another tab")
            t.select(1)
            try expect(t.close(1) == true && t.active == 0, "closing the active (last) tab")
            try expect(t.close(0) == false && t.count == 1, "the last tab stays")
            t.select(5)
            t.update(folder: b, focus: "x")
            try expect(t.current.folder == b && t.current.focus == "x", "follows the panel")
            t.add(folder: URL(string: "ccftp://s/www")!, focus: nil)
            try expect(t.saved.paths == ["/usr"] && t.saved.active == 0, "server tabs aren't saved: \(t.saved)")
            let restored = PanelTabs(saved: ["/usr", "/gone-\(UUID().uuidString)", "/tmp"], active: 7, fallback: a)
            try expect(restored.tabs.map(\.folder.path) == ["/usr", "/tmp"] && restored.active == 1, "restored, gone left out")
            try expect(PanelTabs(saved: [], active: 0, fallback: a).current.folder == a, "fallback")
            try expect(TabBarMode.always.label == "Always", "label")
            let job = TransferJob(title: "b", items: [], isMove: false)
            job.partial[0] = 5
            job.completedBytes = 10
            try expect(job.bytesDone == 15, "bytes done counts files in progress")
        }

        testRunner("Tabs in the commander: ⌃T, click, middle-click, ⌃W, ⌃Tab, bar only with several, swap, remembered") {
            let one = try CoverageTests.tempDir("TabOne"), two = try CoverageTests.tempDir("TabTwo")
            defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
            try Data("x".utf8).write(to: one.appendingPathComponent("a.txt"))
            let (view, _, window) = commander(one, two)
            defer { window.close() }
            var reported: [(CommanderModel.Side, PanelTabs)] = []
            view.onTabsChange = { reported.append(($0, $1)) }
            view.layout()
            try expect(view.leftTabBar.isHidden && view.leftView.frame.minY == 0, "one tab: no bar")
            view.leftView.model.focus(name: "a.txt", visibleRows: 20)
            view.perform(.newTab)
            view.layout()
            try expect(view.tabs[.left]?.count == 2 && !view.leftTabBar.isHidden && view.leftView.tabHeight == TabBarView.height && view.leftTabBar.frame.minY == view.leftView.layoutInfo.driveBar.maxY, "bar appears between drive bar and path bar")
            view.jump(.left, to: two)
            try expect(view.tabs[.left]?.current.folder.path == two.path, "the active tab follows")
            // Click the first tab: back to its folder, cursor where it was.
            let firstTab = view.leftTabBar.tabRects[0]
            view.leftTabBar.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: NSPoint(x: firstTab.midX, y: firstTab.midY), in: view.leftTabBar))
            try expect(view.leftView.model.directory.path == one.path && view.leftView.model.currentEntry?.name == "a.txt", "tab selected")
            // Drawn (active panel and not).
            let image = NSImage(size: NSSize(width: 400, height: TabBarView.height))
            image.lockFocus()
            view.leftTabBar.isActive = false
            view.leftTabBar.draw(NSRect(x: 0, y: 0, width: 400, height: TabBarView.height))
            view.leftTabBar.isActive = true
            view.leftTabBar.draw(NSRect(x: 0, y: 0, width: 400, height: TabBarView.height))
            image.unlockFocus()
            view.perform(.nextTab)
            try expect(view.leftView.model.directory.path == two.path, "⌃Tab")
            view.perform(.previousTab)
            try expect(view.leftView.model.directory.path == one.path, "⌃⇧Tab")
            // Middle-click closes; other buttons don't.
            let second = view.leftTabBar.tabRects[1]
            let middle = NSEvent.mouseEvent(with: .otherMouseDown, location: view.leftTabBar.convert(NSPoint(x: second.midX, y: second.midY), to: nil),
                                            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1)!
            view.leftTabBar.otherMouseDown(with: middle)   // not the middle button: ignored
            if let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center),
               let center = NSEvent(cgEvent: cg) {
                view.leftTabBar.otherMouseDown(with: center)
            }
            try expect(view.tabs[.left]?.count == 2, "not over a tab: nothing closed")
            // Clicking "X" on the tab closes it
            if let cr = view.leftTabBar.closeRect(for: 1) {
                view.leftTabBar.mouseMoved(with: CoverageTests.mouse(.mouseMoved, at: NSPoint(x: cr.midX, y: cr.midY), in: view.leftTabBar))
                try expect(view.leftTabBar.hoveredCloseTab == 1, "hovering close button")
                view.leftTabBar.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: NSPoint(x: cr.midX, y: cr.midY), in: view.leftTabBar))
                try expect(view.tabs[.left]?.count == 1, "clicking X closed the tab")
            }
            view.newTab(.left)
            try expect(view.tabs[.left]?.count == 2, "re-added second tab")
            view.leftTabBar.middleClick(at: NSPoint(x: second.midX, y: second.midY))
            try expect(view.tabs[.left]?.count == 1, "middle-click closed it")
            try expect(view.leftTabBar.acceptsFirstMouse(for: nil), "first click works")
            // ⌘W closes tab if several, or hides window if only one remains
            var windowClosed = false
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in
                windowClosed = true
            }
            view.perform(.closeTab)
            try expect(view.tabs[.left]?.count == 1, "the last tab stays in the model")
            try expect(windowClosed, "when no more tabs to close, ⌘W closes/hides the window")
            view.perform(.nextTab)   // one tab: beep
            // Double-click the empty bar: a new tab (the bar shows always with the option).
            var s = view.settings
            s.display.tabBar = .always
            view.settings = s
            view.layout()
            try expect(!view.leftTabBar.isHidden, "always shown")
            view.leftTabBar.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: NSPoint(x: 900, y: 10), in: view.leftTabBar, clicks: 2))
            try expect(view.tabs[.left]?.count == 2, "double-click: new tab")
            view.leftTabBar.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: NSPoint(x: 900, y: 10), in: view.leftTabBar))
            view.closeTab(1, side: .left)
            view.newTab(.left)
            view.closeTab(0, side: .left)
            try expect(view.tabs[.left]?.count == 1 && view.tabs[.left]?.active == 0, "closed the first, active moved")
            view.selectTab(9, side: .left)
            // A tab on a server whose connection is gone goes home.
            var remote = PanelTabs(folder: one)
            remote.add(folder: URL(string: "ccftp://gone/www")!, focus: nil)
            remote.select(0)
            view.restoreTabs(remote, side: .right)
            view.selectTab(1, side: .right)
            try expect(view.rightView.model.directory.path == FileManager.default.homeDirectoryForCurrentUser.path, "closed server tab: home")
            // Swap panels: the tabs go along.
            let leftCount = view.tabs[.left]?.count, rightCount = view.tabs[.right]?.count
            view.swapPanels()
            try expect(view.tabs[.left]?.count == rightCount && view.tabs[.right]?.count == leftCount, "tabs swapped")
            try expect(!reported.isEmpty, "changes reported")

            // Remembered by the app.
            let suite = "Tabs-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            var saved = PanelTabs(folder: one)
            saved.add(folder: two, focus: nil)
            store.saveTabs(saved, side: .left)
            try expect(store.tabs(.left).paths == [one.path, two.path] && store.tabs(.left).active == 1 && store.tabs(.right).paths.isEmpty, "saved")
            let app = AppDelegate(settings: store, windowAutosaveName: "")
            app.activatesApp = false
            let savedMenu = NSApp.mainMenu
            defer { NSApp.mainMenu = savedMenu }
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            try expect(app.commanderView?.tabs[.left]?.count == 2 && app.commanderView?.leftView.model.directory.path == two.path, "restored at launch")
            app.commanderView?.closeTab(1, side: .left)
            try expect(store.tabs(.left).paths == [one.path], "changes saved")
            app.commanderView?.window?.close()
        }

        testRunner("Settings: new options and quick locations load, save, export and import") {
            let suite = "SelectTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            var s = store.settings
            s.operation.selectionHidesOthers = true
            s.operation.contextMenuHold = 1.5
            s.quickLocations = [QuickLocation(name: "Tmp", path: "/tmp")]
            store.save(s)
            let again = SettingsStore(defaults: defaults)
            try expect(again.settings.operation.selectionHidesOthers && again.settings.operation.contextMenuHold == 1.5
                       && again.settings.quickLocations == s.quickLocations, "reloaded")
            let imported = try SettingsFile.importing(try SettingsFile.export(s), onto: Settings())
            try expect(imported.quickLocations == s.quickLocations && imported.operation == s.operation, "export / import")
            let json = Data(#"{"contextMenuHold": 99}"#.utf8)
            try expect(try JSONDecoder().decode(OperationOptions.self, from: json).contextMenuHold == 10, "hold clamped")
            try expect(try JSONDecoder().decode(OperationOptions.self, from: Data("{}".utf8)).contextMenuHold == 1, "default 1 s")
            // The old 3 s default becomes 1 s once; a value set by hand stays.
            let oldSuite = "SelectTests-old-\(UUID().uuidString)"
            let old = UserDefaults(suiteName: oldSuite)!
            defer { old.removePersistentDomain(forName: oldSuite) }
            old.set(try JSONEncoder().encode(OperationOptions(contextMenuHold: 3)), forKey: "operationOptions")
            try expect(SettingsStore(defaults: old).settings.operation.contextMenuHold == 1, "3 s migrated to 1 s")
            var chosen = SettingsStore(defaults: old).settings
            chosen.operation.contextMenuHold = 3
            SettingsStore(defaults: old).save(chosen)
            try expect(SettingsStore(defaults: old).settings.operation.contextMenuHold == 3, "chosen 3 s kept after the migration")
        }
    }
}

/// Answers every question with Cancel.
final class CancelPrompts: FileCommandPrompts {
    func askText(title: String, message: String, defaultValue: String, okTitle: String) -> String? { nil }
    func confirm(title: String, message: String, okTitle: String) -> Bool { false }
    func resolveConflict(_ conflict: TransferConflict) -> ConflictDecision { .cancel }
    func showProblems(title: String, report: OperationReport) {}
}
