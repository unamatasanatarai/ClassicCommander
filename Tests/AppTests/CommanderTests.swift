import Cocoa

public enum CommanderTests {
    struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure(description: message) }
    }

    /// Builds a temporary tree:
    ///   root/
    ///     alpha/  (contains inner.txt)
    ///     Beta/
    ///     file10.txt, file2.txt, archive.tar.gz, .hidden
    static func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("CommanderTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Beta"), withIntermediateDirectories: true)
        for name in ["file10.txt", "file2.txt", "archive.tar.gz", ".hidden", "alpha/inner.txt"] {
            try Data(repeating: 0x41, count: 2048).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    static func allViews<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        var queue = [root]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let t = v as? T { found.append(t) }
            queue.append(contentsOf: v.subviews)
        }
        return found
    }

    static func findView<T: NSView>(_ type: T.Type, in root: NSView, where match: (T) -> Bool = { _ in true }) throws -> T {
        guard let v = allViews(type, in: root).first(where: match) else { throw TestFailure(description: "no \(type) found") }
        return v
    }

    /// Spins the main run loop until `condition` holds; fails after `timeout`.
    static func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw TestFailure(description: "timed out waiting") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Lets queued main-thread work run for a moment.
    static func drainMainQueue(for seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func press(_ title: String, in root: NSView) throws {
        guard let b = allViews(NSButton.self, in: root).first(where: { $0.title == title }) else {
            throw TestFailure(description: "no button \(title)")
        }
        b.performClick(nil)
    }

    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("Saved themes with the old blue column header get Total Commander's grey header, once") {
            let suite = "HeaderMigration-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var old = Theme.classicBlue
            old.headerBackground = RGBColor(hex: "#0000A8")!
            old.headerText = RGBColor(hex: "#FFFFFF")!
            old.cursorBackground = RGBColor(hex: "#FFFFFF")!          // a user's own change stays
            defaults.set(try JSONEncoder().encode(old), forKey: "colorTheme")
            let store = SettingsStore(defaults: defaults)
            try expect(store.theme.headerBackground == Theme.classicBlue.headerBackground && store.theme.headerText == RGBColor(hex: "#000000"),
                       "header migrated")
            try expect(store.theme.cursorBackground == RGBColor(hex: "#FFFFFF"), "other colours kept")
            var blueAgain = store.settings
            blueAgain.theme.headerBackground = RGBColor(hex: "#0000A8")!
            store.save(blueAgain)
            try expect(SettingsStore(defaults: defaults).theme.headerBackground == RGBColor(hex: "#0000A8"), "a header chosen later is respected")
        }

        testRunner("Menus show real, aligned shortcuts but never take the keys (they keep reaching the panels)") {
            let delegate = AppDelegate()
            let ctrl3 = AppDelegate.keyEquivalent(for: KeyCombo(20, .control))
            try expect(ctrl3?.key == "3" && ctrl3?.modifiers == .control, "⌃3")
            let hidden = AppDelegate.keyEquivalent(for: KeyCombo(47, [.command, .shift]))
            try expect(hidden?.key == "." && hidden?.modifiers == [.command, .shift], "⇧⌘.")
            try expect(AppDelegate.keyEquivalent(for: KeyCombo(99))?.key == String(Character(UnicodeScalar(NSF3FunctionKey)!)), "F3")
            try expect(AppDelegate.keyEquivalent(for: KeyCombo(3, .control))?.key == "f", "⌃F letter")

            let menu = NSMenu(title: "View")
            menu.delegate = delegate
            var fired = false
            final class Target: NSObject { var hit: () -> Void = {}; @objc func go(_ s: Any?) { hit() } }
            let target = Target()
            target.hit = { fired = true }
            let item = NSMenuItem(title: "Sort by Name", action: #selector(Target.go(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = CommandAction.sortByName.rawValue
            menu.addItem(item)
            let view = CommanderView(model: CommanderModel(left: PanelModel(directory: FileManager.default.temporaryDirectory),
                                                           right: PanelModel(directory: FileManager.default.temporaryDirectory)))
            delegate.commanderView = view
            delegate.menuNeedsUpdate(menu)                    // the menu opens: the shortcut is shown
            try expect(item.keyEquivalent == "3" && item.keyEquivalentModifierMask == .control, "shown while open")
            delegate.menuDidClose(menu)                       // and removed when it closes
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0,
                                         context: nil, characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 20)!
            try expect(!menu.performKeyEquivalent(with: event) && !fired, "the menu does not take ⌃3")
        }

        testRunner("View menu: sort by column / unsorted / reverse, Show filters that stay, hidden files saved") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("ViewMenu-\(UUID().uuidString)").resolvingSymlinksInPath()
            defer { try? fm.removeItem(at: dir) }
            try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            for (name, size, age) in [("b.txt", 300, 3.0), ("a.md", 100, 1.0), ("c.log", 200, 2.0), ("run.sh", 10, 4.0), (".hidden", 1, 5.0)] {
                try Data(repeating: 65, count: size).write(to: dir.appendingPathComponent(name))
                try fm.setAttributes([.modificationDate: t0 + age * 1000], ofItemAtPath: dir.appendingPathComponent(name).path)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("run.sh").path)
            let view = CommanderView(model: CommanderModel(left: PanelModel(directory: dir), right: PanelModel(directory: dir)))
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            var saved: [Settings] = []
            view.onSettingsChange = { saved.append($0) }
            let panel = view.leftView.model
            func files() -> [String] { panel.realEntries.filter { $0.kind == .file }.map(\.name) }
            try expect(files() == ["a.md", "b.txt", "c.log", "run.sh"], "by name, dotfiles hidden: \(files())")
            view.perform(.sortBySize)
            try expect(files() == ["run.sh", "a.md", "c.log", "b.txt"], "by size: \(files())")
            view.perform(.reverseOrder)
            try expect(files() == ["b.txt", "c.log", "a.md", "run.sh"] && !panel.sortOrder.ascending, "reversed: \(files())")
            view.perform(.sortByDate)
            try expect(panel.sortOrder.column == .date && panel.sortOrder.ascending && files() == ["a.md", "c.log", "b.txt", "run.sh"],
                       "a new column sorts ascending: \(files())")
            view.perform(.sortByExtension)
            try expect(files() == ["c.log", "a.md", "run.sh", "b.txt"], "by extension: \(files())")
            view.perform(.sortUnsorted)
            try expect(panel.sortOrder.column == .unsorted && Set(files()) == ["a.md", "b.txt", "c.log", "run.sh"], "unsorted lists all")
            view.perform(.sortByName)

            view.perform(.showPrograms)
            try expect(files() == ["run.sh"] && panel.realEntries.contains { $0.name == "sub" }, "programs (folders stay): \(files())")
            panel.setShowFilter(.mask("*.txt *.md"), visibleRows: 20)
            try expect(files() == ["a.md", "b.txt"], "mask: \(files())")
            _ = panel.go(to: dir.appendingPathComponent("sub"), visibleRows: 20)
            _ = panel.goUp(visibleRows: 20)
            try expect(files() == ["a.md", "b.txt"], "the Show filter stays when changing folders")
            panel.focus(name: "a.md", visibleRows: 20)
            _ = panel.toggleMarkAtCursor()
            view.perform(.showPrograms)
            try expect(panel.marked.isEmpty, "marks on hidden files are dropped")
            view.perform(.showAllFiles)
            try expect(files().count == 4, "all files again")

            view.perform(.toggleHiddenFiles)
            try expect(files().contains(".hidden") && saved.last?.display.showHiddenFiles == true, "hidden files shown and saved")
            try expect(view.rightView.model.realEntries.contains { $0.name == ".hidden" }, "both panels")
            view.perform(.toggleHiddenFiles)
            try expect(!files().contains(".hidden"), "hidden again")
            view.perform(.toggleFunctionKeyBar)
            try expect(view.functionBar.isHidden && saved.last?.display.showFunctionKeyBar == false, "button bar toggled")
        }

        testRunner("Open terminal here: configurable app, {dir} as one argument, ⌃⇧T, saved with the settings") {
            let folder = URL(fileURLWithPath: "/tmp/a b/$HOME \"x\"")
            guard case let .openFolder(app, f) = TerminalLauncher.launch(appPath: "", template: "  ", folder: folder) else {
                throw TestFailure(description: "empty template opens the folder")
            }
            try expect(app.path == TerminalLauncher.defaultApp && f == folder, "Terminal.app by default")
            guard case let .run(app2, args) = TerminalLauncher.launch(appPath: "/Applications/Alacritty.app",
                                                                      template: "--working-directory {dir}", folder: folder) else {
                throw TestFailure(description: "template runs the app")
            }
            try expect(app2.path == "/Applications/Alacritty.app" && args == ["--working-directory", folder.path], "args: \(args)")
            guard case let .run(_, g) = TerminalLauncher.launch(appPath: "/x/Ghostty.app", template: "--working-directory={dir}", folder: folder) else {
                throw TestFailure(description: "ghostty")
            }
            try expect(g == ["--working-directory=" + folder.path], "folder kept in one argument (no shell): \(g)")
            try expect(TerminalLauncher.preset(forBundleID: "org.alacritty")?.arguments.contains("{dir}") == true, "Alacritty preset")
            try expect(KeyBindings.standard.action(for: KeyCombo(17, [.control, .shift])) == .openTerminal, "⌃⇧T")
            try expect(KeyBindings.standard.action(for: KeyCombo(31, [.control, .shift])) == .openInFinder, "⌃⇧O")
            let old = try JSONDecoder().decode(OperationOptions.self, from: Data(#"{"maxTransfers":2}"#.utf8))
            try expect(old.terminalApp == TerminalLauncher.defaultApp && old.terminalArguments.isEmpty && old.maxTransfers == 2, "old settings")

            let suite = "CommanderTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            let options = OptionsWindowController(store: store)
            options.showPage(1)
            try expect(options.terminalPopup.titleOfSelectedItem == "Terminal", "Terminal selected: \(options.terminalPopup.titleOfSelectedItem ?? "-")")
            options.terminalArgumentsField.stringValue = "--foo {dir}"
            options.terminalArgumentsChanged()
            try expect(store.settings.operation.terminalArguments == "--foo {dir}", "arguments saved live")
            options.useTerminal(TerminalLauncher.defaultApp)
            try expect(store.settings.operation.terminalArguments == "", "choosing a known app fills its arguments")
            options.window?.close()
        }

        testRunner("Lister hides dotfiles and sorts: .., dirs, files in Finder order") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let panel = PanelModel(directory: root)
            let names = panel.entries.map(\.name)
            try expect(names == ["..", "alpha", "Beta", "archive.tar.gz", "file2.txt", "file10.txt"],
                       "unexpected order: \(names)")
        }

        testRunner("Cursor clamps at both ends and pages by visible rows") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let panel = PanelModel(directory: root)
            panel.moveCursor(by: -1, visibleRows: 3)
            try expect(panel.cursor == 0, "cursor went above top")
            panel.moveToEnd(visibleRows: 3)
            try expect(panel.cursor == 5, "End should land on last entry, got \(panel.cursor)")
            try expect(panel.scrollTop == 3, "last entry should be visible, scrollTop \(panel.scrollTop)")
            panel.moveCursor(by: 1, visibleRows: 3)
            try expect(panel.cursor == 5, "cursor went past bottom")
            panel.pageUp(visibleRows: 3)
            try expect(panel.cursor == 3, "PageUp should move rows-1, got \(panel.cursor)")
            panel.moveToStart(visibleRows: 3)
            try expect(panel.cursor == 0 && panel.scrollTop == 0, "Home should reset to top")
        }

        testRunner("Enter descends, Backspace returns with cursor on the folder we left") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let panel = PanelModel(directory: root)
            panel.setCursor(1, visibleRows: 10) // alpha
            try expect(panel.openCurrent(visibleRows: 10) == .navigated, "should enter alpha")
            try expect(panel.directory.lastPathComponent == "alpha", "now in \(panel.directory.path)")
            try expect(panel.entries.map(\.name) == ["..", "inner.txt"], "alpha listing wrong")
            try expect(panel.cursor == 0, "cursor should start at top")
            panel.goUp(visibleRows: 10)
            try expect(panel.directory == root.standardizedFileURL, "should be back at root")
            try expect(panel.currentEntry?.name == "alpha", "cursor should be on alpha")
        }

        testRunner("Enter on .. goes up; Enter on a file reports it") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let panel = PanelModel(directory: root.appendingPathComponent("alpha"))
            panel.setCursor(1, visibleRows: 10)
            if case .file(let url) = panel.openCurrent(visibleRows: 10) {
                try expect(url.lastPathComponent == "inner.txt", "wrong file \(url)")
            } else {
                throw TestFailure(description: "expected a file result")
            }
            panel.setCursor(0, visibleRows: 10)
            try expect(panel.openCurrent(visibleRows: 10) == .navigated, ".. should navigate")
            try expect(panel.currentEntry?.name == "alpha", "cursor should be on alpha after ..")
        }

        testRunner("Root has no .. entry, shows system folders and treats /tmp link as a folder") {
            let panel = PanelModel(directory: URL(fileURLWithPath: "/"))
            try expect(panel.entries.first?.kind != .parent, "root must not list ..")
            let byName = Dictionary(panel.entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            try expect(byName["usr"]?.kind == .directory, "/usr (a hidden-flagged folder) must be listed")
            try expect(byName["tmp"]?.kind == .directory && byName["tmp"]?.isSymlink == true,
                       "/tmp is a link to a folder and must be enterable")
            try expect(panel.goUp(visibleRows: 10) == .none, "goUp at root should be a no-op")
        }

        testRunner("Unreadable directory keeps the panel where it was and reports an error") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let panel = PanelModel(directory: root)
            let missing = PanelModel(directory: root.appendingPathComponent("nope"))
            try expect(missing.errorMessage != nil, "missing directory should set an error")
            try FileManager.default.removeItem(at: root.appendingPathComponent("Beta"))
            panel.setCursor(2, visibleRows: 10) // Beta, now deleted
            if case .failed = panel.openCurrent(visibleRows: 10) {} else {
                throw TestFailure(description: "expected failure entering deleted folder")
            }
            try expect(panel.directory == root.standardizedFileURL, "panel should stay put")
            panel.reload(visibleRows: 10)
            try expect(!panel.entries.contains { $0.name == "Beta" }, "reload should drop Beta")
        }

        testRunner("Mouse wheel scroll keeps the cursor on screen") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let panel = PanelModel(directory: root)
            panel.scroll(by: 10, visibleRows: 2)
            try expect(panel.scrollTop == 4, "scrollTop should clamp to 4, got \(panel.scrollTop)")
            try expect(panel.cursor == 4, "cursor should follow into view, got \(panel.cursor)")
        }

        testRunner("Formatter matches Total Commander: names, <DIR>, sizes, dates, attrs, status line") {
            let de = EntryFormatter(locale: Locale(identifier: "de_DE"), timeZone: TimeZone(identifier: "UTC")!)
            let date = ISO8601DateFormatter().date(from: "2008-04-17T19:48:00Z")!
            let file = FileEntry(name: "archive.tar.gz", url: URL(fileURLWithPath: "/x"), kind: .file,
                                 size: 15_965, modified: date, permissions: 0o644)
            try expect(file.baseName == "archive.tar" && file.displayExtension == "gz", "ext split")
            let dot = FileEntry(name: ".zshrc", url: URL(fileURLWithPath: "/y"), kind: .file)
            try expect(dot.baseName == ".zshrc" && dot.displayExtension.isEmpty, "dotfile has no ext")
            let dir = FileEntry(name: "my.folder", url: URL(fileURLWithPath: "/z"), kind: .directory, permissions: 0o755)
            let parent = FileEntry.parent(of: URL(fileURLWithPath: "/z/q"))
            try expect(de.name(dir) == "my.folder" && de.name(file) == "archive.tar", "names without brackets")
            try expect(de.size(dir) == "<DIR>" && de.size(parent) == "<DIR>", "dir size is <DIR>")
            try expect(de.size(file) == "15.965", "locale grouping: \(de.size(file))")
            try expect(de.date(file) == "17.04.08 19:48", "date: \(de.date(file))")
            try expect(de.date(file, includeTime: false) == "17.04.08", "short date")
            try expect(de.attributes(file) == "-644" && de.attributes(parent) == "----", "attrs")
            try expect(de.compact(0) == "0 b" && de.compact(90_522) == "88,4 k", "compact: \(de.compact(90_522))")
            try expect(de.compact(82_141_904_896) == "76,5 G", "compact G: \(de.compact(82_141_904_896))")
            try expect(de.summary([parent, file, dir]) == "1 file, 1 folder · 15,6 KB",
                       "summary: \(de.summary([parent, file, dir]))")
            try expect(de.summary([file]) == "1 file · 15,6 KB", "no folder part without folders")
            try expect(de.summary([file, file], selected: (1, 0, 15_965)) == "Selected 1 of 2 files · 15,6 KB of 31,2 KB",
                       "selection: \(de.summary([file, file], selected: (1, 0, 15_965)))")
            try expect(de.readable(812) == "812 B" && de.readable(90_522) == "88,4 KB", "readable")
            try expect(de.size(2_042_908, as: .bytes) == "2.042.908 bytes" && de.size(1, as: .bytes) == "1 byte"
                       && de.size(2_042_908, as: .readable) == "1,9 MB", "size formats")
            let vol = VolumeInfo(name: "system2", available: 82_141_904_896, total: 125_735_239_680)
            try expect(de.volume(vol) == "[system2]  76,5 G of 117,1 G free", "volume: \(de.volume(vol))")
            try expect(EntryFormatter.header(for: URL(fileURLWithPath: "/Users")) == "/Users/*.*", "header")
            try expect(EntryFormatter.header(for: URL(fileURLWithPath: "/")) == "/*.*", "root header")
        }

        testRunner("Header click sorts by column, second click reverses, cursor stays on its entry") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data(count: 10).write(to: root.appendingPathComponent("small.zip"))
            let panel = PanelModel(directory: root)
            panel.setCursor(panel.entries.firstIndex { $0.name == "file2.txt" }!, visibleRows: 20)
            panel.sort(by: .size, visibleRows: 20)
            var names = panel.entries.map(\.name)
            try expect(names.first == ".." && names[1] == "alpha" && names[2] == "Beta", "dirs stay on top: \(names)")
            try expect(names[3] == "small.zip", "smallest file first: \(names)")
            try expect(panel.currentEntry?.name == "file2.txt", "cursor follows its entry")
            panel.sort(by: .size, visibleRows: 20)
            try expect(!panel.sortOrder.ascending && panel.entries.last?.name == "small.zip", "reversed")
            panel.sort(by: .ext, visibleRows: 20)
            names = panel.entries.map(\.name)
            try expect(names.suffix(4) == ["archive.tar.gz", "file2.txt", "file10.txt", "small.zip"], "by ext: \(names)")
            panel.reload(visibleRows: 20)
            try expect(panel.entries.map(\.name) == names, "reload keeps the sort order")
        }

        testRunner("Backslash button jumps to root, tilde button jumps home, downloads button jumps to Downloads") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let panel = PanelModel(directory: root)
            try expect(panel.goToRoot(visibleRows: 10) == .navigated && panel.directory.path == "/", "at root")
            try expect(panel.goToRoot(visibleRows: 10) == .none, "no-op at root")
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            try expect(panel.goHome(visibleRows: 10) == .navigated && panel.directory == home, "~ goes home")
            try expect(panel.goHome(visibleRows: 10) == .none, "no-op at home")
            let downloads = (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")).standardizedFileURL
            try expect(panel.goDownloads(visibleRows: 10) == .navigated && panel.directory == downloads, "downloads button goes to Downloads")
            try expect(panel.goDownloads(visibleRows: 10) == .none, "no-op at downloads")
        }

        testRunner("Theme: hex round trip, slot subscript, presets distinct") {
            try expect(RGBColor(hex: "#071C95")?.hex == "#071C95", "hex round trip")
            try expect(RGBColor(hex: "zzz") == nil && RGBColor(hex: "#12345") == nil, "bad hex rejected")
            var t = Theme.totalCommander
            for slot in ThemeSlot.allCases {
                t[slot] = RGBColor(hex: "#123456")!
                try expect(t[slot].hex == "#123456", "slot \(slot) settable")
            }
            try expect(Theme.totalCommander != Theme.classicBlue, "presets differ")
            try expect(Theme.totalCommander.background.hex == "#FFFFFF", "TC default is white panels")
            let c = RGBColor(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
            try expect(c.hex == "#FF8000", "NSColor to RGB: \(c.hex)")
        }

        testRunner("Contrast: yellow on white is too faint, red on light grey is fine") {
            let yellow = RGBColor(hex: "#FFFF55")!, white = RGBColor(hex: "#FFFFFF")!
            try expect(yellow.contrast(with: white) < 2.5, "yellow/white: \(yellow.contrast(with: white))")
            try expect(RGBColor(hex: "#FF0000")!.contrast(with: RGBColor(hex: "#D6D7DC")!) >= 2.5, "red/grey readable")
            try expect(abs(white.contrast(with: RGBColor(hex: "#000000")!) - 21) < 0.01, "black/white is 21")
            let fixed = yellow.readable(on: white)
            try expect(fixed.contrast(with: white) >= 3 && fixed.red == fixed.green && fixed.blue < fixed.red,
                       "yellow darkened to a readable olive: \(fixed.hex)")
            try expect(yellow.readable(on: RGBColor(hex: "#0000A8")!) == yellow, "already readable stays")
        }

        testRunner("Classic Blue is the default theme, with white text") {
            try expect(Theme.standard == .classicBlue, "default theme is Classic Blue")
            try expect(Theme.classicBlue.text.hex == "#FFFFFF", "Classic Blue text is white")
            try expect(Theme.classicBlue.background.hex == "#0000A8", "Classic Blue background is blue")
            try expect(Theme.presets.first?.name == "Classic Blue", "Classic Blue listed first")
            try expect(Theme.classicBlue.cursorBackground.hex == "#FFFFFF", "Classic Blue has a white cursor bar")
            try expect(Theme.classicBlueCyan.cursorBackground.hex == "#00A8A8", "the earlier cyan cursor stays as a preset")
            // The copy of the default kept in the repo imports as exactly the default.
            let copy = try Data(contentsOf: URL(fileURLWithPath: "docs/themes/classic-blue.json"))
            try expect(try SettingsFile.importing(copy, onto: Settings(theme: .totalCommander)).theme == .classicBlue,
                       "docs/themes/classic-blue.json is the default theme")
            try expect(DisplayOptions.standard.showFolderBrackets, "brackets on by default")
        }

        testRunner("Folder brackets: [name] and [..] when on, plain when off; files never") {
            let f = EntryFormatter(locale: Locale(identifier: "en_US_POSIX"))
            let dir = FileEntry(name: "media", url: URL(fileURLWithPath: "/m"), kind: .directory)
            let parent = FileEntry.parent(of: URL(fileURLWithPath: "/a/b"))
            let file = FileEntry(name: "a.txt", url: URL(fileURLWithPath: "/a.txt"), kind: .file)
            try expect(f.name(dir, folderBrackets: true) == "[media]", "dir bracketed")
            try expect(f.name(parent, folderBrackets: true) == "[..]", "parent bracketed")
            try expect(f.name(file, folderBrackets: true) == "a", "file not bracketed")
            try expect(f.name(dir, folderBrackets: false) == "media", "dir plain")
        }

        testRunner("SettingsStore defaults, persists every section, notifies once, survives bad data") {
            let suite = "CommanderTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            try expect(store.settings == .standard, "defaults")
            try expect(store.operation.spaceCalculatesFolderSize, "folder size on by default")
            try expect(store.operation.spaceMovesCursorDown, "Space moves down by default")
            var notified = 0
            let token = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: store, queue: nil) { _ in notified += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            var custom = Settings.standard
            custom.theme = .totalCommander
            custom.display.showFolderBrackets = false
            custom.operation = OperationOptions(spaceCalculatesFolderSize: true, spaceMovesCursorDown: true)
            custom.keys.add(KeyCombo(KeyCode.space, .shift), to: .goHome)
            store.save(custom)
            store.save(custom)
            try expect(notified == 1, "one notification per real change, got \(notified)")
            try expect(SettingsStore(defaults: defaults).settings == custom, "reloaded from defaults")
            defaults.set(Data("garbage".utf8), forKey: "colorTheme")
            let partial = SettingsStore(defaults: defaults)
            try expect(partial.theme == .classicBlue && partial.operation == custom.operation,
                       "a bad section resets only itself")
        }

        testRunner("Saved theme from before the mark colour existed keeps its colours") {
            let old = ##"{"text":"#FFFFFF","cursorBackground":"#FFFFFF","headerText":"#FFFFFF","background":"#0000A8"}"##
            let theme = try JSONDecoder().decode(Theme.self, from: Data(old.utf8))
            try expect(theme.cursorBackground.hex == "#FFFFFF" && theme.headerText.hex == "#FFFFFF", "kept custom colours")
            try expect(theme.markText == Theme.standard.markText, "missing colour taken from the default")
            let round = try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(Theme.totalCommander))
            try expect(round == .totalCommander, "round trip")
        }

        testRunner("Options dialog is live: each change is saved at once; Cancel restores; OK keeps; no Apply") {
            let suite = "CommanderTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            var notified = 0
            let token = NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: store, queue: nil) { _ in notified += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            let options = OptionsWindowController(store: store)
            let root = options.window!.contentView!
            try expect(options.working == store.settings && notified == 0, "opening saves nothing")
            try expect(options.visiblePageTitle == "Display", "opens on Display")
            for (i, title) in ["Operation", "Quick Search", "FTP", "Color", "Shortcuts"].enumerated() {
                options.showPage(i + 1)
                try expect(options.visiblePageTitle == title, "page \(title)")
            }
            try expect(allViews(NSButton.self, in: root).first { $0.title == "Apply" } == nil, "no Apply button")

            let brackets = try findView(NSButton.self, in: root, where: { $0.title.contains("square brackets") })
            let sizes = try findView(NSButton.self, in: root, where: { $0.title.contains("size of folders") })
            let down = try findView(NSButton.self, in: root, where: { $0.title.contains("cursor down") })
            try expect(brackets.state == .on && sizes.state == .on && down.state == .on, "checkboxes reflect defaults")
            brackets.performClick(nil)
            try expect(!store.display.showFolderBrackets && notified == 1, "checkbox saved immediately")

            let popup = try findView(NSPopUpButton.self, in: root, where: { $0.itemTitles.contains("Classic Blue") })
            try expect(popup.itemTitles == ["Classic Blue", "Classic Blue (cyan cursor)", "Total Commander"], "presets: \(popup.itemTitles)")
            popup.selectItem(withTitle: "Total Commander")
            popup.sendAction(popup.action, to: popup.target)
            try expect(store.theme == .totalCommander, "preset applied immediately")
            let wells = allViews(NSColorWell.self, in: root)
            try expect(wells.count == ThemeSlot.allCases.count, "one colour well per slot")
            wells[0].color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            wells[0].sendAction(wells[0].action, to: wells[0].target)
            try expect(store.theme.text.hex == "#FF0000" && popup.titleOfSelectedItem == "Custom", "colour applied immediately")

            try press("Cancel", in: root)
            try expect(store.settings == .standard, "Cancel restores what was there when the dialog opened")

            options.present()
            try expect(brackets.state == .on && sizes.state == .on, "reopened on the restored settings")
            sizes.performClick(nil)
            down.performClick(nil)
            let labels = CommandAction.allCases.map(\.label)
            try expect(labels.allSatisfy { !$0.isEmpty } && Set(labels).count == labels.count, "every action has a unique non-empty label")

            try press("OK", in: root)
            try expect(store.operation == OperationOptions(spaceCalculatesFolderSize: false, spaceMovesCursorDown: false),
                       "OK keeps the live changes")
            options.present()
            sizes.performClick(nil)
            options.window?.performClose(nil)
            try expect(store.operation.spaceCalculatesFolderSize, "closing the window keeps changes too")
            options.present()
            brackets.performClick(nil)
            try press("Cancel", in: root)
            try expect(store.operation.spaceCalculatesFolderSize && store.display.showFolderBrackets,
                       "Cancel only undoes this session's changes")
        }

        testRunner("Shortcuts page: recording moves a key between actions; menu keys refused; Esc cancels; OK saves") {
            let suite = "CommanderTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            let options = OptionsWindowController(store: store)
            let root = options.window!.contentView!
            let page = try findView(ShortcutsPage.self, in: root)
            let table = try findView(NSTableView.self, in: page)
            try expect(table.numberOfRows == CommandAction.allCases.count, "one row per action")

            page.select(.goHome)
            page.addPressed()
            try expect(page.recordingAction == .goHome, "recording")
            page.record(KeyCombo(KeyCode.space))
            try expect(page.recordingAction == nil, "recording ends")
            try expect(store.keys.action(for: KeyCombo(KeyCode.space)) == .goHome, "Space now goes home (saved live)")
            try expect(options.working.keys.keys(for: .toggleSelection).isEmpty, "and left Select")
            try expect(page.note.stringValue.contains("moved here"), "note explains: \(page.note.stringValue)")

            page.addPressed()
            page.record(KeyCombo(KeyCode.q, .command))
            try expect(options.working.keys.action(for: KeyCombo(KeyCode.q, .command)) == nil, "⌘Q refused")
            page.addPressed()
            page.record(KeyCombo(KeyCode.escape))
            try expect(options.working.keys.keys(for: .goHome) == [KeyCombo(KeyCode.space)], "Esc cancels")

            // Right-click context menu on ShortcutsTableView (row with multiple shortcuts + out-of-bounds)
            table.layoutSubtreeIfNeeded()
            if let multiRow = page.actions.firstIndex(of: .parentFolder) {
                let rowRect = table.rect(ofRow: multiRow)
                let winPt = table.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
                let menuEvt = NSEvent.mouseEvent(
                    with: .rightMouseDown,
                    location: winPt,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: options.window?.windowNumber ?? 0,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )!
                let ctxMenu = table.menu(for: menuEvt)
                try expect(ctxMenu?.items.contains(where: { $0.title == "Add Shortcut…" }) == true, "context menu has Add Shortcut")
                try expect(ctxMenu?.items.contains(where: { $0.title.hasPrefix("Remove All") }) == true, "context menu has Remove All")
            }
            let outsideEvt = NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: NSPoint(x: -50, y: -50),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: options.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
            _ = table.menu(for: outsideEvt)

            let labels = CommandAction.allCases.map(\.label)
            try expect(labels.allSatisfy { !$0.isEmpty } && Set(labels).count == labels.count, "every action has a unique non-empty label")

            try press("OK", in: root)
            try expect(store.keys.action(for: KeyCombo(KeyCode.space)) == .goHome, "kept after OK")
            options.present()
            try press("Reset to Defaults", in: root)
            try press("OK", in: root)
            try expect(store.keys == .standard, "reset saved")
            options.window?.close()
        }

        testRunner("Key bindings: defaults, moving, removing, upgrade-safe decoding, display names") {
            var keys = KeyBindings.standard
            try expect(keys.action(for: KeyCombo(KeyCode.one, .option)) == .leftLocationMenu, "⌥1 left menu")
            try expect(keys.action(for: KeyCombo(KeyCode.two, .option)) == .rightLocationMenu, "⌥2 right menu")
            try expect(keys.action(for: KeyCombo(KeyCode.space)) == .toggleSelection, "Space selects")
            try expect(keys.action(for: KeyCombo(KeyCode.tab, .shift)) == .switchPanel, "⇧⇥ switches too")
            try expect(keys.action(for: KeyCombo(KeyCode.down, .command)) == .open, "⌘↓ opens")
            try expect(keys.action(for: KeyCombo(KeyCode.two)) == .refresh, "2 refreshes")
            try expect(keys.action(for: KeyCombo(21)) == nil, "plain 4 unbound")
            try expect(keys.add(KeyCombo(KeyCode.home), to: .goHome) == .firstItem, "reports previous owner")
            try expect(keys.keys(for: .firstItem).isEmpty && keys.action(for: KeyCombo(KeyCode.home)) == .goHome, "moved")
            keys.remove(KeyCombo(KeyCode.home), from: .goHome)
            try expect(keys.action(for: KeyCombo(KeyCode.home)) == nil, "removed")
            let partial = #"{"goHome":[{"keyCode":4,"modifiers":9}],"someFutureAction":[]}"#
            let decoded = try JSONDecoder().decode(KeyBindings.self, from: Data(partial.utf8))
            try expect(decoded.keys(for: .goHome) == [KeyCombo(4, [.command, .control])], "saved action kept")
            try expect(decoded.keys(for: .cursorUp) == KeyBindings.standard.keys(for: .cursorUp), "missing action gets default")
            let round = try JSONDecoder().decode(KeyBindings.self, from: JSONEncoder().encode(keys))
            try expect(round == keys, "round trip")
            try expect(KeyCombo(KeyCode.two, .option).displayName == "⌥2", "⌥2 name")
            try expect(KeyCombo(KeyCode.up, .command).displayName == "⌘↑", "⌘↑ name")
            try expect(KeyCombo(KeyCode.space).displayName == "Space", "Space name")
            try expect(KeyCombo(KeyCode.q, .command).isReservedByMenu, "⌘Q is reserved by menu")
            try expect(!KeyCombo(KeyCode.w, .command).isReservedByMenu, "⌘W can be used for closeTab")
        }

        testRunner("Marking: Space toggles, .. cannot be marked, totals and status line, reload keeps, cd clears") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let panel = PanelModel(directory: root)
            try expect(panel.toggleMarkAtCursor() == nil && panel.marked.isEmpty, ".. is not markable")
            panel.setCursor(panel.entries.firstIndex { $0.name == "file2.txt" }!, visibleRows: 20)
            panel.toggleMarkAtCursor()
            panel.setCursor(1, visibleRows: 20) // alpha
            panel.toggleMarkAtCursor()
            try expect(panel.marked == ["file2.txt", "alpha"], "marked: \(panel.marked)")
            var t = panel.selectionTotals
            try expect(t.files == 1 && t.dirs == 1 && t.bytes == 2048, "totals without folder size")
            panel.setFolderSize(2048, for: "alpha", in: root)
            t = panel.selectionTotals
            try expect(t.bytes == 4096, "folder size counts once known")
            let f = EntryFormatter(locale: Locale(identifier: "de_DE"))
            try expect(f.summary(panel.realEntries, selected: t) == "Selected 1 of 3 files, 1 of 2 folders · 4,0 KB of 6,0 KB",
                       "status: \(f.summary(panel.realEntries, selected: t))")
            try expect(f.size(panel.entries[1], folderSize: panel.folderSize(for: panel.entries[1])) == "2.048", "size shown")
            panel.toggleMarkAtCursor()
            try expect(panel.marked == ["file2.txt"], "toggled off")
            try FileManager.default.removeItem(at: root.appendingPathComponent("file2.txt"))
            panel.reload(visibleRows: 20)
            try expect(panel.marked.isEmpty && panel.folderSize(for: panel.entries[1]) == 2048, "reload drops gone marks, keeps sizes")
            panel.toggleMarkAtCursor()
            panel.openCurrent(visibleRows: 20)
            try expect(panel.marked.isEmpty && panel.folderSizes.isEmpty, "entering a folder clears marks and sizes")
        }

        testRunner("Folder sizer adds up nested files and does not follow links") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alpha/loop"), withDestinationURL: root)
            try expect(FolderSizer.totalSize(of: root.appendingPathComponent("alpha")) == 2048, "alpha holds one 2 KB file")
            try expect(FolderSizer.totalSize(of: root) == 5 * 2048, "whole tree incl. dotfile, link not followed: \(FolderSizer.totalSize(of: root))")
        }

        testRunner("Space in the commander: by default marks, sizes the folder's contents and moves down") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let model = CommanderModel(left: PanelModel(directory: root), right: PanelModel(directory: root))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            let f = EntryFormatter(locale: Locale(identifier: "de_DE"))
            let alpha = model.left.entries[1]
            try expect(f.size(alpha, folderSize: model.left.folderSize(for: alpha)) == "<DIR>", "<DIR> before Space")
            model.left.setCursor(1, visibleRows: 20) // alpha
            view.perform(.toggleSelection)
            try expect(model.left.marked == ["alpha"] && model.left.cursor == 2, "marked and moved down")
            try waitFor { model.left.folderSizes["alpha"] != nil }
            try expect(f.size(alpha, folderSize: model.left.folderSize(for: alpha)) == "2.048", "contents size after Space")
            try expect(model.left.selectionTotals.bytes == 2048, "selection counts the folder's contents")

            var s = Settings.standard
            s.operation = OperationOptions(spaceCalculatesFolderSize: false, spaceMovesCursorDown: false)
            view.settings = s
            view.perform(.toggleSelection) // Beta
            try expect(model.left.marked == ["alpha", "Beta"] && model.left.cursor == 2, "options off: no move")
            drainMainQueue()
            try expect(model.left.folderSizes["Beta"] == nil, "options off: no size")
        }

        testRunner("⌥2 opens the right panel's location menu: cursor folder, home, drives; choosing jumps and focuses") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let alpha = root.appendingPathComponent("alpha")
            let model = CommanderModel(left: PanelModel(directory: alpha), right: PanelModel(directory: URL(fileURLWithPath: "/")))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            view.drivesProvider = { [.drive(name: "Disk", url: root, available: 1024, total: 2048)] }
            var shown: (NSMenu, PanelView)?
            view.presentMenu = { shown = ($0, $1) }

            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "™", charactersIgnoringModifiers: "2",
                                         isARepeat: false, keyCode: KeyCode.two)!
            view.keyDown(with: event)
            guard let (menu, panel) = shown else { throw TestFailure(description: "no menu shown") }
            try expect(panel === view.rightView, "menu belongs to the right panel")
            let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            try expect(titles.count == 3, "three entries: \(titles)")
            try expect(titles[0].contains(alpha.path), "1: folder of the cursor panel: \(titles[0])")
            try expect(titles[1].hasPrefix("Home"), "2: home: \(titles[1])")
            try expect(titles[2].hasPrefix("[Disk]"), "3: drives: \(titles[2])")
            try expect(menu.items[0].keyEquivalent == "1" && menu.items[1].keyEquivalent == "2", "digits pick entries")

            let first = menu.items[0]
            _ = first.target?.perform(first.action, with: first)
            try expect(model.right.directory == alpha.standardizedFileURL, "right panel jumped to the cursor folder")
            try expect(model.activeSide == .right, "and has the focus")

            view.showLocationMenu(for: .left)
            let home = shown!.0.items[1]
            _ = home.target?.perform(home.action, with: home)
            try expect(model.left.directory == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL, "left went home")
            try expect(model.activeSide == .left, "left focused")
        }

        testRunner("Transfer plan: into a folder, rename a single item, several items create the folder") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let a = root.appendingPathComponent("file2.txt"), b = root.appendingPathComponent("file10.txt")
            var plan = TransferTarget.plan(sources: [a], target: root.path + "/alpha/", base: root)
            try expect(plan.pairs.first?.1.path == root.appendingPathComponent("alpha/file2.txt").path && plan.createFolder == nil, "into folder")
            plan = TransferTarget.plan(sources: [a], target: "renamed.txt", base: root)
            try expect(plan.pairs.first?.1.lastPathComponent == "renamed.txt", "relative rename")
            plan = TransferTarget.plan(sources: [a, b], target: "newdir", base: root)
            try expect(plan.createFolder?.lastPathComponent == "newdir" && plan.pairs.count == 2, "creates folder for several")
            plan = TransferTarget.plan(sources: [a], target: root.path + "/alpha/*.*", base: root)
            try expect(plan.pairs.first?.1.deletingLastPathComponent().lastPathComponent == "alpha", "*.* suffix ignored")
        }

        /// A local copy or move through the queue, as 5 / 6 do it (synchronously).
        func runLocal(_ sources: [URL], to target: String, base: URL, move: Bool,
                      resolve: @escaping (TransferConflict) -> ConflictDecision) throws -> TransferJob {
            let (pairs, create) = TransferTarget.plan(sources: sources, target: target, base: base)
            let planned = pairs.map { pair -> (TransferPlanner.Source, TransferLocation) in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: pair.0.path, isDirectory: &isDir)
                return (TransferPlanner.Source(location: .local(pair.0), isFolder: isDir.boolValue, size: 0,
                                               modified: (try? pair.0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate),
                        .local(pair.1))
            }
            let plan = try TransferPlanner.plan(planned, move: move, mask: nil)
            var items = plan.items
            if let folder = create { items.insert(TransferItem(source: .local(folder), destination: .local(folder), size: 0, isFolder: true), at: 0) }
            let manager = TransferManager()
            manager.resolveConflict = resolve
            let job = TransferJob(title: "test", items: items, isMove: move, sourceFoldersToRemove: move ? plan.foldersToRemove : [])
            manager.enqueue(job, synchronously: true)
            return job
        }

        testRunner("Copy: conflicts ask, Replace all is remembered, folders merge, cannot copy into itself") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = FileManager.default
            let dest = root.appendingPathComponent("Beta")
            try Data("old".utf8).write(to: dest.appendingPathComponent("file2.txt"))
            try Data("old".utf8).write(to: dest.appendingPathComponent("file10.txt"))
            var asked: [TransferConflict] = []
            var job = try runLocal([root.appendingPathComponent("file2.txt"), root.appendingPathComponent("file10.txt"),
                                    root.appendingPathComponent("archive.tar.gz")], to: dest.path, base: root, move: false) { c in
                asked.append(c)
                return .replaceAll
            }
            try expect(job.doneCount == 3 && job.failedCount == 0, "results: \(job.results)")
            try expect(asked.count == 1, "asked once, then applied to all (asked \(asked.count))")
            try expect(asked.first?.targetSize == 3 && asked.first?.sourceSize == 0 && asked.first?.target.name == "file2.txt",
                       "the dialog gets both sides")
            let overwritten = try Data(contentsOf: dest.appendingPathComponent("file2.txt"))
            try expect(overwritten.count == 2048, "overwritten")
            try expect(fm.fileExists(atPath: root.appendingPathComponent("file2.txt").path), "copy keeps source")

            try fm.createDirectory(at: dest.appendingPathComponent("alpha"), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: dest.appendingPathComponent("alpha/mine.txt"))
            try Data("old".utf8).write(to: dest.appendingPathComponent("alpha/inner.txt"))
            job = try runLocal([root.appendingPathComponent("alpha")], to: dest.path, base: root, move: false) { _ in .skip }
            try expect(fm.fileExists(atPath: dest.appendingPathComponent("alpha/mine.txt").path), "merge keeps existing files")
            try expect((try String(contentsOf: dest.appendingPathComponent("alpha/inner.txt"))) == "old", "skipped: kept")
            try expect(job.results.contains(.skipped("the target exists")), "skip reported")

            try expect(TransferTarget.problem(root.appendingPathComponent("alpha"), root.appendingPathComponent("alpha/sub/alpha"), move: false) != nil,
                       "into itself is refused")
            try expect(TransferTarget.problem(root.appendingPathComponent("a"), root.appendingPathComponent("a"), move: true) != nil, "onto itself")
            try expect(TransferTarget.problem(root.appendingPathComponent("a"), root.appendingPathComponent("b"), move: true) == nil, "fine")

            job = try runLocal([root.appendingPathComponent("file2.txt")], to: dest.path, base: root, move: false) { _ in .cancel }
            try expect(job.state == .cancelled && job.doneCount == 0, "cancel stops")

            // Rename: the copy gets a new name next to the existing file.
            job = try runLocal([root.appendingPathComponent("file10.txt")], to: dest.path, base: root, move: false) { c in
                c.target.name == "file10.txt" ? .rename("file10 (2).txt") : .skip
            }
            try expect(fm.fileExists(atPath: dest.appendingPathComponent("file10 (2).txt").path) && job.doneCount == 1, "renamed copy")

            // Replace all older: only the older targets are replaced.
            let older = dest.appendingPathComponent("file2.txt"), newer = dest.appendingPathComponent("file10.txt")
            try Data("o".utf8).write(to: older)
            try Data("n".utf8).write(to: newer)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: older.path)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: newer.path)
            job = try runLocal([root.appendingPathComponent("file2.txt"), root.appendingPathComponent("file10.txt")],
                               to: dest.path, base: root, move: false) { _ in .replaceAllOlder }
            try expect(try Data(contentsOf: older).count == 2048 && (try String(contentsOf: newer)) == "n", "older replaced, newer kept")
        }

        testRunner("Move: renames in place, folders in one step, merged source folder disappears, verify") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = FileManager.default
            var job = try runLocal([root.appendingPathComponent("file2.txt")], to: "two.txt", base: root, move: true) { _ in .skip }
            try expect(job.doneCount == 1 && fm.fileExists(atPath: root.appendingPathComponent("two.txt").path)
                       && !fm.fileExists(atPath: root.appendingPathComponent("file2.txt").path), "renamed")
            job = try runLocal([root.appendingPathComponent("alpha")], to: root.path + "/Moved", base: root, move: true) { _ in .skip }
            try expect(job.items.count == 1 && job.items[0].isWholeFolder, "a folder on the same disk moves in one step")
            try expect(fm.fileExists(atPath: root.appendingPathComponent("Moved/inner.txt").path)
                       && !fm.fileExists(atPath: root.appendingPathComponent("Moved/alpha").path), "moved whole (new name)")
            try fm.createDirectory(at: root.appendingPathComponent("Beta/Moved"), withIntermediateDirectories: true)
            job = try runLocal([root.appendingPathComponent("Moved")], to: root.path + "/Beta", base: root, move: true) { _ in .skip }
            try expect(fm.fileExists(atPath: root.appendingPathComponent("Beta/Moved/inner.txt").path), "merged in")
            try expect(!fm.fileExists(atPath: root.appendingPathComponent("Moved").path), "emptied source removed")

            // Verify: a copy is read back; a move copies, verifies, then removes the original.
            let manager = TransferManager()
            let a = root.appendingPathComponent("two.txt"), b = root.appendingPathComponent("Beta/two.txt")
            let verified = TransferJob(title: "v", items: [TransferItem(source: .local(a), destination: .local(b), size: 2048, isFolder: false)], isMove: true)
            verified.verify = true
            manager.enqueue(verified, synchronously: true)
            try expect(verified.doneCount == 1 && fm.fileExists(atPath: b.path) && !fm.fileExists(atPath: a.path), "verified move")
            try Data("different".utf8).write(to: a)
            let item = TransferItem(source: .local(a), destination: .local(b), size: 9, isFolder: false)
            do {
                try manager.verify(item, at: .local(b))
                throw TestFailure(description: "a different file must fail verification")
            } catch FTPError.verificationFailed {}
            try manager.verify(TransferItem(source: .remote(RemoteSession(client: FTPClient(profile: FTPProfile(), password: nil)), "/x"),
                                            destination: .local(b), size: 2048, isFolder: false), at: .local(b))
        }

        testRunner("Transfer planner: only files of type, folders that hold them, stats") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root, create: true)
            defer { try? FileManager.default.removeItem(at: target) }
            let sources = [TransferPlanner.Source(location: .local(root.appendingPathComponent("alpha")), isFolder: true, size: 0),
                           TransferPlanner.Source(location: .local(root.appendingPathComponent("Beta")), isFolder: true, size: 0),
                           TransferPlanner.Source(location: .local(root.appendingPathComponent("archive.tar.gz")), isFolder: false, size: 2048)]
            let plan = try TransferPlanner.plan(sources, into: .local(target), mask: FileMask("*.txt"))
            try expect(plan.items.map { $0.destination.name } == ["alpha", "inner.txt"], "only .txt and its folder: \(plan.items.map { $0.destination.name })")
            try expect(plan.fileCount == 1 && plan.bytes == 2048, "counts")
            let entries = PanelModel(directory: root).entries.filter { $0.kind != .parent }
            let all = TransferStats.count(entries, mask: nil, cancel: CancelFlag())
            try expect(all.files == 4 && all.folders == 2 && all.bytes == 4 * 2048 && all.complete, "stats: \(all)")
            let txt = TransferStats.count(entries, mask: FileMask("*.txt"), cancel: CancelFlag())
            try expect(txt.files == 3, "masked stats: \(txt)")
            let remote = TransferStats.count([FileEntry(name: "d", url: URL(string: "ccftp://s/d")!, kind: .directory)], mask: nil, cancel: CancelFlag())
            try expect(!remote.complete && remote.folders == 1, "server folders aren't walked")
            try expect(TransferAnswer(target: "/x", mask: "  ").fileMask == nil && TransferAnswer(target: "/x", mask: "*.c").fileMask != nil, "mask")
        }

        testRunner("Commander 5/6/7/8: copy to the other panel, move, new folder, delete to Trash") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = FileManager.default
            let beta = root.appendingPathComponent("Beta")
            let model = CommanderModel(left: PanelModel(directory: root), right: PanelModel(directory: beta))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            let prompts = StubPrompts()
            view.fileCommands.prompts = prompts
            view.fileCommands.runInBackground = false
            var trashed: [String] = []
            view.fileCommands.trash = { urls in   // never touch the real Trash from tests
                var r = OperationReport()
                for u in urls { try? fm.removeItem(at: u); trashed.append(u.lastPathComponent); r.done += 1 }
                return r
            }
            let keys = KeyBindings.standard
            try expect(keys.action(for: KeyCombo(KeyCode.five)) == .copy && keys.action(for: KeyCombo(KeyCode.f5)) == .copy, "5/F5")
            try expect(keys.action(for: KeyCombo(KeyCode.six)) == .move && keys.action(for: KeyCombo(KeyCode.seven)) == .newFolder
                       && keys.action(for: KeyCombo(KeyCode.eight)) == .delete, "6/7/8")

            // 5 with two marked files: copies both into the right panel's folder.
            for name in ["file2.txt", "file10.txt"] {
                model.left.focus(name: name, visibleRows: 20)
                model.left.toggleMarkAtCursor()
            }
            view.perform(.copy)
            try expect(prompts.lastMessage == "Copy 2 files to:" && prompts.lastDefault == beta.path + "/", "dialog: \(prompts.lastMessage) / \(prompts.lastDefault)")
            try expect(fm.fileExists(atPath: beta.appendingPathComponent("file2.txt").path)
                       && fm.fileExists(atPath: beta.appendingPathComponent("file10.txt").path), "copied")
            try expect(model.left.marked.isEmpty, "marks cleared after success")
            try expect(model.right.entries.contains { $0.name == "file2.txt" }, "other panel reloaded")

            // 6 on the cursor item with a typed name: rename.
            model.left.focus(name: "archive.tar.gz", visibleRows: 20)
            prompts.answer = "packed.tgz"
            view.perform(.move)
            try expect(fm.fileExists(atPath: root.appendingPathComponent("packed.tgz").path)
                       && !fm.fileExists(atPath: root.appendingPathComponent("archive.tar.gz").path), "renamed")

            // 7: new folder, cursor lands on it.
            prompts.answer = "Fresh"
            view.perform(.newFolder)
            try expect(fm.fileExists(atPath: root.appendingPathComponent("Fresh").path), "folder created")
            try expect(model.left.currentEntry?.name == "Fresh", "cursor on new folder")

            // 8: confirmation declined keeps the file; accepted moves it to the Trash.
            model.left.focus(name: "file10.txt", visibleRows: 20)
            prompts.confirmAnswer = false
            view.perform(.delete)
            try expect(fm.fileExists(atPath: root.appendingPathComponent("file10.txt").path), "declined: kept")
            prompts.confirmAnswer = true
            view.perform(.delete)
            try expect(prompts.lastMessage == "Move “file10.txt” to the Trash?", "confirm text: \(prompts.lastMessage)")
            try expect(trashed == ["file10.txt"] && !fm.fileExists(atPath: root.appendingPathComponent("file10.txt").path), "trashed")
            try expect(!model.left.entries.contains { $0.name == "file10.txt" }, "panel reloaded")
            try expect(prompts.problems.isEmpty, "no problems: \(prompts.problems)")

            // Nothing to act on (cursor on ".."): no dialog.
            model.left.moveToStart(visibleRows: 20)
            prompts.lastMessage = ""
            view.perform(.copy)
            try expect(prompts.lastMessage.isEmpty, "no dialog on ..")
        }

        testRunner("Function key bar: titles follow bindings, buttons run actions, option hides it, all five columns") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let model = CommanderModel(left: PanelModel(directory: root), right: PanelModel(directory: root))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            try expect(!view.functionBar.isHidden && view.functionBar.frame.height == FunctionKeyBar.height, "bar shown")
            try expect(view.leftView.frame.maxY <= view.functionBar.frame.minY, "panels sit above the bar")
            try expect(FunctionKeyBar.actions.map { view.functionBar.title(for: $0) } == ["3 View", "5 Copy", "6 Move", "7 NewFolder", "8 Delete"],
                       "titles: \(FunctionKeyBar.actions.map { view.functionBar.title(for: $0) })")
            var s = Settings.standard
            s.keys.remove(KeyCombo(KeyCode.five), from: .copy)
            s.display.showFunctionKeyBar = false
            view.settings = s
            view.layout()
            try expect(view.functionBar.title(for: .copy) == "F5 Copy", "title follows bindings")
            try expect(view.functionBar.isHidden && view.leftView.frame.maxY >= 590, "hidden bar gives the space back")
            let prompts = StubPrompts()
            view.fileCommands.prompts = prompts
            view.functionBar.onAction?(.newFolder)
            try expect(prompts.lastMessage == "New folder (directory):", "button runs the action")

            let narrow = PanelView(model: PanelModel(directory: root))
            narrow.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
            let image = narrow.bitmapImageRepForCachingDisplay(in: narrow.bounds)!
            narrow.cacheDisplay(in: narrow.bounds, to: image) // draws without trapping at narrow widths
        }

        testRunner("Double press gate: second press within the interval passes, slow or third presses do not") {
            var gate = DoublePressGate(interval: 1.5)
            let t0 = Date(timeIntervalSince1970: 1000)
            try expect(!gate.press(at: t0), "first press only arms")
            try expect(gate.press(at: t0.addingTimeInterval(1.0)), "second press within 1.5 s passes")
            try expect(!gate.press(at: t0.addingTimeInterval(1.2)), "after passing, the next press arms again")
            try expect(!gate.press(at: t0.addingTimeInterval(3.0)), "too slow: re-arms instead")
            try expect(gate.press(at: t0.addingTimeInterval(4.0)), "then a quick second press passes")
        }

        testRunner("Commander shows a hint over the panels") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let view = CommanderView(model: CommanderModel(left: PanelModel(directory: root), right: PanelModel(directory: root)))
            view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            try expect(view.hintText == nil, "no hint at start")
            view.showHint("Press ⌘Q again to quit")
            try expect(view.hintText == "Press ⌘Q again to quit", "hint visible: \(view.hintText ?? "nil")")
        }

        testRunner("Tab switches focus between panels; keys drive only the active one") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let model = CommanderModel(left: PanelModel(directory: root), right: PanelModel(directory: root))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            try expect(view.leftView.isActive && !view.rightView.isActive, "left starts active")
            view.perform(.cursorDown)
            try expect(model.left.cursor == 1 && model.right.cursor == 0, "down moves left only")
            view.perform(.switchPanel)
            try expect(model.activeSide == .right, "tab focuses right")
            try expect(!view.leftView.isActive && view.rightView.isActive, "views follow focus")
            view.perform(.lastItem)
            try expect(model.right.cursor == 5 && model.left.cursor == 1, "end moves right only")
            view.perform(.switchPanel)
            try expect(model.activeSide == .left, "tab focuses left again")
            view.perform(.open)
            try expect(model.left.directory.lastPathComponent == "alpha", "enter opens alpha in left")
            view.perform(.parentFolder)
            try expect(model.left.currentEntry?.name == "alpha", "backspace returns onto alpha")
        }

        testRunner("Right arrow enters folders only, Left arrow goes up onto the folder we left") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let keys = KeyBindings.standard
            try expect(keys.action(for: KeyCombo(KeyCode.right)) == .enterFolder, "→ enters")
            try expect(keys.action(for: KeyCombo(KeyCode.left)) == .parentFolder, "← goes up")
            try expect(keys.action(for: KeyCombo(KeyCode.h)) == .parentFolder && keys.action(for: KeyCombo(KeyCode.l)) == .enterFolder
                       && keys.action(for: KeyCombo(KeyCode.j)) == .cursorDown && keys.action(for: KeyCombo(KeyCode.k)) == .cursorUp,
                       "vim hjkl")
            try expect(keys.action(for: KeyCombo(KeyCode.h, .command)) == nil, "⌘H stays the app's Hide")
            let model = CommanderModel(left: PanelModel(directory: root), right: PanelModel(directory: root))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            var opened: [URL] = []
            view.onOpenFile = { opened.append($0) }
            model.left.focus(name: "file2.txt", visibleRows: 20)
            view.perform(.enterFolder)
            try expect(model.left.directory == root.standardizedFileURL && opened.isEmpty, "→ on a file does nothing")
            model.left.focus(name: "alpha", visibleRows: 20)
            view.perform(.enterFolder)
            try expect(model.left.directory.lastPathComponent == "alpha", "→ entered alpha")
            view.perform(.parentFolder)
            try expect(model.left.directory == root.standardizedFileURL && model.left.currentEntry?.name == "alpha",
                       "← back up, cursor on alpha")
            model.left.moveToStart(visibleRows: 20)
            view.perform(.enterFolder)
            try expect(model.left.directory == root.deletingLastPathComponent().standardizedFileURL, "→ on .. goes up")
        }

        testRunner("Right-click toggles; right-drag marks or unmarks by the first row; * inverts") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            // entries: 0 .., 1 alpha, 2 Beta, 3 archive.tar.gz, 4 file2.txt, 5 file10.txt
            let model = CommanderModel(left: PanelModel(directory: root), right: PanelModel(directory: root))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            let panel = view.leftView
            let names = { model.left.marked.sorted() }

            panel.beginRightSelection(atRow: 2); panel.endRightSelection()
            try expect(names() == ["Beta"] && model.left.cursor == 2, "right-click marks and moves the cursor")
            panel.beginRightSelection(atRow: 2); panel.endRightSelection()
            try expect(names().isEmpty, "second right-click unmarks")

            panel.beginRightSelection(atRow: 1)           // alpha unmarked -> drag marks
            panel.continueRightSelection(toRow: 4)        // fast drag: rows 2,3,4 all marked
            panel.endRightSelection()
            try expect(names() == ["Beta", "alpha", "archive.tar.gz", "file2.txt"].sorted(), "drag marks: \(names())")

            panel.beginRightSelection(atRow: 3)           // archive marked -> drag unmarks
            panel.continueRightSelection(toRow: 5)
            panel.continueRightSelection(toRow: 0)        // back up past the start, over ".."
            panel.endRightSelection()
            try expect(names().isEmpty, "drag unmarks everything it passes: \(names())")

            panel.beginRightSelection(atRow: 0)           // ".." cannot be marked; mode set by next row
            panel.continueRightSelection(toRow: 1)
            panel.endRightSelection()
            try expect(names() == ["alpha"], "starting on .. : \(names())")

            try expect(KeyBindings.standard.action(for: KeyCombo(KeyCode.eight, [.control, .shift])) == .invertSelection, "⌃⇧8 inverts")
            try expect(KeyBindings.standard.action(for: KeyCombo(KeyCode.eight, .shift)) == .deletePermanently, "⇧8 deletes permanently")
            try expect(KeyBindings.standard.action(for: KeyCombo(KeyCode.six, .shift)) == .renameInPlace, "⇧6 renames in place")
            try expect(KeyBindings.standard.action(for: KeyCombo(KeyCode.eight)) == .delete, "plain 8 still deletes")
            view.perform(.invertSelection)
            try expect(names() == ["Beta", "archive.tar.gz", "file10.txt", "file2.txt"].sorted(), "inverted: \(names())")
            view.perform(.invertSelection)
            try expect(names() == ["alpha"], "inverted back")
        }

        testRunner("Symlinked folder: listed, entered through the link, sized, and .. returns to the link's parent") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                       withDestinationURL: root.appendingPathComponent("alpha"))
            let panel = PanelModel(directory: root)
            panel.focus(name: "link", visibleRows: 20)
            try expect(panel.currentEntry?.kind == .directory && panel.currentEntry?.isSymlink == true, "link shown as folder")
            try expect(FolderSizer.totalSize(of: root.appendingPathComponent("link")) == 2048, "link sized via target")
            try expect(panel.enterCurrentFolder(visibleRows: 20) == .navigated, "entered: \(panel.errorMessage ?? "")")
            try expect(panel.directory.lastPathComponent == "link", "path stays on the link: \(panel.directory.path)")
            try expect(panel.entries.map(\.name) == ["..", "inner.txt"], "target contents listed")
            try expect(panel.entries[1].url.path == root.appendingPathComponent("link/inner.txt").path, "entries under the link path")
            panel.goUp(visibleRows: 20)
            try expect(panel.directory == root.standardizedFileURL && panel.currentEntry?.name == "link", "back to parent, on link")
        }

        testRunner("File masks: wildcards, several masks, *.* matches all, trailing / for folders") {
            func e(_ n: String, dir: Bool = false) -> FileEntry {
                FileEntry(name: n, url: URL(fileURLWithPath: "/" + n), kind: dir ? .directory : .file)
            }
            try expect(FileMask("*.txt").matches(e("Notes.TXT")) && !FileMask("*.txt").matches(e("a.txt.gz")), "*.txt")
            try expect(FileMask("*.jpg;*.png").matches(e("a.png")) && FileMask("*.jpg *.png").matches(e("b.jpg")), "several")
            try expect(FileMask("*.*").matches(e("Makefile")), "*.* matches names without a dot")
            try expect(FileMask("file?.txt").matches(e("file2.txt")) && !FileMask("file?.txt").matches(e("file10.txt")), "?")
            try expect(!FileMask("*.*").matches(e("src", dir: true)), "files-only by default")
            try expect(FileMask("s*/").matches(e("src", dir: true)) && !FileMask("s*/").matches(e("s.txt")), "folders with /")
            try expect(!FileMask("*").matches(FileEntry.parent(of: URL(fileURLWithPath: "/a/b"))), ".. never")
            try expect(FileMask("a+b(1).txt").matches(e("a+b(1).txt")), "regex characters are literal")
            try expect(FileMask(" ; ").isEmpty, "empty mask")
        }

        testRunner("+ selects and - deselects by mask (⇧= / = / - keys), remembering the last mask") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let keys = KeyBindings.standard
            try expect(keys.action(for: KeyCombo(KeyCode.equal, .shift)) == .selectByMask, "⇧= is +")
            try expect(keys.action(for: KeyCombo(KeyCode.equal)) == .selectByMask, "= too")
            try expect(keys.action(for: KeyCombo(KeyCode.minus)) == .deselectByMask, "- deselects")
            let model = CommanderModel(left: PanelModel(directory: root), right: PanelModel(directory: root))
            let view = CommanderView(model: model)
            let prompts = StubPrompts()
            view.fileCommands.prompts = prompts
            prompts.answer = "*.txt"
            view.perform(.selectByMask)
            try expect(model.left.marked == ["file2.txt", "file10.txt"], "selected: \(model.left.marked)")
            try expect(prompts.lastDefault == "*.*", "first default is *.*")
            prompts.answer = "*.*"
            view.perform(.selectByMask)
            try expect(model.left.marked == ["file2.txt", "file10.txt", "archive.tar.gz"], "all files, no folders")
            prompts.answer = "file1*"
            view.perform(.deselectByMask)
            try expect(model.left.marked == ["file2.txt", "archive.tar.gz"], "deselected: \(model.left.marked)")
            try expect(prompts.lastDefault == "*.*", "default was the last mask")
            view.perform(.selectByMask)     // StubPrompts returns the default -> last mask "file1*"
            try expect(prompts.lastDefault == "file1*" && model.left.marked.contains("file10.txt"), "remembered mask")
        }

        testRunner("Columns: Date is never cut — Size narrows first, then Date drops the time") {
            for total in stride(from: CGFloat(200), through: 1400, by: 10) {
                let w = PanelView.columnWidths(total: total)
                try expect(w.date >= PanelView.shortDateWidth, "date cut at \(total): \(w.date)")
                try expect(w.size >= PanelView.minimumSizeWidth, "size below short form at \(total)")
                try expect(abs(w.name + w.ext + w.size + w.date + w.attr - max(total, w.ext + w.size + w.date + w.attr)) < 0.5,
                           "widths add up at \(total)")
            }
            let wide = PanelView.columnWidths(total: 900)
            try expect(wide.date == PanelView.fullDateWidth && wide.name >= 900 * 0.34, "wide: full date, roomy name")
            let half = PanelView.columnWidths(total: 620)   // a pane in a half-screen window
            try expect(half.date >= PanelView.shortDateWidth && half.name >= 90, "half screen: \(half)")
            let narrow = PanelView.columnWidths(total: 360)
            try expect(narrow.date == PanelView.shortDateWidth && narrow.size == PanelView.minimumSizeWidth,
                       "narrow: short date, short size: \(narrow)")
        }

        testRunner("Shift-click marks from the cursor to the clicked row, keeping other marks") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            // 0 .., 1 alpha, 2 Beta, 3 archive.tar.gz, 4 file2.txt, 5 file10.txt
            let p = PanelModel(directory: root)
            p.setCursor(5, visibleRows: 20)
            p.toggleMarkAtCursor()
            p.setCursor(0, visibleRows: 20)
            p.markRange(toRow: 2, visibleRows: 20)
            try expect(p.marked == ["alpha", "Beta", "file10.txt"] && p.cursor == 2, "down from ..: \(p.marked)")
            p.markRange(toRow: 4, visibleRows: 20)
            try expect(p.marked == ["alpha", "Beta", "archive.tar.gz", "file2.txt", "file10.txt"] && p.cursor == 4, "extends")
            p.clearMarks()
            p.markRange(toRow: 3, visibleRows: 20)    // upwards
            try expect(p.marked == ["archive.tar.gz", "file2.txt"] && p.cursor == 3, "upwards: \(p.marked)")
        }

        testRunner("Settings export/import as JSON: everything round-trips, partial files merge, junk is refused") {
            var custom = Settings.standard
            custom.theme = .totalCommander
            custom.display = DisplayOptions(showFolderBrackets: false, showFunctionKeyBar: false, showStatusBarIcon: false)
            custom.operation = OperationOptions(spaceCalculatesFolderSize: false, spaceMovesCursorDown: true)
            custom.keys.add(KeyCombo(KeyCode.q, .control), to: .goHome)
            let data = try SettingsFile.export(custom)
            let text = String(decoding: data, as: UTF8.self)
            try expect(text.contains("\"format\" : \"ClassicCommander settings\"") && text.contains("\"cursorBackground\""), "readable JSON")
            try expect(try SettingsFile.importing(data, onto: .standard) == custom, "round trip")
            let partial = Data(#"{"format":"ClassicCommander settings","version":1,"display":{"showFolderBrackets":false}}"#.utf8)
            let merged = try SettingsFile.importing(partial, onto: custom)
            try expect(merged.theme == custom.theme && merged.keys == custom.keys, "missing sections keep current values")
            try expect(!merged.display.showFolderBrackets && merged.display.showFunctionKeyBar && merged.display.showStatusBarIcon,
                       "missing fields take defaults")
            for junk in ["not json", #"{"format":"something else","version":1}"#] {
                var refused = false
                do { _ = try SettingsFile.importing(Data(junk.utf8), onto: custom) } catch { refused = true }
                try expect(refused, "refused: \(junk)")
            }
        }

        testRunner("Options export/import buttons: export writes a file, import applies live, Cancel undoes it") {
            let suite = "CommanderTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            let options = OptionsWindowController(store: store)
            let root = options.window!.contentView!
            try expect(allViews(NSButton.self, in: root).contains { $0.title == "Export…" }
                       && allViews(NSButton.self, in: root).contains { $0.title == "Import…" }, "buttons present")
            let icon = try findView(NSButton.self, in: root, where: { $0.title.contains("menu bar") })
            try expect(icon.state == .on, "menu bar icon on by default")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            var other = Settings.standard
            other.theme = .totalCommander
            other.display.showStatusBarIcon = false
            try SettingsFile.export(other).write(to: file)
            try options.importSettings(from: file)
            try expect(store.theme == .totalCommander && !store.display.showStatusBarIcon && icon.state == .off, "imported live")
            try press("Cancel", in: root)
            try expect(store.settings == .standard, "Cancel undoes the import")
            options.present()
            try options.exportSettings(to: file)
            try expect(try SettingsFile.importing(Data(contentsOf: file), onto: other) == .standard, "export wrote current settings")
            options.window?.close()
            try expect(StatusBarController.floppyIcon.isTemplate, "menu bar icon is a template image")
        }

        testRunner("Quick search matching: prefix, any case, wildcards, wraps, skips ..") {
            try expect(PanelModel.quickMatches("Documents", "doc") && !PanelModel.quickMatches("MyDocs", "doc"), "prefix")
            try expect(PanelModel.quickMatches("photo.JPG", "*.jpg") && PanelModel.quickMatches("file10.txt", "f?le1"), "wildcards")
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            // 0 .., 1 alpha, 2 Beta, 3 archive.tar.gz, 4 file2.txt, 5 file10.txt
            let p = PanelModel(directory: root)
            try expect(p.quickSearchIndex("a", from: 0) == 1, "first a")
            try expect(p.quickSearchIndex("a", from: 1, includingStart: false) == 3, "next a")
            try expect(p.quickSearchIndex("a", from: 3, includingStart: false) == 1, "wraps around")
            try expect(p.quickSearchIndex("a", from: 1, forward: false, includingStart: false) == 3, "previous wraps")
            try expect(p.quickSearchIndex("zzz", from: 0) == nil, "no match")
            try expect(p.quickSearchIndex(".", from: 0) == nil, ".. never matches")
        }

        testRunner("Quick filter: only matches (and ..) remain, cursor on the first match, Esc/cd clears, sort and marks still work") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let p = PanelModel(directory: root)
            p.focus(name: "file10.txt", visibleRows: 20)
            p.setQuickFilter("*.txt", visibleRows: 20)
            try expect(p.entries.map(\.name) == ["..", "file2.txt", "file10.txt"], "filtered: \(p.entries.map(\.name))")
            try expect(p.currentEntry?.name == "file2.txt" && p.quickFilter == "*.txt", "cursor on the first match, not kept")
            p.focus(name: "..", visibleRows: 20)
            p.setQuickFilter("file", visibleRows: 20)
            try expect(p.currentEntry?.name == "file2.txt", "from .. too: every change selects the first match")
            p.sort(by: .name, visibleRows: 20)  // now descending
            try expect(p.entries.map(\.name) == ["..", "file10.txt", "file2.txt"], "sorting keeps the filter")
            p.setQuickFilter("*.txt", visibleRows: 20)
            p.invertMarks()
            try expect(p.marked == ["file2.txt", "file10.txt"], "* acts on visible entries: \(p.marked)")
            p.reload(visibleRows: 20)
            try expect(p.quickFilter == "*.txt" && p.entries.count == 3, "reload keeps the filter")
            try expect(p.quickFilterCount("q") == 0 && p.quickFilterCount("a") == 2, "counts")
            p.focus(name: "file10.txt", visibleRows: 20)
            p.setQuickFilter(nil, visibleRows: 20)
            try expect(p.entries.count == 6 && p.currentEntry?.name == "file10.txt", "cleared, cursor kept on its entry")
            p.setQuickFilter("al", visibleRows: 20)
            p.focus(name: "alpha", visibleRows: 20)
            p.enterCurrentFolder(visibleRows: 20)
            try expect(p.quickFilter == nil, "changing directory clears the filter")
        }

        testRunner("Quick search box: ⌃⌥+letter starts it, typing narrows, bad letters refused, ⌃S filters, Esc clears") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let model = CommanderModel(left: PanelModel(directory: root), right: PanelModel(directory: root))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            }
            try expect(view.quickSearchStart(key(3, "f", [.control, .option])) == "f", "⌃⌥F starts quick search")
            try expect(view.quickSearchStart(key(3, "f", [])) == nil, "plain f does not (default)")
            var s = Settings.standard
            s.quickSearch.activation = .lettersOnly
            view.settings = s
            try expect(view.quickSearchStart(key(3, "f", [])) == "f", "letter alone when chosen")
            s.quickSearch.activation = .off
            view.settings = s
            try expect(view.quickSearchStart(key(3, "f", [.control, .option])) == nil, "off")

            let qs = view.quickSearch
            qs.open(in: view.leftView, mode: .search, text: "f")
            try expect(qs.isOpen && model.left.currentEntry?.name == "file2.txt", "jumped to first f")
            qs.type("ile1")
            try expect(model.left.currentEntry?.name == "file10.txt", "narrowed")
            qs.type("x")
            try expect(qs.field.stringValue == "file1" && model.left.currentEntry?.name == "file10.txt", "bad letter refused")
            qs.switchMode()
            try expect(qs.mode == .filter && model.left.entries.map(\.name) == ["..", "file10.txt"], "⌃S → filter")
            qs.close(clearFilter: false)
            try expect(model.left.quickFilter == "file1", "↩ keeps the filter")
            try expect(qs.lastText == "file1", "remembered for ⌃⇧S")
            view.perform(.reopenQuickSearch)
            try expect(qs.isOpen && qs.mode == .search && qs.field.stringValue == "file1", "reopened")
            qs.close(clearFilter: true)
            view.keyDown(with: key(KeyCode.escape, "\u{1b}", []))
            try expect(model.left.quickFilter == nil && model.left.entries.count == 6, "Esc clears the filter")
            try expect(KeyBindings.standard.action(for: KeyCombo(KeyCode.s, .control)) == .quickFilter, "⌃S bound")
        }

        testRunner("Lister content: encoding detection, binary detection, hex and binary layout") {
            try expect(ListerContent.detectEncoding(Data("zażółć".utf8)) == .utf8, "UTF-8")
            var bom = Data([0xFF, 0xFE]); bom.append("hi there".data(using: .utf16LittleEndian)!)
            try expect(ListerContent.detectEncoding(bom) == .utf16LE, "UTF-16 LE BOM")
            try expect(ListerContent.detectEncoding("plain ascii text".data(using: .utf16BigEndian)!) == .utf16BE, "UTF-16 BE pattern")
            try expect(ListerContent.detectEncoding(Data([0x63, 0x61, 0x66, 0xE9])) == .ansi, "invalid UTF-8 falls back to ANSI")
            var cut = Data("abc".utf8); cut.append(contentsOf: [0xC5])          // first byte of "ż", cut off
            try expect(ListerContent.detectEncoding(cut, cut: true) == .utf8, "a character cut by the read limit is still UTF-8")
            try expect(ListerContent.detectEncoding(cut) == .ansi, "but a whole file ending like that is not UTF-8")
            try expect(ListerContent.text(Data([0xEF, 0xBB, 0xBF, 0x41]), encoding: .auto).0 == "A", "UTF-8 BOM hidden")
            try expect(ListerContent.isBinary(Data([0x4D, 0x5A, 0x00, 0x01, 0x02])) && !ListerContent.isBinary(Data("text\n".utf8)), "binary")
            try expect(!ListerContent.isBinary("utf16".data(using: .utf16LittleEndian)! + "more text!".data(using: .utf16LittleEndian)!), "UTF-16 is text")
            try expect(ListerContent.hexLine(Array("Hello World\n".utf8), offset: 16)
                       == "00000010  48 65 6C 6C 6F 20 57 6F  72 6C 64 0A              Hello World.", "hex line")
            try expect(ListerContent.binaryText(Data([0x41, 0x00, 0x42, 0x43]), width: 2) == "A·\nBC\n", "binary layout")
            try expect(ListerContent.defaultMode(for: URL(fileURLWithPath: "/a.png"), sample: Data()) == .preview, "images preview")
            try expect(ListerContent.defaultMode(for: URL(fileURLWithPath: "/a.bin"), sample: Data([0, 1, 2])) == .hex, "binary → hex")
            try expect(ListerContent.defaultMode(for: URL(fileURLWithPath: "/a.txt"), sample: Data("x".utf8)) == .text, "text")
        }

        testRunner("Lister: 3 opens the file under the cursor; 1/2/3/4 modes, n/p, w, huge files in hex, F3 on a folder sizes it") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            try expect(KeyBindings.standard.action(for: KeyCombo(KeyCode.three)) == .view
                       && KeyBindings.standard.action(for: KeyCombo(KeyCode.f3)) == .view, "3 and F3 view")
            try Data("Hello Lister\nzażółć".utf8).write(to: root.appendingPathComponent("file2.txt"))
            let model = CommanderModel(left: PanelModel(directory: root), right: PanelModel(directory: root))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            model.left.focus(name: "file2.txt", visibleRows: 20)
            guard let lister = view.view(in: view.leftView) else { throw TestFailure(description: "no lister") }
            defer { lister.window?.close() }
            try expect(lister.mode == .text && lister.textView.string == "Hello Lister\nzażółć", "text: \(lister.textView.string)")
            try expect(lister.shownEncoding == .utf8 && lister.statusLabel.stringValue.contains("UTF-8"), "encoding shown")
            func key(_ chars: String, _ code: UInt16 = 0) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                 characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            }
            try expect(lister.handleKey(key("3")) && lister.mode == .hex && lister.hexTable.numberOfRows == 2, "3 → hex")
            try expect(lister.handleKey(key("2")) && lister.mode == .binary, "2 → binary")
            try expect(lister.handleKey(key("1")) && lister.mode == .text, "1 → text")
            let wrapped = lister.wrap
            _ = lister.handleKey(key("w"))
            try expect(lister.wrap != wrapped, "w toggles wrap")
            _ = lister.handleKey(key("n"))
            try expect(lister.url.lastPathComponent == "file10.txt", "n → next file: \(lister.url.lastPathComponent)")
            _ = lister.handleKey(key("p"))
            _ = lister.handleKey(key("p"))
            try expect(lister.url.lastPathComponent == "archive.tar.gz", "p → previous: \(lister.url.lastPathComponent)")
            try expect(!lister.handleKey(key("x")), "other keys are not taken")
            try expect(view.listers.count == 1, "tracked")

            // A 3 GB sparse file opens at once in hex without reading it all.
            let big = root.appendingPathComponent("big.bin")
            FileManager.default.createFile(atPath: big.path, contents: Data([0x4D, 0x5A, 0x00]))
            let h = try FileHandle(forWritingTo: big)
            try h.truncate(atOffset: 3 * 1024 * 1024 * 1024)
            try h.close()
            let reader = try HexReader(url: big)
            try expect(reader.lineCount == 3 * 1024 * 1024 * 1024 / 16, "lines")
            try expect(reader.line(0).hasPrefix("00000000  4D 5A 00 00"), "first line: \(reader.line(0))")
            try expect(reader.line(reader.lineCount - 1).hasPrefix("BFFFFFF0"), "last line: \(reader.line(reader.lineCount - 1))")

            // F3 on a folder works out its size instead of opening Lister.
            view.sizingQueue = DispatchQueue.main
            model.left.focus(name: "alpha", visibleRows: 20)
            try expect(view.view(in: view.leftView) == nil, "no lister for folders")
            try waitFor { model.left.folderSizes["alpha"] != nil }
            try expect(model.left.marked.isEmpty, "folder not marked by F3")
        }

        testRunner("Fuzzy match: substrings first, letters in order, all words, case and accents ignored") {
            try expect(FuzzyMatch.score("copy", in: "Copy (F5)") != nil && FuzzyMatch.score("nwfl", in: "New folder (F7)") != nil, "match")
            try expect(FuzzyMatch.score("xyz", in: "Copy") == nil, "no match")
            try expect(FuzzyMatch.score("zolw", in: "Żółw") != nil, "accents ignored")
            try expect(FuzzyMatch.score("copy f5", in: "Copy (F5)") != nil && FuzzyMatch.score("copy f6", in: "Copy (F5)") == nil, "all words")
            let ranked = FuzzyMatch.filter(["Move / rename (F6)", "Copy (F5)", "Clear copying"], query: "copy") { $0 }
            try expect(ranked.first == "Copy (F5)", "substring at start ranks first: \(ranked)")
            try expect(FuzzyMatch.filter([1, 2, 3], query: " ") { String($0) } == [1, 2, 3], "empty query keeps order")
        }

        testRunner("Shortcuts page filter: by name, by key, fuzzy; selection follows; clearing restores all") {
            let suite = "CommanderTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let options = OptionsWindowController(store: SettingsStore(defaults: defaults))
            let page = try findView(ShortcutsPage.self, in: options.window!.contentView!)
            func filter(_ q: String) -> [CommandAction] {
                page.filterField.stringValue = q
                page.filterChanged()
                return page.actions
            }
            try expect(filter("") == CommandAction.allCases, "all by default")
            try expect(filter("copy").first == .copy, "by name: \(filter("copy"))")
            try expect(filter("F5") == [.copy], "by key: \(filter("F5"))")
            try expect(filter("⌥7").contains(.findFiles), "by key symbol")
            try expect(filter("alt 7").first == .findFiles, "spelled modifiers: \(filter("alt 7"))")
            try expect(filter("nwfold").first == .newFolder, "fuzzy: \(filter("nwfold"))")
            try expect(filter("qkflt").first == .quickFilter, "fuzzy 2: \(filter("qkflt"))")
            try expect(filter("zzzz").isEmpty, "no match")
            _ = filter("delete")
            let table = try findView(NSTableView.self, in: page)
            try expect(table.numberOfRows == page.actions.count && table.selectedRow == 0, "first match selected")
            page.select(.cursorUp)
            try expect(page.filterField.stringValue.isEmpty && page.actions == CommandAction.allCases, "selecting a hidden row clears the filter")
            options.window?.close()
        }

        testRunner("Panel view reports visible rows from its height") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let panel = PanelView(model: PanelModel(directory: root))
            panel.frame = NSRect(x: 0, y: 0, width: 500, height: 120)
            let small = panel.visibleRows
            panel.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
            try expect(panel.visibleRows > small && small >= 1, "rows \(small) -> \(panel.visibleRows)")
        }
    }
}

/// Answers file-command questions without dialogs.
final class StubPrompts: FileCommandPrompts {
    var answer: String?
    var confirmAnswer = true
    var conflict: ConflictDecision = .skip
    var conflicts: [TransferConflict] = []
    var lastMessage = ""
    var lastDefault = ""
    var problems: [String] = []

    func askText(title: String, message: String, defaultValue: String, okTitle: String) -> String? {
        lastMessage = message
        lastDefault = defaultValue
        defer { answer = nil }
        return answer ?? defaultValue
    }

    func confirm(title: String, message: String, okTitle: String) -> Bool {
        lastMessage = message
        return confirmAnswer
    }

    func resolveConflict(_ c: TransferConflict) -> ConflictDecision {
        conflicts.append(c)
        return conflict
    }

    func showProblems(title: String, report: OperationReport) {
        problems += report.errors
    }
}
