import Cocoa

/// The Multi-Rename Tool: masks, counter, ranges, case, search & replace, problems, swaps, Undo, the window.
enum MultiRenameTests {
    typealias Fail = CommanderTests.TestFailure
    static func expect(_ c: @autoclosure () throws -> Bool, _ m: String) throws {
        if try !c() { throw Fail(description: m) }
    }

    static func file(_ name: String, _ kind: FileEntry.Kind = .file, date: Date? = nil) -> FileEntry {
        FileEntry(name: name, url: URL(fileURLWithPath: "/x/" + name), kind: kind, size: 1, modified: date)
    }

    static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("Multi-Rename rules: [N] [E] ranges, counter, date/time, case, search & replace") {
            var r = RenameRules()
            let photo = file("Holiday Photo.JPG")
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "Holiday Photo.JPG", "unchanged")
            r.nameMask = "[N1-3]_[C]"
            r.counterStart = 5; r.counterStep = 2; r.counterDigits = 3
            try expect(try MultiRename.newName(for: photo, index: 2, rules: r) == "Hol_009.JPG", "range + counter")
            r.nameMask = "[N9-]"; r.extensionMask = "[E2]x"
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "Photo.Px", "range to the end, one ext char")
            r.nameMask = "[N4]-[N20-30]-[N5-2]-[Nx]-[Q]-[N1-x]"; r.extensionMask = ""
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "i--- [Nx]-[Q]-[N1-x]".replacingOccurrences(of: " ", with: ""),
                       "edge ranges and unknowns kept: \(try MultiRename.newName(for: photo, index: 0, rules: r))")
            var c = DateComponents()
            c.year = 2015; c.month = 5; c.day = 22; c.hour = 22; c.minute = 38; c.second = 58
            let dated = file("x.txt", date: Calendar.current.date(from: c))
            r = RenameRules()
            r.nameMask = "[YMD]-[hms]-[Y][M][D][h][m][s]-[C]"
            r.counterStart = -3
            try expect(try MultiRename.newName(for: dated, index: 0, rules: r) == "20150522-223858-20150522223858--3.txt", "date, time, negative counter")
            try expect(try MultiRename.newName(for: file("y", date: nil), index: 0, rules: r).hasPrefix("1970"), "no date")
            r = RenameRules()
            r.nameMask = "[N"
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "[N.JPG", "unclosed bracket kept")
            let folder = file("My Folder", .directory)
            r = RenameRules()
            r.nameMask = "[N].[E]"
            try expect(try MultiRename.newName(for: folder, index: 0, rules: r) == "My Folder.", "folders have no extension")

            r = RenameRules()
            r.search = "photo"; r.replace = "pic"
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "Holiday pic.JPG", "plain, ignoring case")
            r.caseSensitive = true
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "Holiday Photo.JPG", "case sensitive: no match")
            r = RenameRules()
            r.search = "o"; r.replace = "0"; r.firstOnly = true
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "H0liday Photo.JPG", "first only")
            r.firstOnly = false; r.search = "zz"
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "Holiday Photo.JPG", "no match")
            r.firstOnly = true
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "Holiday Photo.JPG", "no match, first only")
            r = RenameRules()
            r.search = "jpg"; r.replace = "jpeg"; r.includeExtension = true
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "Holiday Photo.jpeg", "into the extension")
            r = RenameRules()
            r.regex = true; r.search = "(\\w+) (\\w+)"; r.replace = "$2_$1"
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "Photo_Holiday.JPG", "regex groups")
            r.firstOnly = true; r.search = "o"; r.replace = "0"
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "H0liday Photo.JPG", "regex first only")
            r.search = "q"
            try expect(try MultiRename.newName(for: photo, index: 0, rules: r) == "Holiday Photo.JPG", "regex first only, no match")
            r.search = "("
            do { _ = try MultiRename.newName(for: photo, index: 0, rules: r); throw Fail(description: "bad regex must throw") } catch is Fail { throw Fail(description: "bad regex must throw") } catch {}

            let cases: [(RenameRules.Case, String)] = [(.unchanged, "hELLO wORLD.Txt"), (.lower, "hello world.txt"), (.upper, "HELLO WORLD.TXT"),
                                                       (.firstUpper, "Hello world.txt"), (.words, "Hello World.Txt")]
            for (mode, expected) in cases {
                r = RenameRules()
                r.letterCase = mode
                try expect(try MultiRename.newName(for: file("hELLO wORLD.Txt"), index: 0, rules: r) == expected, "\(mode): \(expected)")
                try expect(!mode.label.isEmpty, "label")
            }
        }

        testRunner("Multi-Rename problems: empty, slash, duplicates (any case), names taken; swaps and Undo on disk") {
            var r = RenameRules()
            let entries = [file("a.txt"), file("b.txt")]
            r.nameMask = ""; r.extensionMask = ""
            try expect(try MultiRename.preview(entries, rules: r, existing: []).allSatisfy { $0.problem == "empty name" }, "empty")
            r = RenameRules(); r.nameMask = "x/[N]"
            try expect(try MultiRename.preview(entries, rules: r, existing: [])[0].problem?.contains("/") == true, "slash")
            r = RenameRules(); r.nameMask = "same"; r.extensionMask = "txt"
            try expect(try MultiRename.preview([file("a.txt"), file("B.TXT")], rules: r, existing: []).allSatisfy { $0.problem == "two files would get this name" },
                       "duplicates ignore case")
            r = RenameRules(); r.nameMask = "c"
            let taken = try MultiRename.preview([file("a.txt")], rules: r, existing: ["C.txt"])
            try expect(taken[0].problem == "a file with this name exists", "taken by another file")
            r = RenameRules(); r.letterCase = .upper
            try expect(try MultiRename.preview([file("a.txt")], rules: r, existing: ["other"])[0].problem == nil, "a case change of itself is fine")

            // On disk: swap two names, then undo.
            let dir = try CoverageTests.tempDir("MultiRename")
            defer { try? FileManager.default.removeItem(at: dir) }
            for (name, text) in [("a.txt", "A"), ("b.txt", "B"), ("c.txt", "C")] { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
            let onDisk = PanelModel(directory: dir).entries.filter { $0.kind != .parent }
            let rows = [MultiRename.Row(entry: onDisk[0], newName: "b.txt", problem: nil), MultiRename.Row(entry: onDisk[1], newName: "a.txt", problem: nil),
                        MultiRename.Row(entry: onDisk[2], newName: "c.txt", problem: nil)]
            let move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
            let result = MultiRename.apply(rows, rename: move)
            try expect(result.errors.isEmpty && result.done.count == 2, "two renamed (c unchanged)")
            try expect(try String(contentsOf: dir.appendingPathComponent("a.txt")) == "B", "swapped")
            let undone = MultiRename.undo(result.done, rename: move)
            try expect(undone.errors.isEmpty && (try String(contentsOf: dir.appendingPathComponent("a.txt"))) == "A", "undone")
            // A failure moving aside puts everything back; a failure at the end is reported.
            var calls = 0
            let failSecond: (URL, URL) throws -> Void = { from, to in
                calls += 1
                if calls == 2 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: from, to: to)
            }
            let failed = MultiRename.apply(rows, rename: failSecond)
            try expect(failed.done.isEmpty && failed.errors.count == 1 && (try String(contentsOf: dir.appendingPathComponent("a.txt"))) == "A", "rolled back")
            calls = 0
            let failLast: (URL, URL) throws -> Void = { from, to in
                calls += 1
                if calls == 3 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: from, to: to)
            }
            let partly = MultiRename.apply(rows, rename: failLast)
            try expect(partly.done.count == 1 && partly.errors.count == 2 && partly.errors[1].contains(".cc-rename-"),
                       "one done; the other reported with where it is: \(partly)")
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            try expect(names.count == 3 && names.contains("a.txt") && names.contains { $0.hasPrefix(".cc-rename-") }, "nothing lost: \(names)")
            // Not a swap: a failed rename goes straight back to its old name.
            let lone = dir.appendingPathComponent("c.txt")
            calls = 0
            let failFinal: (URL, URL) throws -> Void = { from, to in
                calls += 1
                if calls == 2 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: from, to: to)
            }
            let back = MultiRename.apply([MultiRename.Row(entry: FileEntry(name: "c.txt", url: lone, kind: .file), newName: "d.txt", problem: nil)],
                                         rename: failFinal)
            try expect(back.done.isEmpty && back.errors.count == 1 && FileManager.default.fileExists(atPath: lone.path), "put back")
        }

        testRunner("Multi-Rename window: selection or whole list, live preview, buttons, Start!, Undo, sorting, history") {
            let dir = try CoverageTests.tempDir("MultiRenameUI")
            defer { try? FileManager.default.removeItem(at: dir) }
            for name in ["one.txt", "two.txt", "keep.md"] { try Data(name.utf8).write(to: dir.appendingPathComponent(name)) }
            let (view, _, window) = SelectTests.commander(dir, dir)
            defer { window.close() }
            let suite = "MultiRename-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let tool = MultiRenameWindowController(commander: view, defaults: defaults)
            let panel = view.leftView
            panel.model.setMarks(["one.txt", "two.txt"])
            tool.present(for: panel)
            try expect(tool.entries.map(\.name) == ["one.txt", "two.txt"], "only the marked files")
            try expect(!tool.startButton.isEnabled && tool.statusLabel.stringValue.hasPrefix("Nothing changes"), "nothing to do yet")
            tool.window?.makeFirstResponder(nil)
            tool.nameField.stringValue = "file_"
            tool.insertToken(CommanderTests.allViews(NSButton.self, in: tool.window!.contentView!).first { $0.title == "[C] Counter" }!)
            tool.digitsPopup.selectItem(at: 1)
            tool.changed()
            try expect(tool.rows.map(\.newName) == ["file_01.txt", "file_02.txt"], "preview: \(tool.rows.map(\.newName))")
            try expect(tool.startButton.isEnabled, "Start! on")
            func cell(_ column: String, _ row: Int) -> NSTextField? {
                tool.tableView(tool.table, viewFor: tool.table.tableColumns.first { $0.identifier.rawValue == column }, row: row) as? NSTextField
            }
            try expect(cell("new", 0)?.stringValue == "file_01.txt" && cell("old", 0)?.stringValue == "one.txt"
                       && cell("size", 0)?.stringValue == "7" && cell("where", 0)?.stringValue == dir.path && cell("date", 0) != nil, "cells")
            try expect(tool.tableView(tool.table, viewFor: nil, row: 9) == nil, "no row")
            for key in ["size", "date", "where", "new", "old"] {
                tool.table.sortDescriptors = [NSSortDescriptor(key: key, ascending: false)]
            }
            try expect(tool.entries.map(\.name) == ["two.txt", "one.txt"], "sorted by old name, descending: \(tool.entries.map(\.name))")
            tool.table.sortDescriptors = [NSSortDescriptor(key: "old", ascending: true)]
            tool.table.sortDescriptors = []
            tool.tableView(tool.table, sortDescriptorsDidChange: [])

            // A clash with a file that isn't renamed is shown in red and stops Start!.
            tool.nameField.stringValue = "keep"
            tool.extField.stringValue = "md"
            tool.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            try expect(!tool.startButton.isEnabled && tool.statusLabel.textColor == .systemRed && cell("new", 0)?.toolTip != nil, "problem shown")
            tool.startPressed()
            tool.regexBox.state = .on
            tool.searchField.stringValue = "("
            tool.changed()
            try expect(tool.statusLabel.stringValue.contains("regular expression"), "bad regex reported")
            tool.regexBox.state = .off
            tool.searchField.stringValue = ""
            tool.nameField.stringValue = "[N]_new"
            tool.extField.stringValue = "[E]"
            tool.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification))
            CoverageTests.wait(1) { tool.rows.first?.newName == "one_new.txt" }
            tool.startPressed()
            try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("one_new.txt").path) && tool.lastRun.count == 2, "renamed on disk")
            try expect(tool.entries.map(\.name) == ["one_new.txt", "two_new.txt"] && tool.undoButton.isEnabled, "list follows the new names")
            try expect(defaults.stringArray(forKey: "multiRename.nameHistory") == ["[N]_new"], "history")
            tool.undoPressed()
            try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("one.txt").path) && tool.lastRun.isEmpty, "undone")
            tool.undoPressed()   // nothing to undo: beep
            // The extension button inserts into the extension field (where the cursor is, when editing).
            tool.window?.makeFirstResponder(tool.extField)
            tool.insertToken(CommanderTests.allViews(NSButton.self, in: tool.window!.contentView!).first { $0.title == "[E] Ext." }!)
            try expect(tool.extField.stringValue.contains("[E]"), "extension token")
            tool.closePressed()

            // Nothing marked: the whole list. From the menu command too.
            panel.model.markAll(false)
            tool.present(for: panel)
            try expect(tool.entries.count == 3, "the whole list")
            tool.close()
            view.perform(.multiRename)
            try expect(view.multiRename.window?.isVisible == true, "⌃M opens it")
            view.multiRename.close()
            let empty = try CoverageTests.tempDir("MultiRenameEmpty")
            defer { try? FileManager.default.removeItem(at: empty) }
            panel.model.go(to: empty, visibleRows: 20)
            view.perform(.multiRename)   // nothing to rename: beep
        }
    }
}
