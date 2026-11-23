import Cocoa

/// Window placement, combo box hover and drag & drop between panels and to other apps.
enum WindowAndDragTests {
    typealias Fail = CommanderTests.TestFailure
    static func expect(_ c: @autoclosure () throws -> Bool, _ m: String) throws {
        if try !c() { throw Fail(description: m) }
    }

    /// Stands in for AppKit's drag information during a drop.
    final class FakeDrop: NSObject, NSDraggingInfo {
        let source: Any?
        /// In window coordinates.
        let location: NSPoint
        let pasteboard: NSPasteboard
        /// `files`: what Finder would put on the pasteboard.
        init(source: Any?, at location: NSPoint = NSPoint(x: -100, y: -100), files: [URL] = []) {
            self.source = source
            self.location = location
            pasteboard = NSPasteboard(name: .init("ClassicCommanderTests-\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.writeObjects(files.map { $0 as NSURL })
        }
        deinit { pasteboard.releaseGlobally() }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
        var draggingLocation: NSPoint { location }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pasteboard }
        var draggingSource: Any? { source }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("Windows open centred on the main window and are kept on the screen") {
            let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let main = NSRect(x: 100, y: 100, width: 1000, height: 600)
            let c = AppWindows.centered(NSRect(x: 0, y: 0, width: 400, height: 300), on: main, within: screen)
            try expect(c == NSRect(x: 400, y: 250, width: 400, height: 300), "centred on the main window: \(c)")
            let corner = AppWindows.centered(NSRect(x: 0, y: 0, width: 800, height: 600),
                                             on: NSRect(x: 1200, y: 700, width: 200, height: 150), within: screen)
            try expect(corner.maxX <= screen.maxX && corner.maxY <= screen.maxY && corner.size == NSSize(width: 800, height: 600),
                       "moved back onto the screen: \(corner)")
            let huge = AppWindows.centered(NSRect(x: 0, y: 0, width: 3000, height: 2000), on: main, within: screen)
            try expect(huge == screen, "shrunk to the screen: \(huge)")
            try expect(AppWindows.centered(NSRect(x: 0, y: 0, width: 10, height: 10), on: main, within: nil).origin == NSPoint(x: 595, y: 395),
                       "no screen: just centred")

            let mainWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            mainWindow.orderBack(nil)
            defer { mainWindow.orderOut(nil); AppWindows.mainWindow = nil }
            AppWindows.mainWindow = mainWindow
            let dialog = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            AppWindows.place(dialog)
            try expect(abs(dialog.frame.midX - mainWindow.frame.midX) < 1 && abs(dialog.frame.midY - mainWindow.frame.midY) < 1,
                       "placed over the main window: \(dialog.frame) vs \(mainWindow.frame)")
            dialog.orderBack(nil)
            dialog.setFrameOrigin(NSPoint(x: 10, y: 10))
            AppWindows.place(dialog)
            try expect(dialog.frame.origin == NSPoint(x: 10, y: 10), "a window already open stays where it is")
            dialog.orderOut(nil)
        }

        testRunner("Combo box lists highlight the row under the mouse") {
            ComboHover.install()
            ComboHover.install()
            let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 320, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
            let combo = NSComboBox(frame: NSRect(x: 10, y: 30, width: 280, height: 26))
            combo.addItems(withObjectValues: ["/one", "/two", "/three"])
            window.contentView?.addSubview(combo)
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            (combo.cell as? NSComboBoxCell)?.perform(NSSelectorFromString("popUp:"), with: nil)
            var tracker: ComboHover?
            CoverageTests.wait(5) {
                tracker = ComboHover.attach(to: combo)
                return tracker != nil
            }
            guard let hover = tracker else { throw Fail(description: "the combo list was not found") }
            defer { hover.table.window?.orderOut(nil) }
            let table = hover.table
            try expect(hover.highlight.isHidden, "nothing highlighted until the mouse is over a row")
            let row1 = table.rect(ofRow: 1)
            let event = CoverageTests.mouse(.mouseMoved, at: NSPoint(x: row1.midX, y: row1.midY), in: table)
            hover.mouseEntered(with: event)
            try expect(!hover.highlight.isHidden && hover.highlight.frame == row1, "row 2 highlighted: \(hover.highlight.frame)")
            try expect(combo.stringValue.isEmpty, "hovering doesn't change the text")
            hover.highlight.display()
            try expect(hover.highlight.hitTest(NSPoint(x: 1, y: 1)) == nil, "clicks go to the row")
            hover.show(at: NSPoint(x: -50, y: -50))
            try expect(hover.highlight.isHidden, "outside the rows: no highlight")
            hover.mouseMoved(with: event)
            hover.mouseExited(with: event)
            try expect(hover.highlight.isHidden, "mouse left the list")
            hover.mouseMoved(with: event)
            try expect(ComboHover.attach(to: combo) === hover && hover.highlight.isHidden, "reused list starts without a highlight")
            try expect(ComboHover.tableViews(in: NSView()).isEmpty, "no tables in an empty view")
        }

        testRunner("Drag & drop: rows drag their files; a drop on the other panel copies (⇧/⌘ moves)") {
            let left = try CoverageTests.tempDir("DragLeft")
            let right = try CoverageTests.tempDir("DragRight")
            defer {
                try? FileManager.default.removeItem(at: left)
                try? FileManager.default.removeItem(at: right)
                CoverageTests.resetAnswers()
            }
            for name in ["a.txt", "b.txt", "c.txt"] { try Data(name.utf8).write(to: left.appendingPathComponent(name)) }
            let sub = right.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let view = CommanderView(model: CommanderModel(left: PanelModel(directory: left), right: PanelModel(directory: right)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = window.contentView!.bounds
            view.layout()
            view.fileCommands.runInBackground = false
            let panel = view.leftView, other = view.rightView
            let names = panel.model.entries.map(\.name)
            guard let a = names.firstIndex(of: "a.txt"), let b = names.firstIndex(of: "b.txt") else { throw Fail(description: "files: \(names)") }

            // What a drag carries.
            try expect(panel.draggedEntries(forRow: 0).isEmpty && panel.draggedEntries(forRow: 99).isEmpty, ".. and no row drag nothing")
            try expect(panel.draggedEntries(forRow: a).map(\.name) == ["a.txt"], "an unmarked row drags itself")
            panel.model.focus(name: "b.txt", visibleRows: 20)
            _ = panel.model.toggleMarkAtCursor()
            panel.model.focus(name: "c.txt", visibleRows: 20)
            _ = panel.model.toggleMarkAtCursor()
            try expect(panel.draggedEntries(forRow: b).map(\.name) == ["b.txt", "c.txt"], "a marked row drags every marked file")
            try expect(panel.draggedEntries(forRow: a).map(\.name) == ["a.txt"], "an unmarked row ignores the marks")
            let items = panel.draggingItems(for: panel.draggedEntries(forRow: b), from: b)
            let item = items.first?.item as? NSPasteboardItem
            try expect(items.count == 2 && item?.string(forType: .fileURL) == left.appendingPathComponent("b.txt").absoluteString
                       && item?.string(forType: PanelView.entryDragType) == "b.txt", "file URLs for other apps")
            let image = items[0].imageComponents?.first?.contents as? NSImage
            try expect(image?.tiffRepresentation != nil, "drag image drawn")

            // Pressing on a row and moving the mouse starts the drag (a click alone doesn't).
            var dragged: [NSDraggingItem] = []
            Modal.dragged = { dragged = $0 }
            defer { Modal.dragged = { _ in } }
            let rowA = panel.layoutInfo.rows.minY + CGFloat(a - panel.model.scrollTop) * 19 + 9
            let start = NSPoint(x: panel.layoutInfo.rows.minX + 40, y: rowA)
            panel.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: start, in: panel))
            panel.mouseDragged(with: CoverageTests.mouse(.leftMouseDragged, at: NSPoint(x: start.x + 1, y: start.y), in: panel))
            try expect(dragged.isEmpty, "a tiny move is still a click")
            panel.mouseDragged(with: CoverageTests.mouse(.leftMouseDragged, at: NSPoint(x: start.x + 30, y: start.y), in: panel))
            try expect(dragged.count == 1 && panel.draggedEntries.map(\.name) == ["a.txt"], "drag started with a.txt")
            panel.mouseUp(with: CoverageTests.mouse(.leftMouseUp, at: start, in: panel))
            panel.mouseDown(with: CoverageTests.mouse(.leftMouseDown, at: NSPoint(x: start.x, y: panel.layoutInfo.rows.minY + 9), in: panel))
            panel.mouseDragged(with: CoverageTests.mouse(.leftMouseDragged, at: NSPoint(x: start.x + 30, y: panel.layoutInfo.rows.minY + 9), in: panel))
            try expect(dragged.count == 1, ".. can't be dragged")

            // Other apps decide like for Finder's own drags; the other panel may copy or move.
            // The session isn't looked at; any object stands in for it.
            let stand = NSObject()
            let session = Unmanaged<NSDraggingSession>.fromOpaque(Unmanaged.passUnretained(stand).toOpaque()).takeUnretainedValue()
            try expect(panel.draggingSession(session, sourceOperationMaskFor: .outsideApplication) == [.copy, .move, .generic, .delete],
                       "outside: Finder's rules")
            try expect(panel.draggingSession(session, sourceOperationMaskFor: .withinApplication) == [.copy, .move], "inside: copy or move")

            // Where a drop goes.
            func point(ofRow name: String, in view: PanelView) throws -> NSPoint {
                guard let i = view.model.entries.firstIndex(where: { $0.name == name }) else { throw Fail(description: "no row \(name)") }
                let y = view.layoutInfo.rows.minY + CGFloat(i - view.model.scrollTop) * 19 + 9
                return view.convert(NSPoint(x: view.layoutInfo.rows.minX + 40, y: y), to: nil)
            }
            try expect(PanelView.dropOperation(for: []) == .copy && PanelView.dropOperation(for: .shift) == .move
                       && PanelView.dropOperation(for: .command) == .move, "⇧/⌘ move, otherwise copy")
            try expect(panel.draggingEntered(FakeDrop(source: panel)) == [], "not onto its own panel's folder")
            try expect(other.draggingEntered(FakeDrop(source: "Finder")) == [], "nothing to drop")
            // (Copy or move depends on the keys held on the real keyboard right now.)
            try expect([.copy, .move].contains(other.draggingEntered(FakeDrop(source: panel))), "accepted by the other panel")
            try expect(other.dropRow == nil && other.dropTarget(FakeDrop(source: panel), move: false)?.folder.path == right.path,
                       "outside the rows: into the panel's folder")
            let overSub = FakeDrop(source: panel, at: try point(ofRow: "sub", in: other))
            _ = other.draggingUpdated(overSub)
            try expect(other.dropRow != nil && other.dropTarget(overSub, move: false)?.folder.path == sub.path,
                       "over a folder row: into that folder (row framed)")
            other.display()
            other.draggingExited(overSub)
            try expect(other.dropRow == nil, "frame removed when the drag leaves")
            let overParent = FakeDrop(source: panel, at: try point(ofRow: "..", in: other))
            try expect(other.dropTarget(overParent, move: false)?.folder.path == right.deletingLastPathComponent().path,
                       ".. is the parent folder")
            try expect(other.dropTarget(FakeDrop(source: panel, at: try point(ofRow: "a.txt", in: panel)), move: false)?.folderRow == nil,
                       "a file row isn't a folder")
            try expect(!other.performDragOperation(FakeDrop(source: other)), "own drop outside a folder refused")

            // From the other panel into its folder: exactly the dragged file.
            CoverageTests.answer(.alertFirstButtonReturn)
            var dropped: PanelDrop?
            let realDrop = other.onDrop
            other.onDrop = { drop in
                dropped = drop
                // Always a copy here (a real ⇧/⌘ held on the keyboard during the test would make it a move).
                realDrop?(PanelDrop(entries: drop.entries, source: drop.source, target: drop.target, folder: drop.folder,
                                    folderRow: drop.folderRow, move: false))
            }
            try expect(other.performDragOperation(FakeDrop(source: panel)), "drop accepted")
            try expect(dropped?.entries.map(\.name) == ["a.txt"] && dropped?.source === panel, "the dragged file is dropped")
            let copied = right.appendingPathComponent("a.txt")
            CoverageTests.wait(5) { FileManager.default.fileExists(atPath: copied.path) }
            try expect(FileManager.default.fileExists(atPath: copied.path)
                       && !FileManager.default.fileExists(atPath: right.appendingPathComponent("b.txt").path),
                       "only the dragged file copied, not the marked ones")
            try expect(FileManager.default.fileExists(atPath: left.appendingPathComponent("a.txt").path), "a copy keeps the original")
            try expect(view.model.activeSide == .right, "the panel dropped on becomes active")
            panel.draggingSession(session, endedAt: .zero, operation: .copy)
            try expect(panel.draggedEntries.isEmpty, "drag over")

            // Onto a folder row of the other panel.
            panel.model.reload(visibleRows: 20)
            other.model.reload(visibleRows: 20)
            let aAgain = panel.model.entries.filter { $0.name == "a.txt" }
            try expect(!aAgain.isEmpty, "a.txt still on the left")
            view.drop(PanelDrop(entries: aAgain, source: panel, target: other, folder: sub, folderRow: 1, move: false))
            try expect(FileManager.default.fileExists(atPath: sub.appendingPathComponent("a.txt").path), "copied into the folder under the mouse")

            // Within one panel, into one of its own folders (moved).
            other.model.reload(visibleRows: 20)
            let inRight = other.model.entries.filter { $0.name == "a.txt" }
            try FileManager.default.removeItem(at: sub.appendingPathComponent("a.txt"))
            view.drop(PanelDrop(entries: inRight, source: other, target: other, folder: sub, folderRow: 1, move: true))
            try expect(FileManager.default.fileExists(atPath: sub.appendingPathComponent("a.txt").path)
                       && !FileManager.default.fileExists(atPath: copied.path), "moved into its own subfolder")

            // From Finder: file reference URLs, folders, and things that aren't files.
            let outside = try CoverageTests.tempDir("DragFinder")
            defer { try? FileManager.default.removeItem(at: outside) }
            let note = outside.appendingPathComponent("note.md")
            try Data("x".utf8).write(to: note)
            let reference = (note as NSURL).fileReferenceURL() ?? note
            try expect(PanelView.droppedEntry(reference)?.url.path == note.path && PanelView.droppedEntry(reference)?.kind == .file,
                       "Finder's file reference resolved")
            try expect(PanelView.droppedEntry(outside)?.kind == .directory, "folders recognised")
            try expect(PanelView.droppedEntry(URL(string: "https://example.com/x")!) == nil, "web links aren't files")
            let finder = FakeDrop(source: nil, files: [reference])
            try expect([.copy, .move].contains(other.draggingEntered(finder)), "Finder's files accepted")
            try expect(other.dropTarget(finder, move: false)?.source == nil, "from another app")
            try expect(other.performDragOperation(finder), "Finder drop accepted")
            CoverageTests.wait(5) { FileManager.default.fileExists(atPath: right.appendingPathComponent("note.md").path) }
            try expect(FileManager.default.fileExists(atPath: right.appendingPathComponent("note.md").path)
                       && FileManager.default.fileExists(atPath: note.path), "copied in from Finder, original kept")

            // Move (as from a ⇧/⌘ drop) of the marked files.
            view.activate(.right)
            let marked = panel.model.entries.filter { ["b.txt", "c.txt"].contains($0.name) }
            view.drop(PanelDrop(entries: marked, source: panel, target: other, folder: right, folderRow: nil, move: true))
            try expect(FileManager.default.fileExists(atPath: right.appendingPathComponent("c.txt").path)
                       && !FileManager.default.fileExists(atPath: left.appendingPathComponent("b.txt").path), "moved b and c")

            // A file moved away by Finder (or into the Trash): the panel reads its folder again.
            panel.onFilesChanged?()   // the commander's: reloads both panels
            var changed = false
            panel.onFilesChanged = { changed = true }
            panel.draggingSession(session, endedAt: .zero, operation: .copy)
            try expect(!changed, "a copy changes nothing here")
            panel.draggingSession(session, endedAt: .zero, operation: .move)
            try expect(changed, "a move re-reads the panel")
        }
    }
}
