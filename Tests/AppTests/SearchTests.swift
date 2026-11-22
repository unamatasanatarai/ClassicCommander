import Cocoa

/// Find Files (⌥7): engine, filters, content search, duplicates and the dialog.
public enum SearchTests {
    typealias Fail = CommanderTests.TestFailure
    static func expect(_ c: @autoclosure () throws -> Bool, _ m: String) throws {
        if try !c() { throw Fail(description: m) }
    }

    /// root/
    ///   a.txt "Hello World" · b.TXT "hello" · notes.md "Zażółć gęślą jaźń" (UTF-8)
    ///   sub/ c.txt "hello world" · deep/ d.txt "x"  · .hidden.txt
    ///   other/ a.txt "Hello World"  (duplicate of root/a.txt by name+size+contents)
    static func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SearchTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: root.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("a.txt", "Hello World"), ("b.TXT", "hello"), ("notes.md", "Zażółć gęślą jaźń"),
            ("sub/c.txt", "hello world"), ("sub/deep/d.txt", "x"), ("sub/.hidden.txt", "hidden hello"),
            ("other/a.txt", "Hello World"),
        ]
        for (path, text) in files {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    static func names(_ r: FileSearch.Report) -> [String] {
        r.found.map(\.name).sorted()
    }

    static func search(_ root: URL, _ change: (inout FileSearchConfiguration) -> Void) throws -> FileSearch.Report {
        var c = FileSearchConfiguration()
        c.general.searchPaths = [root.path]
        change(&c)
        return try FileSearch(config: c, base: root).run()
    }

    static func setDate(_ url: URL, daysAgo: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)],
                                              ofItemAtPath: url.path)
    }

    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("Search names: masks, several masks, plain text = contains, | excludes, regex, Unicode forms") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            var r = try search(root) { $0.general.filenamePattern = "*.txt" }
            try expect(names(r) == [".hidden.txt", "a.txt", "a.txt", "b.TXT", "c.txt", "d.txt"], "*.txt any case: \(names(r))")
            r = try search(root) { $0.general.filenamePattern = "*.md;b*" }
            try expect(names(r) == ["b.TXT", "notes.md"], "several: \(names(r))")
            r = try search(root) { $0.general.filenamePattern = "note" }
            try expect(names(r) == ["notes.md"], "plain text is 'contains': \(names(r))")
            r = try search(root) { $0.general.filenamePattern = "*.txt | a*;.*" }
            try expect(names(r) == ["b.TXT", "c.txt", "d.txt"], "exclusions: \(names(r))")
            r = try search(root) { $0.general.filenamePattern = "^[ab]\\.txt$"; $0.general.useRegex = true }
            try expect(names(r) == ["a.txt", "a.txt", "b.TXT"], "regex: \(names(r))")
            r = try search(root) { $0.general.filenamePattern = "sub" }
            try expect(names(r) == ["sub"], "folders match by name too")

            let nfd = "z\u{0307}o\u{0301}\u{0142}w.txt"   // "żółw" with ż and ó decomposed
            try Data().write(to: root.appendingPathComponent(nfd))
            r = try search(root) { $0.general.filenamePattern = "ŻÓŁW*" }
            try expect(names(r).count == 1, "Unicode NFC mask finds NFD name, any case: \(names(r))")
        }

        testRunner("Search scope: all levels, current folder only, limited depth, several roots, selected items") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            var r = try search(root) { $0.general.filenamePattern = "*.txt"; $0.general.depth = .currentOnly }
            try expect(names(r) == ["a.txt", "b.TXT"], "current only: \(names(r))")
            r = try search(root) { $0.general.filenamePattern = "*.txt"; $0.general.depth = .limited(1) }
            try expect(names(r) == [".hidden.txt", "a.txt", "a.txt", "b.TXT", "c.txt"], "one level: \(names(r))")
            r = try search(root) {
                $0.general.filenamePattern = "*.txt"
                $0.general.searchPaths = [root.appendingPathComponent("sub/deep").path, root.appendingPathComponent("other").path]
            }
            try expect(names(r) == ["a.txt", "d.txt"], "two roots: \(names(r))")
            var c = FileSearchConfiguration()
            c.general.filenamePattern = "*"
            c.general.selectedItemsOnly = true
            r = try FileSearch(config: c, selectedItems: [root.appendingPathComponent("other"), root.appendingPathComponent("notes.md")],
                               base: root).run()
            try expect(names(r) == ["a.txt", "notes.md"], "selected only: \(names(r))")
            try expect(r.found.first { $0.name == "a.txt" }?.url.path == root.appendingPathComponent("other/a.txt").path, "path kept")
        }

        testRunner("Advanced: date between (inclusive), not older / older than, file size, all combined with AND") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            try setDate(root.appendingPathComponent("a.txt"), daysAgo: 40)
            try setDate(root.appendingPathComponent("b.TXT"), daysAgo: 3)
            let cal = Calendar.current
            var r = try search(root) {
                $0.general.filenamePattern = "*.txt"; $0.general.depth = .currentOnly
                $0.advanced.dateBetweenEnabled = true
                $0.advanced.dateFrom = cal.date(byAdding: .day, value: -3, to: Date())   // same day as b, inclusive
                $0.advanced.dateTo = Date()
            }
            try expect(names(r) == ["b.TXT"], "between: \(names(r))")
            r = try search(root) {
                $0.general.filenamePattern = "*.txt"; $0.general.depth = .currentOnly
                $0.advanced.notOlderThan = AgeFilter(enabled: true, value: 1, unit: .weeks)
            }
            try expect(names(r) == ["b.TXT"], "not older than a week: \(names(r))")
            r = try search(root) {
                $0.general.filenamePattern = "*.txt"; $0.general.depth = .currentOnly
                $0.advanced.olderThan = AgeFilter(enabled: true, value: 1, unit: .months)
            }
            try expect(names(r) == ["a.txt"], "older than a month: \(names(r))")

            r = try search(root) { $0.advanced.fileSize = SizeFilter(enabled: true, comparison: .greater, value: 10, unit: .bytes) }
            try expect(names(r) == [".hidden.txt", "a.txt", "a.txt", "c.txt", "notes.md"], "> 10 bytes, files only: \(names(r))")
            r = try search(root) { $0.advanced.fileSize = SizeFilter(enabled: true, comparison: .equal, value: 5, unit: .bytes) }
            try expect(names(r) == ["b.TXT"], "= 5 bytes: \(names(r))")
            try Data().write(to: root.appendingPathComponent("empty.txt"))
            r = try search(root) {
                $0.general.filenamePattern = "*.txt"; $0.general.depth = .currentOnly
                $0.advanced.fileSize = SizeFilter(enabled: true, comparison: .notEqual, value: 0, unit: .kilobytes)
            }
            try expect(names(r) == ["a.txt", "b.TXT"], "<> 0 KB = non-empty: \(names(r))")
            try expect(SizeFilter(value: 1.5, unit: .megabytes).bytes == 1_572_864, "1.5 MB in bytes")

            r = try search(root) {   // AND: name + size + date
                $0.general.filenamePattern = "*.txt"
                $0.advanced.fileSize = SizeFilter(enabled: true, comparison: .greater, value: 10, unit: .bytes)
                $0.advanced.notOlderThan = AgeFilter(enabled: true, value: 10, unit: .days)
            }
            try expect(names(r) == [".hidden.txt", "a.txt", "c.txt"], "combined: \(names(r))")
            r = try search(root) {   // disabled filters keep values but do nothing
                $0.advanced.fileSize = SizeFilter(enabled: false, comparison: .greater, value: 999, unit: .gigabytes)
                $0.advanced.olderThan = AgeFilter(enabled: false, value: 99, unit: .years)
            }
            try expect(r.found.count == 11, "disabled filters ignored: \(r.found.count)")
        }

        testRunner("Attributes: three states — ignored, required, excluded") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: root.appendingPathComponent("b.TXT").path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("b.TXT").path) }
            func run(_ attrs: [FileAttribute: TriState]) throws -> [String] {
                names(try search(root) { $0.general.filenamePattern = "*.txt"; $0.advanced.attributesEnabled = true; $0.advanced.attributes = attrs })
            }
            try expect(try run([:]).count == 6, "all ignored = no filter")
            try expect(try run([.hidden: .required]) == [".hidden.txt"], "hidden required")
            try expect(try run([.hidden: .excluded]).contains(".hidden.txt") == false, "hidden excluded")
            try expect(try run([.readOnly: .required]) == ["b.TXT"], "read-only required")
            try expect(try run([.readOnly: .excluded, .hidden: .excluded]).count == 4, "two exclusions")
            let dirs = names(try search(root) { $0.advanced.attributesEnabled = true; $0.advanced.attributes = [.directory: .required] })
            try expect(dirs == ["deep", "other", "sub"], "directories only: \(dirs)")
            try expect(!FileAttribute.encrypted.isAvailable, "encrypted is not offered on macOS")
        }

        testRunner("Find text: case, whole words, regex, NOT, hex, binary skipped, charsets, chunk borders, errors") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            func find(_ change: (inout ContentSearchConfiguration) -> Void) throws -> [String] {
                names(try search(root) {
                    $0.general.filenamePattern = "*"
                    $0.general.content.enabled = true
                    change(&$0.general.content)
                })
            }
            try expect(try find { $0.expression = "hello" } == [".hidden.txt", "a.txt", "a.txt", "b.TXT", "c.txt"], "any case")
            try expect(try find { $0.expression = "Hello"; $0.caseSensitive = true } == ["a.txt", "a.txt"], "case sensitive")
            try expect(try find { $0.expression = "hell"; $0.wholeWordsOnly = true }.isEmpty, "whole words")
            try expect(try find { $0.expression = "hello world"; $0.wholeWordsOnly = true } == ["a.txt", "a.txt", "c.txt"], "phrase")
            try expect(try find { $0.expression = "w.rld$"; $0.useRegex = true } == ["a.txt", "a.txt", "c.txt"], "regex")
            try expect(try find { $0.expression = "hello"; $0.invertMatch = true } == ["d.txt", "notes.md"], "NOT: \(try find { $0.expression = "hello"; $0.invertMatch = true })")
            try expect(try find { $0.expression = "gęślą" } == ["notes.md"], "UTF-8 Polish")

            var bin = Data([0x4D, 0x5A, 0x00, 0x90, 0xFF])
            bin.append(Data("hello".utf8))
            try bin.write(to: root.appendingPathComponent("prog.bin"))
            try expect(try find { $0.expression = "hello" }.contains("prog.bin") == false, "binary skipped in text mode")
            try expect(try find { $0.expression = "5a 00 90"; $0.hexadecimal = true } == ["prog.bin"], "hex finds bytes")

            // ANSI = the Windows code page of the user's language (1250 for Polish).
            let ansi = ContentCharset.ansi.stringEncoding!
            let word = ContentCharset.ansiCodePage == 1250 ? "gęślą" : "crème"
            let sample = ContentCharset.ansiCodePage == 1250 ? "Zażółć gęślą" : "Café crème"
            try sample.data(using: ansi)!.write(to: root.appendingPathComponent("ansi.txt"))
            try expect(try find { $0.expression = word.uppercased(); $0.charsets = [.ansi] } == ["ansi.txt"], "ANSI \(ContentCharset.ansiName)")
            try expect(try find { $0.expression = word.uppercased(); $0.charsets = [.utf8] }.contains("ansi.txt") == false, "not UTF-8")
            try "Unicode hello".data(using: .utf16LittleEndian)!.write(to: root.appendingPathComponent("u16.txt"))
            try expect(try find { $0.expression = "unicode HELLO"; $0.charsets = [.utf16] } == ["u16.txt"], "UTF-16 (NUL bytes allowed)")
            try expect(try find { $0.expression = "unicode HELLO"; $0.charsets = [.utf8] }.isEmpty, "UTF-16 file is binary for UTF-8")
            try Data([0x61, 0xC3, 0x28, 0x62]).write(to: root.appendingPathComponent("bad.txt"))   // invalid UTF-8
            try expect(try find { $0.expression = "b" }.contains("bad.txt"), "invalid UTF-8 does not break the search")

            // A word split across a chunk border is still found.
            var big = Data(repeating: 0x2E, count: 1000)
            big.append(Data("needle".utf8))
            try big.write(to: root.appendingPathComponent("big.log"))
            var cfg = ContentSearchConfiguration()
            cfg.expression = "needle"
            let small = try ContentMatcher(cfg, chunkSize: 1003)      // the border falls inside "needle"
            try expect(try small.search(root.appendingPathComponent("big.log")) == .contains, "across chunk border")
            try expect(small.chunkSize < 2000, "really reads in chunks")

            try Data("hello".utf8).write(to: root.appendingPathComponent("locked.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent("locked.txt").path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("locked.txt").path) }
            let r = try search(root) { $0.general.content.enabled = true; $0.general.content.expression = "hello" }
            try expect(!names(r).contains("locked.txt") && r.errors.contains { $0.contains("locked.txt") }, "unreadable reported, search continues")
            try expect(names(r).contains("a.txt"), "other results still there")
        }

        testRunner("Find text in Office files (docx/odt) when Office xml is ticked") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let parts = root.appendingPathComponent("docx-parts")
            try FileManager.default.createDirectory(at: parts.appendingPathComponent("word"), withIntermediateDirectories: true)
            try #"<?xml version="1.0"?><w:document><w:body><w:p><w:r><w:t>Quarterly &amp; Annual Report</w:t></w:r></w:p></w:body></w:document>"#
                .write(to: parts.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = parts
            zip.arguments = ["-q", "-r", root.appendingPathComponent("report.docx").path, "."]
            try zip.run(); zip.waitUntilExit()
            func find(_ charsets: [ContentCharset]) throws -> [String] {
                names(try search(root) {
                    $0.general.filenamePattern = "*.docx"
                    $0.general.content.enabled = true
                    $0.general.content.expression = "annual report"
                    $0.general.content.charsets = charsets
                })
            }
            try expect(try find([.ansi, .utf8, .officeXML]) == ["report.docx"], "found inside the docx")
            try expect(try find([.ansi, .utf8]).isEmpty, "not searched without Office xml")
        }

        testRunner("Duplicates: by name (any case), size, contents across folders; stable numbered groups") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("Hello World".utf8).write(to: root.appendingPathComponent("sub/copy-of-a.dat"))   // same contents, other name
            try Data("Hellx World".utf8).write(to: root.appendingPathComponent("sub/A.TXT.bak"))     // same size, other contents
            try Data("other".utf8).write(to: root.appendingPathComponent("sub/A.TXT"))               // same name as a.txt (case)
            func groups(_ d: DuplicateSearchConfiguration) throws -> [[String]] {
                let r = try search(root) { $0.advanced.duplicates = d }
                return (r.duplicateGroups ?? []).map { $0.items.map { $0.url.path.replacingOccurrences(of: root.path + "/", with: "") } }
            }
            var g = try groups(DuplicateSearchConfiguration(enabled: true, sameName: true, sameSize: false, sameContents: false))
            try expect(g == [["a.txt", "other/a.txt", "sub/A.TXT"]], "same name, case-insensitive: \(g)")
            g = try groups(DuplicateSearchConfiguration(enabled: true, sameName: true, sameSize: true, sameContents: false))
            try expect(g == [["a.txt", "other/a.txt"]], "name + size: \(g)")
            g = try groups(DuplicateSearchConfiguration(enabled: true, sameName: false, sameSize: false, sameContents: true))
            try expect(g.contains(["a.txt", "other/a.txt", "sub/copy-of-a.dat"]), "contents, any name: \(g)")
            try expect(!g.flatMap { $0 }.contains("sub/A.TXT.bak"), "same size but different bytes is not a duplicate")
            let r = try search(root) { $0.advanced.duplicates = DuplicateSearchConfiguration(enabled: true, sameName: false, sameSize: true, sameContents: false) }
            try expect(r.duplicateGroups!.map(\.id) == Array(1...r.duplicateGroups!.count), "ids 1…n")
            let again = try search(root) { $0.advanced.duplicates = DuplicateSearchConfiguration(enabled: true, sameName: false, sameSize: true, sameContents: false) }
            try expect(again.duplicateGroups == r.duplicateGroups, "stable groups between runs")
            try expect(DuplicateFinder.identical(root.appendingPathComponent("a.txt"), root.appendingPathComponent("other/a.txt")), "byte compare")
        }

        testRunner("Validation: bad regex, bad hex, empty text, inverted dates, no folder, nothing to compare") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            func fails(_ change: (inout FileSearchConfiguration) -> Void) -> String? {
                do { _ = try search(root, change); return nil } catch let e as SearchValidationError { return e.message } catch { return "\(error)" }
            }
            try expect(fails { $0.general.filenamePattern = "(["; $0.general.useRegex = true } != nil, "bad name regex")
            try expect(fails { $0.general.content.enabled = true; $0.general.content.expression = "4G"; $0.general.content.hexadecimal = true } != nil, "bad hex")
            try expect(fails { $0.general.content.enabled = true; $0.general.content.expression = "" } != nil, "empty find text")
            try expect(fails { $0.general.content.enabled = true; $0.general.content.expression = "(x"; $0.general.content.useRegex = true } != nil, "bad text regex")
            try expect(fails {
                $0.advanced.dateBetweenEnabled = true
                $0.advanced.dateFrom = Date(); $0.advanced.dateTo = Date().addingTimeInterval(-10 * 86_400)
            } != nil, "inverted dates")
            try expect(fails { $0.general.searchPaths = [] } != nil, "no folder")
            try expect(fails { $0.general.searchPaths = ["/definitely/not/here"] } != nil, "missing folder")
            try expect(fails { $0.advanced.duplicates = DuplicateSearchConfiguration(enabled: true, sameName: false, sameSize: false, sameContents: false) } != nil, "nothing to compare")
            try expect(fails { $0.general.selectedItemsOnly = true } != nil, "selected only with nothing selected")
            try expect(fails { $0.general.content.enabled = true; $0.general.content.expression = "x"; $0.general.content.charsets = [] } != nil, "no charset")
            let maskHint = fails { $0.general.filenamePattern = "*.iso"; $0.general.useRegex = true } ?? ""
            try expect(maskHint.contains("Untick RegEx"), "wildcard with RegEx explains itself: \(maskHint)")
            try expect(fails { $0.general.filenamePattern = "*.txt" } == nil, "valid config passes")
        }

        testRunner("Search configuration round-trips through JSON (persistence)") {
            var c = FileSearchConfiguration()
            c.general.filenamePattern = "*.jpg"
            c.general.depth = .limited(3)
            c.general.content.charsets = [.ascii, .utf16, .officeXML]
            c.advanced.fileSize = SizeFilter(enabled: true, comparison: .greaterOrEqual, value: 5, unit: .megabytes)
            c.advanced.attributes = [.hidden: .excluded, .readOnly: .required]
            c.advanced.duplicates = DuplicateSearchConfiguration(enabled: true, sameName: false, sameSize: true, sameContents: true)
            let back = try JSONDecoder().decode(FileSearchConfiguration.self, from: JSONEncoder().encode(c))
            try expect(back == c, "round trip")
        }

        testRunner("Find Files dialog (⌥7): tabs keep values, tri-state boxes, results, Go to file, Reset, remembered") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "SearchTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            try expect(KeyBindings.standard.action(for: KeyCombo(KeyCode.seven, .option)) == .findFiles, "⌥7 opens Find Files")

            let model = CommanderModel(left: PanelModel(directory: root), right: PanelModel(directory: root))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            let dialog = FindFilesWindowController(commander: view, defaults: defaults)
            dialog.runSynchronously = true
            dialog.present()
            try expect(dialog.searchIn.stringValue == root.path, "starts in the active panel's folder")
            try expect(dialog.attributeBoxes.values.allSatisfy { $0.state == .mixed }, "attributes start as 'ignore'")
            try expect(dialog.attributeBoxes[.encrypted]?.isEnabled == false, "encrypted unavailable")
            try expect(dialog.tabs.tabViewItems.map(\.label) == ["General", "Advanced", "Plugins", "Load/Save"], "TC tabs")
            try expect(dialog.charsetBoxes[.ansi]?.state == .on && dialog.charsetBoxes[.utf8]?.state == .on
                       && dialog.charsetBoxes[.utf16]?.state == .off, "default charsets ANSI + UTF8")
            try expect(dialog.archivesBox.isEnabled == false, "archives shown but not available")

            dialog.searchFor.stringValue = "*.txt"
            dialog.tabs.selectTabViewItem(at: 1)
            dialog.sizeBox.state = .on
            dialog.sizeOperator.selectItem(withTitle: ">")
            dialog.sizeField.stringValue = "10"
            dialog.sizeUnit.selectItem(withTitle: "bytes")
            dialog.attributesBox.state = .on
            dialog.attributeBoxes[.hidden]?.state = .off           // must NOT be hidden
            dialog.tabs.selectTabViewItem(at: 0)
            try expect(dialog.searchFor.stringValue == "*.txt", "General kept its value across tabs")
            dialog.startSearch()
            let found = dialog.rows.map { $0.item.url.path.replacingOccurrences(of: root.path + "/", with: "") }.sorted()
            try expect(found == ["a.txt", "other/a.txt", "sub/c.txt"], "combined General + Advanced: \(found)")
            try expect(dialog.statusLabel.stringValue == "[3 files and 0 directories found]", "status: \(dialog.statusLabel.stringValue)")
            try expect(dialog.config.advanced.attributes == [.hidden: .excluded], "tri-state read back: \(dialog.config.advanced.attributes)")

            dialog.sizeField.stringValue = "lots"
            dialog.startSearch()
            try expect(dialog.statusLabel.stringValue.contains("File size"), "bad number reported: \(dialog.statusLabel.stringValue)")
            dialog.sizeBox.state = .off
            dialog.duplicatesBox.state = .on
            dialog.sameNameBox.state = .on
            dialog.sameSizeBox.state = .on
            dialog.startSearch()
            try expect(dialog.rows.map(\.group) == [1, 1] && dialog.statusLabel.stringValue.contains("1 group"), "duplicates grouped: \(dialog.statusLabel.stringValue)")
            dialog.duplicatesBox.state = .off

            dialog.startSearch()
            let target = dialog.rows.firstIndex { $0.item.url.path.hasSuffix("sub/c.txt") }!
            try expect(dialog.table.numberOfRows == dialog.rows.count + 1, "summary line + one line per result")
            dialog.table.selectRowIndexes(IndexSet(integer: target + 1), byExtendingSelection: false)
            // "3" in the results list opens Lister on that result; n steps through the found files.
            let three = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, characters: "3", charactersIgnoringModifiers: "3", isARepeat: false,
                                         keyCode: KeyCode.three)!
            try expect(dialog.handleResultsKey(three), "3 handled in the results")
            try expect(view.listers.count == 1 && view.listers[0].url.path.hasSuffix("sub/c.txt"), "Lister on the result")
            try expect(dialog.viewButton.title == "3 View", "button shows the key: \(dialog.viewButton.title)")
            let during = FindFilesWindowController.resultButtons(hasResults: true, searching: true)
            try expect(during.view && during.goTo && !during.feed, "View and Go to file work while searching; Feed waits")
            try expect(!FindFilesWindowController.resultButtons(hasResults: false, searching: true).view, "nothing to view yet")
            view.listers[0].window?.close()
            try expect(view.listers.isEmpty, "closed")
            dialog.goToFile()
            try expect(model.left.directory.lastPathComponent == "sub" && model.left.currentEntry?.name == "c.txt", "Go to file")

            // Feed to listbox: results become the panel listing; ".." returns to the folder.
            dialog.present()
            dialog.searchFor.stringValue = "*.txt"
            dialog.tabs.selectTabViewItem(at: 1)
            dialog.attributesBox.state = .off
            dialog.startSearch()
            let fed = dialog.rows.count
            dialog.feedToListbox()
            try expect(model.left.virtualTitle?.hasPrefix("Search results") == true, "listing shown")
            try expect(model.left.entries.count == fed + 1 && model.left.entries.first?.kind == .parent, "all results + ..")
            try expect(model.left.entries.contains { $0.name == "c.txt" }, "names relative to the folder")
            model.left.focus(name: "c.txt", visibleRows: 20)
            model.left.toggleMarkAtCursor()
            try expect(model.left.operationTargets.first?.url.path.hasSuffix("sub/c.txt") == true, "marks carry real paths")
            model.left.goUp(visibleRows: 20)
            try expect(model.left.virtualTitle == nil && model.left.directory.lastPathComponent == "sub", ".. leaves the listing")

            // Load/Save: store a setup by name and load it back.
            dialog.searchFor.stringValue = "*.md"
            dialog.storeTemplate(named: "Markdown")
            dialog.searchFor.stringValue = "other"
            dialog.templateTable.selectRowIndexes(IndexSet(integer: dialog.templateNames.firstIndex(of: "Markdown")!), byExtendingSelection: false)
            dialog.loadTemplate()
            try expect(dialog.searchFor.stringValue == "*.md", "template loaded")
            dialog.searchFor.stringValue = "*.txt"
            dialog.readUI()

            let again = FindFilesWindowController(commander: view, defaults: defaults)
            try expect(again.templateNames == ["Markdown"], "templates remembered")
            try expect(again.config.general.filenamePattern == "*.txt" && again.config.advanced.attributes == [.hidden: .excluded],
                       "settings remembered")
            again.present()
            try expect(again.searchFor.objectValues.first as? String == "*.txt", "search-for history")
            try expect(again.searchIn.stringValue == root.appendingPathComponent("sub").path, "starts where the panel is now")
            again.window?.close()
            dialog.window?.close()
        }

        testRunner("Cancelling stops the walk and says so") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            var c = FileSearchConfiguration()
            c.general.searchPaths = [root.path]
            var seen = 0
            let r = try FileSearch(config: c, base: root, isCancelled: { seen >= 2 }, onFound: { _ in seen += 1 }).run()
            try expect(r.cancelled && r.found.count == 2, "stopped after 2: \(r.found.count)")
        }
    }
}
