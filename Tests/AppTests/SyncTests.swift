import Cocoa

/// Synchronize Directories: comparison, planning, execution and the dialog.
public enum SyncTests {
    typealias Fail = CommanderTests.TestFailure
    static func expect(_ c: @autoclosure () throws -> Bool, _ m: String) throws {
        if try !c() { throw Fail(description: m) }
    }

    /// left/                         right/
    ///   same.txt   "same"  t0         same.txt   "same"  t0      → =
    ///   newer.txt  "new!"  t0+100     newer.txt  "old"   t0      → →
    ///   older.txt  "old"   t0         older.txt  "new!"  t0+100  → ←
    ///   tie.txt    "aaaa"  t0         tie.txt    "bbbbb" t0      → ≠ (same date, different size)
    ///   samesize.txt "abcd" t0        samesize.txt "abce" t0     → = by date/size, ≠ by content
    ///   onlyL.txt                                                 → →
    ///                                 onlyR.txt                   → ← (or delete when asymmetric)
    ///   sub/deep.txt "d"     t0       (missing)                   → →
    ///   emptyL/ (empty folder)
    static func makePair() throws -> (URL, URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("SyncTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        let l = base.appendingPathComponent("left"), r = base.appendingPathComponent("right")
        try fm.createDirectory(at: l.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: l.appendingPathComponent("emptyL"), withIntermediateDirectories: true)
        try fm.createDirectory(at: r, withIntermediateDirectories: true)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func put(_ root: URL, _ name: String, _ text: String, _ date: Date) throws {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try put(l, "same.txt", "same", t0); try put(r, "same.txt", "same", t0)
        try put(l, "newer.txt", "new!", t0 + 100); try put(r, "newer.txt", "old", t0)
        try put(l, "older.txt", "old", t0); try put(r, "older.txt", "new!", t0 + 100)
        try put(l, "tie.txt", "aaaa", t0); try put(r, "tie.txt", "bbbbb", t0)
        try put(l, "samesize.txt", "abcd", t0); try put(r, "samesize.txt", "abce", t0)
        try put(l, "onlyL.txt", "L", t0)
        try put(r, "onlyR.txt", "R", t0)
        try put(l, "sub/deep.txt", "d", t0)
        return (l, r)
    }

    static func rowMap(_ c: SyncComparison) -> [String: SyncRow] {
        Dictionary(uniqueKeysWithValues: c.rows.map { ($0.path, $0) })
    }

    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("Synchronize dialog: only the directions shown in the comparison start ticked") {
            let now = Date()
            func info(_ p: String) -> SyncFileInfo { SyncFileInfo(url: URL(fileURLWithPath: "/tmp/x/" + p), size: 1, modified: now, isDirectory: false) }
            let toRight = SyncRow(path: "a", left: info("a"), right: nil, state: .leftOnly, action: .copyToRight, recommended: .copyToRight)
            let toLeft = SyncRow(path: "b", left: nil, right: info("b"), state: .rightOnly, action: .copyToLeft, recommended: .copyToLeft)
            let cfg = SyncConfiguration(left: URL(fileURLWithPath: "/tmp/x"), right: URL(fileURLWithPath: "/tmp/y"))
            let plan = SyncPlan(rows: [toRight, toLeft], config: cfg)
            var onlyLeft = SyncShowFilter()
            onlyLeft.copyRight = false; onlyLeft.equal = false; onlyLeft.different = false
            let sheet = SyncConfirmationController(plan: plan, config: cfg, shown: onlyLeft)
            _ = sheet.window
            try expect(sheet.leftToRightBox.state == .off && sheet.leftToRightBox.isEnabled, "→ hidden: unticked but available")
            try expect(sheet.rightToLeftBox.state == .on, "← shown: ticked")
            let all = SyncConfirmationController(plan: plan, config: cfg)
            try expect(all.leftToRightBox.state == .on && all.rightToLeftBox.state == .on, "everything shown: both ticked")
        }

        testRunner("Compare: states and recommended directions; read-only") {
            let (l, r) = try makePair()
            defer { try? FileManager.default.removeItem(at: l.deletingLastPathComponent()) }
            let before = try FileManager.default.subpathsOfDirectory(atPath: r.path).sorted()
            let c = try SyncEngine.compare(SyncConfiguration(left: l, right: r))
            let m = rowMap(c)
            try expect(m["same.txt"]?.state == .identical && m["same.txt"]?.action == SyncAction.none, "=")
            try expect(m["newer.txt"]?.action == .copyToRight && m["newer.txt"]?.state == .leftNewer, "→ newer")
            try expect(m["older.txt"]?.action == .copyToLeft && m["older.txt"]?.state == .rightNewer, "← older")
            try expect(m["tie.txt"]?.state == .different && m["tie.txt"]?.action == SyncAction.none && m["tie.txt"]?.symbol == "≠", "≠ unresolved")
            try expect(m["samesize.txt"]?.state == .identical, "same size+date counts as equal without by-content")
            try expect(m["onlyL.txt"]?.action == .copyToRight && m["onlyR.txt"]?.action == .copyToLeft, "singles")
            try expect(m["sub/deep.txt"]?.action == .copyToRight, "subdirectories")
            try expect(c.summary == "Files found: 8 (Identical: 2, Different: 3, Unique left: 2, Unique right: 1)", c.summary)
            try expect(try FileManager.default.subpathsOfDirectory(atPath: r.path).sorted() == before, "comparing changed nothing")
        }

        testRunner("Compare options: by content, ignore date, asymmetric, no subdirs, mask, empty dirs, only selected") {
            let (l, r) = try makePair()
            defer { try? FileManager.default.removeItem(at: l.deletingLastPathComponent()) }
            var cfg = SyncConfiguration(left: l, right: r)
            cfg.byContent = true
            try expect(rowMap(try SyncEngine.compare(cfg))["samesize.txt"]?.state == .different, "by content finds the difference")
            try expect(rowMap(try SyncEngine.compare(cfg))["same.txt"]?.state == .identical, "by content: equal stays equal")

            cfg = SyncConfiguration(left: l, right: r)
            cfg.ignoreDate = true
            var m = rowMap(try SyncEngine.compare(cfg))
            try expect(m["newer.txt"]?.state == .different && m["newer.txt"]?.action == SyncAction.none, "ignore date: no direction")

            cfg = SyncConfiguration(left: l, right: r)
            cfg.asymmetric = true
            m = rowMap(try SyncEngine.compare(cfg))
            try expect(m["older.txt"]?.action == .copyToRight, "asymmetric: left wins even when older")
            try expect(m["onlyR.txt"]?.action == .deleteRight, "asymmetric: right-only marked for deletion")

            cfg = SyncConfiguration(left: l, right: r)
            cfg.subdirectories = false
            try expect(rowMap(try SyncEngine.compare(cfg))["sub/deep.txt"] == nil, "no subdirs")
            cfg = SyncConfiguration(left: l, right: r)
            cfg.mask = "only*"
            try expect(Set(try SyncEngine.compare(cfg).rows.map(\.path)) == ["onlyL.txt", "onlyR.txt"], "mask")
            cfg = SyncConfiguration(left: l, right: r)
            cfg.emptyDirectories = true
            m = rowMap(try SyncEngine.compare(cfg))
            try expect(m["emptyL"]?.isDirectory == true && m["emptyL"]?.action == .copyToRight, "empty folder listed")
            cfg = SyncConfiguration(left: l, right: r)
            cfg.onlyNames = ["same.txt", "sub"]
            let onlyPaths = Set(try SyncEngine.compare(cfg).rows.map(\.path))
            try expect(onlyPaths == ["same.txt", "sub/deep.txt"], "only selected: \(onlyPaths)")

            var bad = SyncConfiguration(left: l, right: l)
            try expect((try? SyncEngine.compare(bad)) == nil, "same folder refused")
            bad = SyncConfiguration(left: l, right: l.appendingPathComponent("sub"))
            try expect((try? SyncEngine.compare(bad)) == nil, "nested folders refused")
        }

        testRunner("Show filters and changing a row's direction") {
            let (l, r) = try makePair()
            defer { try? FileManager.default.removeItem(at: l.deletingLastPathComponent()) }
            let c = try SyncEngine.compare(SyncConfiguration(left: l, right: r))
            var f = SyncShowFilter()
            try expect(c.rows.filter(f.shows).count == c.rows.count, "all shown")
            f.equal = false
            try expect(!c.rows.filter(f.shows).contains { $0.state == .identical }, "hide =")
            f = SyncShowFilter(); f.singles = false
            try expect(c.rows.filter(f.shows).allSatisfy(\.onBothSides), "duplicates only")
            f = SyncShowFilter(); f.duplicates = false
            try expect(c.rows.filter(f.shows).allSatisfy { !$0.onBothSides }, "singles only")
            f = SyncShowFilter(); f.copyRight = false; f.equal = false; f.different = false
            try expect(c.rows.filter(f.shows).allSatisfy { $0.action == .copyToLeft }, "← only")

            var row = rowMap(c)["newer.txt"]!
            try expect(SyncEngine.choices(for: row) == [.copyToRight, .copyToLeft, .none], "choices on both sides")
            row.action = SyncEngine.cycle(row)
            try expect(row.action == .copyToLeft, "click cycles to ←")
            row.action = SyncEngine.cycle(row)
            try expect(row.action == .none && row.symbol == "≠", "then off")
            let single = rowMap(c)["onlyR.txt"]!
            try expect(SyncEngine.choices(for: single) == [.copyToLeft, .deleteRight, .none], "right-only choices")
        }

        testRunner("Synchronize: copies both ways keeping dates, deletes to Trash, never overwrites a changed file") {
            let (l, r) = try makePair()
            defer { try? FileManager.default.removeItem(at: l.deletingLastPathComponent()) }
            var cfg = SyncConfiguration(left: l, right: r)
            cfg.asymmetric = false
            var c = try SyncEngine.compare(cfg)
            let plan = SyncPlan(rows: c.rows, config: cfg)
            try expect(plan.toRight.count == 3 && plan.toLeft.count == 2 && plan.deletions.isEmpty, "plan: \(plan.toRight.count)/\(plan.toLeft.count)")
            try expect(SyncPlan.bytes(plan.toRight) == 4 + 1 + 1, "bytes to copy right")

            // A file changing after the comparison is not touched.
            try Data("edited!".utf8).write(to: r.appendingPathComponent("older.txt"))
            let report = SyncExecutor.run(plan, options: SyncRunOptions())
            try expect(report.copied == 4 && report.skipped.count == 1 && report.skipped[0].hasPrefix("older.txt"), "report: \(report)")
            try expect(String(decoding: try Data(contentsOf: r.appendingPathComponent("newer.txt")), as: UTF8.self) == "new!", "→ copied")
            try expect(FileManager.default.fileExists(atPath: r.appendingPathComponent("sub/deep.txt").path), "folders created")
            try expect(FileManager.default.fileExists(atPath: l.appendingPathComponent("onlyR.txt").path), "← copied")
            c = try SyncEngine.compare(cfg)
            let m = rowMap(c)
            try expect(m["newer.txt"]?.state == .identical && m["onlyL.txt"]?.state == .identical, "dates kept: now identical")

            // Asymmetric: the right-only file goes to the Trash (stubbed here), only when allowed.
            cfg.asymmetric = true
            try Data("stray".utf8).write(to: r.appendingPathComponent("strayR.txt"))
            c = try SyncEngine.compare(cfg)
            var trashed: [String] = []
            let asym = SyncPlan(rows: c.rows, config: cfg)
            var opts = SyncRunOptions()
            opts.delete = false
            var rep = SyncExecutor.run(asym, options: opts, trash: { trashed.append($0.lastPathComponent) })
            try expect(trashed.isEmpty, "no deletion when not allowed")
            try expect(rep.deleted == 0, "nothing deleted")
            opts.delete = true
            rep = SyncExecutor.run(SyncPlan(rows: try SyncEngine.compare(cfg).rows, config: cfg), options: opts,
                                   trash: { trashed.append($0.lastPathComponent) })
            try expect(trashed == ["strayR.txt"] && rep.deleted == 1, "right-only file to the Trash: \(trashed)")

            // Overwrite off: a newer left file does not replace the right one.
            try Data("changed on the left".utf8).write(to: l.appendingPathComponent("same.txt"))
            opts.overwrite = false
            rep = SyncExecutor.run(SyncPlan(rows: try SyncEngine.compare(cfg).rows, config: cfg), options: opts,
                                   trash: { trashed.append($0.lastPathComponent) })
            try expect(rep.skipped.contains { $0.contains("not overwritten") }, "overwrite off skips replacing: \(rep)")
            try expect(String(decoding: try Data(contentsOf: r.appendingPathComponent("same.txt")), as: UTF8.self) == "same", "right untouched")
        }

        testRunner("Synchronize Directories dialog: paths from panels, compare, filters, change direction, confirm") {
            let (l, r) = try makePair()
            defer { try? FileManager.default.removeItem(at: l.deletingLastPathComponent()) }
            let model = CommanderModel(left: PanelModel(directory: l), right: PanelModel(directory: r))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            let dialog = SyncWindowController(commander: view, defaults: UserDefaults(suiteName: "SyncTests-\(UUID().uuidString)")!)
            dialog.runSynchronously = true
            dialog.present()
            try expect(dialog.leftPath.stringValue == l.path && dialog.rightPath.stringValue == r.path, "paths from panels")
            try expect(dialog.synchronizeButton.isEnabled == false, "nothing to synchronize before comparing")
            dialog.compare()
            try expect(dialog.statusLabel.stringValue.hasPrefix("Files found: 8"), "status: \(dialog.statusLabel.stringValue)")
            try expect(dialog.visibleRows.count == 8 && dialog.synchronizeButton.isEnabled, "rows shown")
            dialog.showEqual.state = .off
            dialog.filterChanged()
            try expect(dialog.visibleRows.count == 6, "= hidden: \(dialog.visibleRows.count)")
            let i = dialog.visibleRows.firstIndex { $0.path == "newer.txt" }!
            dialog.setAction(.copyToLeft, forVisible: [i])
            try expect(dialog.comparison.rows.first { $0.path == "newer.txt" }?.action == .copyToLeft, "direction changed")
            let plan = dialog.currentPlan
            try expect(plan.toLeft.contains { $0.row.path == "newer.txt" }, "plan follows the change")
            try expect(FileManager.default.fileExists(atPath: r.appendingPathComponent("onlyL.txt").path) == false, "dialog did not copy anything")
            dialog.window?.close()
        }

        testRunner("Synchronize list: ← → set the direction, Space cycles ← = delete →, columns sort, 3 shows a side-by-side diff") {
            let (l, r) = try makePair()
            defer { try? FileManager.default.removeItem(at: l.deletingLastPathComponent()) }
            try Data("one\ntwo\nthree\nfour\n".utf8).write(to: l.appendingPathComponent("text.txt"))
            try Data("one\nTWO\nthree\nfour\nfive\n".utf8).write(to: r.appendingPathComponent("text.txt"))
            let view = CommanderView(model: CommanderModel(left: PanelModel(directory: l), right: PanelModel(directory: r)))
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            let dialog = SyncWindowController(commander: view, defaults: UserDefaults(suiteName: "SyncTests-\(UUID().uuidString)")!)
            dialog.runSynchronously = true
            dialog.present()
            dialog.compare()
            func key(_ code: UInt16, _ chars: String) -> Bool {
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                return dialog.handleTableKey(e)
            }
            func select(_ path: String) { dialog.table.selectRowIndexes(IndexSet(integer: dialog.visibleRows.firstIndex { $0.path == path }!), byExtendingSelection: false) }
            func action(_ path: String) -> SyncAction? { dialog.comparison.rows.first { $0.path == path }?.action }
            select("text.txt")
            try expect(key(123, "") && action("text.txt") == .copyToLeft, "← copies to the left")
            try expect(key(124, "") && action("text.txt") == .copyToRight, "→ copies to the right")
            select("onlyL.txt")
            var seen: [SyncAction] = []
            for _ in 0..<4 { _ = key(49, " "); seen.append(action("onlyL.txt")!) }
            try expect(seen == [.none, .deleteLeft, .copyToRight, .none], "Space cycles what is possible: \(seen)")

            dialog.table.sortDescriptors = [NSSortDescriptor(key: "leftSize", ascending: false)]
            let sizes = dialog.visibleRows.compactMap { $0.left?.size }
            try expect(sizes == sizes.sorted(by: >), "sorted by left size, descending: \(sizes)")
            dialog.table.sortDescriptors = [NSSortDescriptor(key: "rightName", ascending: true)]
            let names = dialog.visibleRows.map(\.path)
            try expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "sorted by name")

            select("text.txt")
            try expect(key(20, "3"), "3 handled")
            let diffWindows = NSApp.windows.filter { $0.title.hasSuffix("Compare: text.txt") }
            guard let viewer = diffWindows.last?.windowController as? DiffWindowController else { throw Fail(description: "no diff window") }
            try expect(viewer.diff?.blocks.count == 2 && viewer.statusLabel.stringValue == "Difference 1 of 2", "diff: \(viewer.statusLabel.stringValue)")
            viewer.nextDifference()
            try expect(viewer.statusLabel.stringValue == "Difference 2 of 2", "next")
            viewer.previousDifference()
            try expect(viewer.statusLabel.stringValue == "Difference 1 of 2", "previous")
            try expect(viewer.leftText.string.contains("two") && viewer.rightText.string.contains("five"), "side by side text")
            viewer.window?.close()
            select("same.txt")
            _ = key(99, "")
            guard let same = NSApp.windows.last(where: { $0.title.hasSuffix("Compare: same.txt") })?.windowController as? DiffWindowController else {
                throw Fail(description: "no diff window for same.txt")
            }
            try expect(same.statusLabel.stringValue.hasPrefix("The files are identical"), same.statusLabel.stringValue)
            same.window?.close()
            dialog.window?.close()
        }

        testRunner("Text diff: aligned rows, changed/added/removed, blocks, binary files") {
            let d = TextDiff(left: ["a", "b", "c", "d", "e"], right: ["a", "B", "c", "e", "f"])
            try expect(d.rows.map(\.kind) == [.same, .changed, .same, .removed, .same, .added], "\(d.rows.map(\.kind))")
            try expect(d.blocks == [1, 3, 5] && d.nextBlock(after: 1) == 3 && d.previousBlock(before: 3) == 1, "blocks \(d.blocks)")
            try expect(d.rows[3].left == "d" && d.rows[3].right == nil && d.rows[5].rightNumber == 5, "alignment")
            try expect(TextDiff(left: ["x"], right: ["x"]).isIdentical && TextDiff(left: [], right: []).isIdentical, "identical")
            try expect(TextDiff(left: [], right: ["n"]).rows.map(\.kind) == [.added], "all new")
            let big = (0..<3000).map { "line \($0)" }
            var changed = big; changed[1500] = "different"; changed.insert("new", at: 10)
            let bd = TextDiff(left: big, right: changed)
            try expect(bd.blocks.count == 2 && bd.rows.filter { $0.kind != .same }.count == 2, "large files: \(bd.blocks)")
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Diff-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("a.bin"))
            try Data([0, 1, 9, 3]).write(to: dir.appendingPathComponent("b.bin"))
            guard case .binary(false, 2?) = try FileComparison.compare(dir.appendingPathComponent("a.bin"), dir.appendingPathComponent("b.bin")) else {
                throw Fail(description: "binary difference at byte 2")
            }
            try Data("x\r\ny\r\n".utf8).write(to: dir.appendingPathComponent("crlf.txt"))
            try Data("x\ny\n".utf8).write(to: dir.appendingPathComponent("lf.txt"))
            guard case .text(let t) = try FileComparison.compare(dir.appendingPathComponent("crlf.txt"), dir.appendingPathComponent("lf.txt")), t.isIdentical else {
                throw Fail(description: "line endings ignored")
            }
        }
    }
}
