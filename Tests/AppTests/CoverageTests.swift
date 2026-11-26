import Cocoa

/// Tests that exercise every function of the app that the feature suites do not reach
/// (see scripts/coverage.sh / make coverage). Grouped by source file.
public enum CoverageTests {
    typealias Fail = CommanderTests.TestFailure
    static func expect(_ c: @autoclosure () throws -> Bool, _ m: String) throws {
        if try !c() { throw Fail(description: m) }
    }

    static func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs the main run loop until `done` or the timeout (async work reports on the main queue).
    static func wait(_ seconds: TimeInterval = 30, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// Removes a file that was moved to the Trash by a test (by its unique name).
    static func removeFromTrash(named name: String) {
        guard let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first,
              let items = try? FileManager.default.contentsOfDirectory(atPath: trash.path) else { return }
        for item in items where item.hasPrefix(name) { try? FileManager.default.removeItem(at: trash.appendingPathComponent(item)) }
    }

    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        runCore(testRunner)
        runFTPWindows(testRunner)
        runPanelAndWindows(testRunner)
        runBigWindows(testRunner)
    }

    static func allButtons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? [] + view.subviews.flatMap(allButtons)
    }

    /// A commander inside an offscreen window, so mouse and key events have real coordinates.
    static func windowed(_ dir: URL) -> (NSWindow, CommanderView) {
        let view = commander(dir)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = window.contentView!.bounds
        view.layout()
        return (window, view)
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    static func center(_ r: NSRect) -> NSPoint { NSPoint(x: r.midX, y: r.midY) }

    // MARK: - UI helpers

    /// Calls an @objc action by name (also private ones), as a click on its control would.
    static func send(_ target: NSObject, _ selector: String, _ argument: Any? = nil) {
        _ = target.perform(NSSelectorFromString(selector), with: argument)
    }

    static func button(_ title: String, in view: NSView) -> NSButton? {
        if let b = view as? NSButton, b.title == title { return b }
        for sub in view.subviews { if let b = button(title, in: sub) { return b } }
        return nil
    }

    static func click(_ title: String, in view: NSView?) throws {
        guard let view = view, let b = button(title, in: view) else { throw Fail(description: "no button “\(title)”") }
        b.performClick(nil)
    }

    /// Dialogs answer with `response`; a text accessory gets `text`.
    /// Answers alerts with `response`; the first button also answers OK in the Copy / Move dialog.
    static func answer(_ response: NSApplication.ModalResponse, text: String? = nil) {
        Modal.answerAlert = { alert in
            if let text = text { (alert.accessoryView as? NSTextField)?.stringValue = text }
            return response
        }
        Modal.answerWindow = { _ in response == .alertFirstButtonReturn ? .OK : .cancel }
    }

    static func resetAnswers() {
        Modal.answerAlert = { _ in .cancel }
        Modal.answerPanel = { _ in [] }
        Modal.answerWindow = { _ in .cancel }
    }

    static func commander(_ dir: URL = FileManager.default.temporaryDirectory) -> CommanderView {
        let view = CommanderView(model: CommanderModel(left: PanelModel(directory: dir), right: PanelModel(directory: dir)))
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        view.layout()
        return view
    }

    static func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    // MARK: - Core

    static func runCore(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("Core: labels, getters and small helpers") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let model = CommanderModel(left: PanelModel(directory: home), right: PanelModel(directory: URL(fileURLWithPath: "/")))
            try expect(model.inactive === model.right, "inactive panel")
            try expect(FTPServerType.allCases.map(\.label).count == 4 && FTPTransferMode.allCases.map(\.label).allSatisfy { !$0.isEmpty }
                       && FTPProxyKind.allCases.map(\.label).count == 3 && RemoteProtocol.allCases.map(\.label).count == 2
                       && SSHAuthMethod.allCases.map(\.label).count == 2, "labels")
            let suite = "Coverage-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let repo = FTPProfileRepository(defaults: defaults, credentials: MemoryCredentialStore())
            repo.addFolder("  Work ")
            repo.addFolder("Work")
            try expect(repo.folders == ["Work"], "folder added once")
            let session = RemoteSession(client: FTPClient(profile: FTPProfile(), password: nil))
            try expect(RemoteSession.path(of: session.rootURL) == "/", "root URL")
            try expect(FileEntry.parent(of: home).isNavigable, "navigable")
            let menu = LocationMenu(cursorFolder: home, home: home, drives: LocationMenu.mountedDrives())
            try expect(!menu.drives.isEmpty && menu.drives.allSatisfy { if case .drive = $0 { return true } else { return false } }, "drives")
            let panel = PanelModel(directory: URL(fileURLWithPath: "/usr/bin"))
            panel.pageDown(visibleRows: 10)
            try expect(panel.cursor == 9, "page down: \(panel.cursor)")
            try expect(SearchValidationError(message: "m").description == "m", "description")
            try expect(ContentCharset.allCases.map(\.stringEncoding).filter { $0 != nil }.count >= 4, "encodings")
            try expect(Theme.SlotKey(intValue: 1) == nil && Theme.SlotKey(stringValue: "text").intValue == nil, "coding key")
            var errors: [String] = []
            let twin = { (dir: String) in SearchItem(url: URL(fileURLWithPath: "/\(dir)/same.txt"), name: "same.txt", isDirectory: false,
                                                     size: 5, modified: Date(), mode: 0o644, flags: 0, ownerID: 501) }
            try expect(DuplicateFinder.groups(of: [twin("a"), twin("b")], config: DuplicateSearchConfiguration(enabled: true), errors: &errors).count == 1,
                       "duplicates by name and size")
            let drive = { (path: String) in LocationMenu.Item.drive(name: path, url: URL(fileURLWithPath: path), available: nil, total: nil) }
            try expect(LocationMenu.ordered([drive("/Volumes/B"), drive("/"), drive("/Volumes/A")]).map(\.url.path) == ["/", "/Volumes/A", "/Volumes/B"],
                       "startup volume first")
            let many = try tempDir("Many")
            defer { try? FileManager.default.removeItem(at: many) }
            for i in 0..<520 { FileManager.default.createFile(atPath: many.appendingPathComponent("f\(i)").path, contents: Data([1])) }
            try expect(FolderSizer.totalSize(of: many) == 520, "size of a folder with more than 512 entries")
        }

        testRunner("Core: unreadable folders are reported by every walker") {
            let dir = try tempDir("Unreadable")
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("locked").path)
                    try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("locked"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("locked/inside.txt"))
            try Data("abc".utf8).write(to: dir.appendingPathComponent("a.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.appendingPathComponent("locked").path)
            try expect(FolderSizer.totalSize(of: dir) == 3, "size skips the unreadable folder")
            var c = FileSearchConfiguration()
            c.general.searchPaths = [dir.path]
            let report = try FileSearch(config: c, base: dir).run()
            try expect(report.errors.contains { $0.contains("locked") }, "search reports it: \(report.errors)")
            let other = try tempDir("Other")
            defer { try? FileManager.default.removeItem(at: other) }
            let comparison = try SyncEngine.compare(SyncConfiguration(left: dir, right: other))
            try expect(comparison.errors.contains { $0.contains("locked") }, "sync reports it: \(comparison.errors)")
        }

        testRunner("Core: search results in a panel drop files that disappeared on reload") {
            let dir = try tempDir("Virtual")
            defer { try? FileManager.default.removeItem(at: dir) }
            for n in ["a.txt", "b.txt"] { try Data(n.utf8).write(to: dir.appendingPathComponent(n)) }
            let panel = PanelModel(directory: dir)
            panel.showSearchResults([dir.appendingPathComponent("a.txt"), dir.appendingPathComponent("b.txt")], title: "r", visibleRows: 10)
            panel.focus(name: "b.txt", visibleRows: 10)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("a.txt"))
            panel.reload(visibleRows: 10)
            try expect(panel.realEntries.map(\.name) == ["b.txt"] && panel.currentEntry?.name == "b.txt", "\(panel.realEntries.map(\.name))")
        }

        testRunner("Core: Keychain credential store saves, reads and removes a password") {
            let store = KeychainCredentialStore(service: "ClassicCommander Coverage \(UUID().uuidString)")
            let id = UUID()
            store.setPassword("s3cret", for: id)
            try expect(store.password(for: id) == "s3cret", "read back")
            store.setPassword(nil, for: id)
            try expect(store.password(for: id) == nil, "removed")
        }

        testRunner("Core: deleting to the Trash (file commands and Synchronize)") {
            let dir = try tempDir("Trash")
            defer { try? FileManager.default.removeItem(at: dir) }
            let name = "cc-coverage-\(UUID().uuidString.prefix(8))"
            let a = dir.appendingPathComponent(name + "-a.txt")
            try Data("a".utf8).write(to: a)
            defer { removeFromTrash(named: name) }
            try expect(FileCommandsCore.trash([a]).done == 1 && !FileManager.default.fileExists(atPath: a.path), "trashed")
            // Synchronize: an asymmetric run deletes a right-only file with the default (Trash) handler.
            let left = dir.appendingPathComponent("L"), right = dir.appendingPathComponent("R")
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
            try Data("b".utf8).write(to: right.appendingPathComponent(name + "-b.txt"))
            var cfg = SyncConfiguration(left: left, right: right)
            cfg.asymmetric = true
            let plan = SyncPlan(rows: try SyncEngine.compare(cfg).rows, config: cfg)
            let report = SyncExecutor.run(plan, options: SyncRunOptions())
            try expect(report.deleted == 1, "sync delete: \(report)")
        }

        testRunner("Core: certificate of a TLS server (trust dialog data)") {
            let dir = try tempDir("TLS")
            defer { try? FileManager.default.removeItem(at: dir) }
            try SFTPTests.TestSSHServer.tool("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=localhost", "-keyout", dir.appendingPathComponent("k.pem").path, "-out", dir.appendingPathComponent("c.pem").path])
            let port = Int.random(in: 30000...60000)
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            server.arguments = ["s_server", "-accept", String(port), "-cert", dir.appendingPathComponent("c.pem").path,
                                "-key", dir.appendingPathComponent("k.pem").path, "-quiet"]
            server.standardInput = Pipe()
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try server.run()
            defer { server.terminate() }
            var cert: (summary: String, pin: String)?
            for _ in 0..<50 where cert == nil {
                cert = FTPClient.fetchCertificate(host: "127.0.0.1", port: port, explicit: false)
                if cert == nil { Thread.sleep(forTimeInterval: 0.1) }
            }
            try expect(cert?.pin.hasPrefix("sha256//") == true && cert?.summary.contains("localhost") == true, "certificate: \(String(describing: cert))")
            try expect(FTPClient.fetchCertificate(host: "bad host", port: port, explicit: true) == nil, "invalid host refused")
        }

        testRunner("Core: transfers in the background — server to server, moves, progress, cancel, clear") {
            let server = try FTPTests.TestServer()
            defer { server.stop() }
            let a = RemoteSession(client: FTPClient(profile: server.profile(), password: "s3cret pass"))
            let b = RemoteSession(client: FTPClient(profile: server.profile(), password: "s3cret pass"))
            let manager = TransferManager()
            var seenBytes: Int64 = 0
            manager.onChange = { job in seenBytes = max(seenBytes, job.bytesDone) }
            func runJob(_ job: TransferJob) throws {
                manager.enqueue(job)
                wait { job.state == .finished || job.state == .cancelled }
                try expect(job.state == .finished && job.failedCount == 0, "\(job.title): \(job.statusText) \(job.results)")
            }
            // Server to server (through a temporary file on this Mac).
            let copy = TransferJob(title: "s2s", items: [TransferItem(source: .remote(a, "/www/assets/big.bin"),
                destination: .remote(b, "/www/s2s/big.bin"), size: 70_000, isFolder: false)], isMove: false)
            try runJob(copy)
            try expect(FileManager.default.contents(atPath: server.root.appendingPathComponent("www/s2s/big.bin").path)?.count == 70_000, "copied")
            seenBytes = max(seenBytes, copy.bytesDone)
            try expect(copy.fileCount == 1 && copy.elapsed >= 0 && copy.speed >= 0 && seenBytes > 0, "job figures")
            // Move a local folder up, then move it back down (source folders are removed afterwards).
            let local = try tempDir("Move")
            defer { try? FileManager.default.removeItem(at: local) }
            try FileManager.default.createDirectory(at: local.appendingPathComponent("tree/sub"), withIntermediateDirectories: true)
            try Data("m".utf8).write(to: local.appendingPathComponent("tree/sub/m.txt"))
            var plan = try TransferPlanner.plan([.init(location: .local(local.appendingPathComponent("tree")), isFolder: true, size: 0)],
                                                into: .remote(a, "/www"))
            try runJob(TransferJob(title: "up", items: plan.items, isMove: true, sourceFoldersToRemove: plan.foldersToRemove))
            try expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("tree").path), "local tree moved away")
            plan = try TransferPlanner.plan([.init(location: .remote(a, "/www/tree"), isFolder: true, size: 0)], into: .local(local))
            try runJob(TransferJob(title: "down", items: plan.items, isMove: true, sourceFoldersToRemove: plan.foldersToRemove))
            try expect(!FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/tree").path)
                       && FileManager.default.fileExists(atPath: local.appendingPathComponent("tree/sub/m.txt").path), "moved back")
            // Cancel a queue: one file at a time, the rest is dropped.
            manager.limits = TransferLimits(total: 1)
            let many = (0..<6).map { TransferItem(source: .remote(a, "/www/assets/big.bin"), destination: .local(local.appendingPathComponent("c\($0).bin")), size: 70_000, isFolder: false) }
            let job = TransferJob(title: "many", items: many, isMove: false)
            manager.enqueue(job)
            wait { job.running > 0 }
            manager.cancel(job)
            wait { job.state == .cancelled || job.state == .finished }
            try expect(job.state == .cancelled && job.doneCount < 6, "cancelled: \(job.statusText)")
            manager.clearFinished()
            try expect(manager.jobs.isEmpty, "finished jobs cleared")
        }

        testRunner("Core: Synchronize between two server folders, with empty folders created on the server") {
            let server = try FTPTests.TestServer()
            defer { server.stop() }
            let a = RemoteSession(client: FTPClient(profile: server.profile(), password: "s3cret pass"))
            let b = RemoteSession(client: FTPClient(profile: server.profile(), password: "s3cret pass"))
            let lookup: SyncSessionLookup = { url in [a, b].first { $0.id == RemoteSession.sessionID(of: url) } }
            let fm = FileManager.default
            try fm.createDirectory(at: server.root.appendingPathComponent("www/left/empty/inner"), withIntermediateDirectories: true)
            try fm.createDirectory(at: server.root.appendingPathComponent("www/right"), withIntermediateDirectories: true)
            try Data("only left".utf8).write(to: server.root.appendingPathComponent("www/left/l.txt"))
            var cfg = SyncConfiguration(left: a.url(for: "/www/left"), right: b.url(for: "/www/right"))
            cfg.emptyDirectories = true
            let rows = try SyncEngine.compare(cfg, sessions: lookup).rows
            let report = SyncExecutor.run(SyncPlan(rows: rows, config: cfg), options: SyncRunOptions(), sessions: lookup)
            try expect(report.errors.isEmpty && report.copied == 1 && report.created >= 1, "server to server sync: \(report)")
            try expect(fm.fileExists(atPath: server.root.appendingPathComponent("www/right/l.txt").path)
                       && fm.fileExists(atPath: server.root.appendingPathComponent("www/right/empty/inner").path), "copied and created")
        }
    }

    // MARK: - FTP windows

    static func runFTPWindows(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("UI: FTP profile editor — every control, Test connection, OK and Cancel") {
            defer { resetAnswers() }
            let server = try FTPTests.TestServer()
            defer { server.stop() }
            var p = server.profile()
            p.pinnedPublicKey = "sha256//abc="
            p.trustedHostKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKcj"]
            let editor = FTPProfileEditorController(profile: p, password: "s3cret pass", folders: ["Work"], isNew: true)
            try expect(editor.savePasswordBox.nextKeyView != nil, "savePasswordBox has nextKeyView")
            var saved: (FTPProfile, String?)?
            var cancelled = false
            editor.onSave = { saved = ($0, $1) }
            editor.onCancel = { cancelled = true }
            editor.commandsView.string = "SITE UMASK 022\n   \n"
            let (read, password) = editor.read()
            try expect(read.commandsAfterLogin == ["SITE UMASK 022"] && password == "s3cret pass", "read")
            // Test connection: success, then a wrong password.
            send(editor, "testConnection")
            wait { editor.testResult.stringValue.hasPrefix("Connected") }
            try expect(editor.testResult.stringValue.hasPrefix("Connected"), "test: \(editor.testResult.stringValue)")
            editor.passwordField.stringValue = "wrong"
            send(editor, "testConnection")
            wait { editor.testResult.stringValue.contains("Login failed") }
            try expect(editor.testResult.stringValue.contains("Login failed"), "failed test: \(editor.testResult.stringValue)")
            editor.passwordField.stringValue = "s3cret pass"
            // Security, pin, anonymous, password display.
            editor.securityPopup.selectItem(at: 2)
            send(editor, "securityChanged")
            send(editor, "forgetPinned")
            editor.anonymousBox.state = .on
            send(editor, "anonymousChanged")
            try expect(!editor.userField.isEnabled, "anonymous disables the user")
            editor.anonymousBox.state = .off
            send(editor, "anonymousChanged")
            send(editor, "togglePassword")
            send(editor, "togglePassword")
            // SFTP: key login with a chosen key file, then password login.
            editor.protocolPopup.selectItem(at: 1)
            send(editor, "protocolChanged")
            Modal.answerPanel = { _ in [URL(fileURLWithPath: NSHomeDirectory() + "/.ssh/test_key")] }
            send(editor, "chooseKeyFile")
            try expect(editor.keyFileField.stringValue == "~/.ssh/test_key", "key file: \(editor.keyFileField.stringValue)")
            send(editor, "forgetPinned")
            editor.authPopup.selectItem(at: 1)
            send(editor, "authChanged")
            // A problem keeps the dialog; a valid profile is saved; Cancel reports.
            editor.nameField.stringValue = ""
            send(editor, "okPressed")
            try expect(saved == nil && editor.testResult.stringValue.contains("session name"), "problem shown")
            editor.nameField.stringValue = "Saved"
            send(editor, "okPressed")
            try expect(saved?.0.name == "Saved" && saved?.0.isSFTP == true, "saved")
            send(editor, "cancelPressed")
            try expect(cancelled, "cancel")
        }

        testRunner("UI: connection manager — folders, new/URL/duplicate/edit/delete, password prompt, help") {
            defer { resetAnswers() }
            let server = try FTPTests.TestServer()
            defer { server.stop() }
            let view = commander()
            let suite = "Coverage-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let ftp = view.ftp
            ftp.repository = FTPProfileRepository(defaults: defaults, credentials: MemoryCredentialStore())
            ftp.runSynchronously = true
            let manager = ftp.managerWindow
            manager.present()
            try expect(manager.window?.title == AppWindows.title("Connect to FTP server"), "title starts with the app name")
            try expect(!manager.connectButton.isEnabled && !manager.editButton.isEnabled && !manager.duplicateButton.isEnabled
                       && !manager.deleteButton.isEnabled, "nothing selected: Connect/Duplicate/Edit/Delete greyed out")
            answer(.alertFirstButtonReturn, text: "Work")
            send(manager, "newFolder")
            try expect(ftp.repository.folders == ["Work"], "folder")
            manager.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            manager.newProfile()
            guard let editor = manager.editor else { throw Fail(description: "no editor") }
            try expect(editor.folderPopup.titleOfSelectedItem == "Work", "new profile goes into the selected folder")
            try expect(manager.deleteButton.isEnabled && !manager.editButton.isEnabled && !manager.connectButton.isEnabled,
                       "a folder can be deleted, not edited or connected")
            var p = server.profile()
            p.folder = "Work"
            p.savePassword = false
            ftp.repository.save(p, password: nil)
            send(editor, "cancelPressed")
            manager.reload(select: p.id)
            try expect(manager.connectButton.isEnabled && manager.editButton.isEnabled && manager.duplicateButton.isEnabled
                       && manager.deleteButton.isEnabled, "a connection enables every button")
            let cell = manager.outlineView(manager.outline, viewFor: manager.outline.tableColumns[0],
                                           item: manager.outline.item(atRow: manager.outline.selectedRow)!) as? NSTableCellView
            try expect(cell?.textField?.stringValue == p.name, "name cell: \(String(describing: cell?.textField?.stringValue))")
            // No saved password: asked for it, then connected (not saved: the profile doesn't save passwords).
            answer(.alertFirstButtonReturn, text: "s3cret pass")
            manager.connectSelected()
            try expect(view.rightView.model.isRemote || view.leftView.model.isRemote, "connected after the password prompt")
            try expect(ftp.repository.credentials.password(for: p.id) == nil, "not saved when unticked")
            ftp.disconnectActive()
            // Ticked "Save password in Keychain": saved once the login works, and not asked again.
            Modal.answerAlert = { alert in
                (alert.accessoryView as? NSTextField)?.stringValue = "s3cret pass"
                alert.suppressionButton?.state = .on
                return .alertFirstButtonReturn
            }
            manager.reload(select: p.id)
            manager.connectSelected()
            try expect(ftp.repository.credentials.password(for: p.id) == "s3cret pass" && ftp.repository.profile(p.id)?.savePassword == true,
                       "password saved from the prompt")
            ftp.disconnectActive()
            answer(.cancel)
            manager.reload(select: p.id)
            manager.connectSelected()
            try expect(view.rightView.model.isRemote || view.leftView.model.isRemote, "connected with the saved password, no prompt")
            ftp.disconnectActive()
            answer(.alertFirstButtonReturn, text: "ftp://u:pw@files.example.com/x")
            send(manager, "newURL")
            try expect(manager.editor?.hostField.stringValue == "files.example.com", "editor from URL")
            if let e = manager.editor { send(e, "cancelPressed") }
            answer(.alertFirstButtonReturn, text: "nonsense")
            send(manager, "newURL")
            try expect(manager.status.stringValue.contains("not an ftp"), "bad URL")
            manager.reload(select: p.id)
            send(manager, "duplicate")
            try expect(ftp.repository.profiles.count == 2 && manager.editor != nil, "duplicate opens the editor")
            if let e = manager.editor { send(e, "okPressed") }
            answer(.alertFirstButtonReturn)
            manager.reload(select: p.id)
            send(manager, "deleteSelected")
            try expect(ftp.repository.profile(p.id) == nil, "profile deleted")
            manager.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            send(manager, "deleteSelected")
            try expect(ftp.repository.folders.isEmpty, "folder deleted")
            manager.close()
        }

        testRunner("UI: FTP controller — default dialogs, background work, certificate trust, root/home, view/open, reveal") {
            defer { resetAnswers() }
            let plain = commander()
            let fresh = FTPController(commander: plain)
            answer(.alertSecondButtonReturn)
            fresh.showMessage("Title", "Text")
            try expect(fresh.askTrust("cert") && fresh.askHostKeyTrust("key"), "default trust dialogs answer")
            // A TLS server with a self-signed certificate: the trust dialog is offered (declined, then accepted).
            let dir = try tempDir("TLSTrust")
            defer { try? FileManager.default.removeItem(at: dir) }
            try SFTPTests.TestSSHServer.tool("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=localhost", "-keyout", dir.appendingPathComponent("k.pem").path, "-out", dir.appendingPathComponent("c.pem").path])
            let port = Int.random(in: 30000...60000)
            let tls = Process()
            tls.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            tls.arguments = ["s_server", "-accept", String(port), "-cert", dir.appendingPathComponent("c.pem").path,
                             "-key", dir.appendingPathComponent("k.pem").path, "-quiet"]
            tls.standardInput = Pipe(); tls.standardOutput = FileHandle.nullDevice; tls.standardError = FileHandle.nullDevice
            try tls.run()
            defer { tls.terminate() }
            Thread.sleep(forTimeInterval: 0.5)
            var p = FTPProfile()
            p.name = "TLS"; p.host = "127.0.0.1"; p.port = port; p.username = "u"; p.security = .implicitTLS
            let view = commander()
            let ftp = view.ftp
            let suite = "Coverage-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            ftp.repository = FTPProfileRepository(defaults: defaults, credentials: MemoryCredentialStore())
            var asked = 0
            ftp.askTrust = { _ in asked += 1; return asked > 1 }
            var outcome: Result<Void, FTPError>?
            ftp.connect(p, password: "x", side: .left) { outcome = $0 }
            wait(20) { outcome != nil }
            try expect(asked == 1, "trust offered: \(String(describing: outcome))")
            outcome = nil
            ftp.connect(p, password: "x", side: .left) { outcome = $0 }
            wait(20) { asked >= 2 }
            try expect(asked >= 2, "accepted: pinned and retried")
            // Background navigation on a real FTP server: root, home, view, open, reveal.
            let server = try FTPTests.TestServer()
            defer { server.stop() }
            outcome = nil
            ftp.connect(server.profile(), password: "s3cret pass", side: .right) { outcome = $0 }
            wait { outcome != nil }
            guard case .success = outcome else { throw Fail(description: "connect: \(String(describing: outcome))") }
            let right = view.rightView
            view.activate(.right)
            view.perform(.goRoot)
            wait { RemoteSession.path(of: right.model.directory) == "/" }
            try expect(RemoteSession.path(of: right.model.directory) == "/", "root")
            guard let session = ftp.session(for: right) else { throw Fail(description: "session") }
            var opened: URL?
            Modal.opened = { opened = $0 }
            defer { Modal.opened = { _ in } }
            _ = ftp.reveal(session.url(for: "/www/index.html"), in: right)
            wait { right.model.currentEntry?.name == "index.html" }
            try expect(right.model.currentEntry?.name == "index.html", "revealed")
            view.perform(.open)
            wait { opened != nil }
            try expect(opened?.lastPathComponent == "index.html", "opened with the default app")
            ftp.viewRemote(session.url(for: "/www/index.html"), size: 18)
            wait { NSApp.windows.contains { $0.title.contains("index.html") && $0.isVisible } }
            ftp.viewRemote(URL(string: "ccftp://00000000-0000-0000-0000-000000000000/x")!, size: nil)
            view.perform(.goHome)
            try expect(!right.model.isRemote, "home leaves the server")
            for w in NSApp.windows where w.title.contains("index.html") { w.close() }
        }

        testRunner("UI: Queue window — present, file statuses, remove completed, cancel, retry, clear") {
            let server = try FTPTests.TestServer()
            defer { server.stop() }
            let manager = TransferManager()
            manager.runSynchronously = true
            let suite = "Queue-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let window = TransfersWindowController(manager: manager, defaults: defaults)
            let session = RemoteSession(client: FTPClient(profile: server.profile(), password: "s3cret pass"))
            let local = try tempDir("TW")
            defer { try? FileManager.default.removeItem(at: local) }
            let job = TransferJob(title: "mixed", items: [
                TransferItem(source: .remote(session, "/www/index.html"), destination: .local(local.appendingPathComponent("ok.html")), size: 18, isFolder: false),
                TransferItem(source: .remote(session, "/www/missing.txt"), destination: .local(local.appendingPathComponent("no.txt")), size: 1, isFolder: false),
            ], isMove: false)
            manager.enqueue(job)
            window.present()
            window.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            send(window, "tableViewSelectionDidChange:", Notification(name: NSTableView.selectionDidChangeNotification))
            try expect(window.fileRows == [0, 1], "both files listed")
            func cellText(_ column: Int, _ row: Int) -> String {
                (window.tableView(window.files, viewFor: window.files.tableColumns[column], row: row) as? NSTextField)?.stringValue ?? ""
            }
            try expect(cellText(0, 0) == "Copied" && cellText(0, 1).hasPrefix("Failed") && cellText(1, 0).hasSuffix("ok.html"),
                       "statuses: \(cellText(0, 0)) / \(cellText(0, 1))")
            try expect(cellText(2, 0) == "18 B", "size: \(cellText(2, 0))")
            window.sizeFormat = .bytes
            try expect(cellText(2, 0) == "18 bytes", "size in bytes")
            window.removeCompletedBox.state = .on
            window.removeCompletedToggled()
            try expect(defaults.bool(forKey: "queue.removeCompleted") && window.fileRows == [1], "copied files hidden: \(window.fileRows)")
            try expect(window.tableView(window.files, viewFor: nil, row: 9) == nil, "no such row")
            // Statuses while a job runs.
            let pending = TransferJob(title: "p", items: [TransferItem(source: .local(local), destination: .local(local), size: 10, isFolder: false),
                                                          TransferItem(source: .local(local), destination: .local(local), size: 0, isFolder: true)], isMove: true)
            pending.active = [0]
            pending.partial[0] = 5
            try expect(TransfersWindowController.status(of: pending, at: 0).0 == "Moving 50 %", "\(TransfersWindowController.status(of: pending, at: 0))")
            try expect(TransfersWindowController.status(of: pending, at: 1).0 == "Pending", "pending")
            pending.results[1] = .done
            pending.results[0] = .skipped("the target exists")
            try expect(TransfersWindowController.status(of: pending, at: 1).0 == "Created"
                       && TransfersWindowController.status(of: pending, at: 0).0.hasPrefix("Skipped"), "folder created, file skipped")
            pending.state = .cancelled
            pending.results[0] = .pending
            pending.active = []
            try expect(TransfersWindowController.status(of: pending, at: 0).0 == "Not done", "cancelled")
            window.removeCompletedBox.state = .off
            window.removeCompletedToggled()
            _ = window.tableView(window.table, viewFor: window.table.tableColumns[1], row: 0)
            _ = window.tableView(window.table, viewFor: window.table.tableColumns[2], row: 0)
            _ = window.tableView(window.table, viewFor: window.table.tableColumns[3], row: 0)
            _ = window.tableView(window.table, viewFor: window.table.tableColumns[0], row: 0)
            send(window, "retrySelected")
            try expect(manager.jobs.count == 2, "retry queued")
            send(window, "cancelSelected")
            let escEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                           isARepeat: false, keyCode: 53)!
            try expect(window.handleKey(escEvent), "escape closes when finished")
            send(window, "clearFinished")
            try expect(manager.jobs.isEmpty, "cleared")
            window.close()
        }

        testRunner("UI: Modal — hooks, real sheets ended programmatically, panel URLs, launch results") {
            defer { resetAnswers() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            answer(.alertFirstButtonReturn)
            try expect(Modal.run(NSAlert()) == .alertFirstButtonReturn, "run answered")
            var got: NSApplication.ModalResponse?
            Modal.sheet(NSAlert(), for: window) { got = $0 }
            try expect(got == .alertFirstButtonReturn, "sheet answered")
            // Without hooks: a real sheet, ended by code.
            Modal.answerAlert = nil
            Modal.answerPanel = nil
            let alert = NSAlert()
            got = nil
            Modal.sheet(alert, for: window) { got = $0 }
            window.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
            wait(2) { got != nil }
            try expect(got == .alertSecondButtonReturn, "real sheet: \(String(describing: got))")
            let panel = NSSavePanel()
            var urls: [URL]?
            Modal.choose(panel, for: window) { urls = $0 }
            window.endSheet(panel, returnCode: .cancel)
            wait(2) { urls != nil }
            try expect(urls == [], "cancelled panel")
            resetAnswers()
            try expect(Modal.urls(of: NSOpenPanel()).isEmpty && Modal.urls(of: NSSavePanel()).count <= 1, "panel URLs")
            var chosen: [URL]?
            Modal.PanelResult(panel: NSSavePanel(), completion: { chosen = $0 }).finished(.OK)
            try expect(chosen != nil, "panel result")
            var failure: Error?
            Modal.LaunchResult(failed: { failure = $0 }).finished(nil, FTPError.timeout)
            Modal.LaunchResult(failed: { failure = $0 }).finished(nil, nil)
            try expect((failure as? FTPError) == .timeout, "launch error reported")
            var launched: TerminalLauncher.Launch?
            Modal.launched = { launched = $0 }
            Modal.launch(.openFolder(app: URL(fileURLWithPath: "/x.app"), folder: URL(fileURLWithPath: "/")), failed: { _ in })
            try expect(launched != nil, "launch hook")
            Modal.launched = { _ in }
            var terminated = false
            Modal.terminated = { terminated = true }
            Modal.terminate()
            Modal.terminated = {}
            try expect(terminated, "terminate hook")
            var opened: URL?
            Modal.opened = { opened = $0 }
            Modal.open(URL(fileURLWithPath: "/tmp"))
            Modal.opened = { _ in }
            try expect(opened != nil, "open hook")
        }
    }

    // MARK: - Panels and windows

    static func runPanelAndWindows(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("UI: panel mouse — buttons, drive bar, header sort, click, shift-click, double-click, right-drag, wheel") {
            let dir = try tempDir("Mouse")
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
            for i in 0..<40 { try Data(repeating: 1, count: i).write(to: dir.appendingPathComponent(String(format: "f%02d.txt", i))) }
            let (window, view) = windowed(dir)
            defer { window.close() }
            let panel = view.leftView
            var menus = 0
            Modal.poppedUp = { _ in menus += 1 }
            defer { Modal.poppedUp = { _ in } }
            try expect(view.acceptsFirstResponder && !panel.acceptsFirstResponder && panel.acceptsFirstMouse(for: nil), "keys go to the commander, clicks to the panel")
            _ = panel.menuAnchor
            let l = panel.layoutInfo
            panel.mouseDown(with: mouse(.leftMouseDown, at: center(l.driveBar), in: panel))
            try expect(menus == 1, "drive bar opens the location menu")
            panel.mouseDown(with: mouse(.leftMouseDown, at: center(l.header).applying(.init(translationX: -l.header.width / 2 + 20, y: 0)), in: panel))
            try expect(!panel.model.sortOrder.ascending, "header click sorts")
            let row = { (i: Int) in NSPoint(x: l.rows.midX, y: l.rows.minY + CGFloat(i) * 20 + 5) }
            panel.mouseDown(with: mouse(.leftMouseDown, at: row(2), in: panel))
            try expect(panel.model.cursor == 2, "click moves the cursor: \(panel.model.cursor)")
            panel.mouseDown(with: mouse(.leftMouseDown, at: row(4), in: panel, flags: .shift))
            try expect(panel.model.marked.count >= 2, "shift-click marks a range")
            panel.mouseDown(with: mouse(.rightMouseDown, at: row(6), in: panel, flags: .control))
            panel.mouseDragged(with: mouse(.leftMouseDragged, at: row(8), in: panel))
            panel.rightMouseDragged(with: mouse(.rightMouseDragged, at: NSPoint(x: l.rows.midX, y: l.rows.maxY + 5), in: panel))
            panel.rightMouseDragged(with: mouse(.rightMouseDragged, at: NSPoint(x: l.rows.midX, y: l.rows.minY - 5), in: panel))
            panel.mouseUp(with: mouse(.leftMouseUp, at: row(8), in: panel))
            panel.rightMouseDown(with: mouse(.rightMouseDown, at: row(9), in: panel))
            panel.rightMouseUp(with: mouse(.rightMouseUp, at: row(9), in: panel))
            let wheel = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -5, wheel2: 0, wheel3: 0)!)!
            panel.scrollWheel(with: wheel)
            let pixels = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -45, wheel2: 0, wheel3: 0)!)!
            panel.scrollWheel(with: pixels)
            panel.mouseDown(with: mouse(.leftMouseDown, at: row(0), in: panel, clicks: 2))
            panel.mouseDown(with: mouse(.leftMouseDown, at: center(l.hotlistButton), in: panel))
            panel.mouseDown(with: mouse(.leftMouseDown, at: center(l.downloadsButton), in: panel))
            let downloads = (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")).standardizedFileURL
            try expect(panel.model.directory == downloads, "downloads button")
            panel.mouseDown(with: mouse(.leftMouseDown, at: center(l.rootButton), in: panel))
            try expect(panel.model.directory.path == "/", "root button")
            panel.mouseDown(with: mouse(.leftMouseDown, at: center(l.homeButton), in: panel))
            try expect(panel.model.directory == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL, "home button")
            // A panel without a commander navigates by itself.
            let solo = PanelView(model: PanelModel(directory: dir))
            solo.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
            let sl = solo.layoutInfo
            solo.mouseDown(with: mouse(.leftMouseDown, at: center(sl.hotlistButton), in: solo))
            solo.mouseDown(with: mouse(.leftMouseDown, at: center(sl.downloadsButton), in: solo))
            solo.mouseDown(with: mouse(.leftMouseDown, at: center(sl.rootButton), in: solo))
            solo.mouseDown(with: mouse(.leftMouseDown, at: center(sl.homeButton), in: solo))

            // Double-clicking path bar opens in-place path editor; typing path navigates with *.* by default
            let pathCenter = NSPoint(x: l.pathBar.midX, y: l.pathBar.midY)
            panel.mouseDown(with: mouse(.leftMouseDown, at: pathCenter, in: panel, clicks: 1))
            try expect(panel.pathField == nil, "single click on path bar does not edit")
            panel.mouseDown(with: mouse(.leftMouseDown, at: pathCenter, in: panel, clicks: 2))
            try expect(panel.pathField != nil, "double-clicking path bar opens path editor")
            try expect(panel.pathField?.stringValue.hasSuffix("*.*") == true, "shows *.* by default")

            // Parsing paths and masks
            let p1 = PanelView.parsePathAndMask("/tmp", currentDirectory: dir.path)
            try expect(p1.directory == "/private/tmp" || p1.directory == "/tmp", "path without mask: \(p1.directory)")
            try expect(p1.mask == nil, "default mask is nil (*.*)")
            let p2 = PanelView.parsePathAndMask("/tmp/*.*", currentDirectory: dir.path)
            try expect((p2.directory == "/private/tmp" || p2.directory == "/tmp") && p2.mask == "*.*", "path with *.*")
            let p3 = PanelView.parsePathAndMask("/tmp/*.json", currentDirectory: dir.path)
            try expect((p3.directory == "/private/tmp" || p3.directory == "/tmp") && p3.mask == "*.json", "path with *.json")
            let p4 = PanelView.parsePathAndMask("*.swift", currentDirectory: dir.path)
            try expect(p4.directory == dir.path && p4.mask == "*.swift", "mask alone")

            // Commit path
            panel.commitPath(dir.path)
            try expect(panel.model.directory.resolvingSymlinksInPath() == dir.resolvingSymlinksInPath(), "navigated to dir")
            try expect(panel.model.showFilter == .all, "default mask is *.*")
            panel.commitPath("*.txt")
            try expect(panel.model.showFilter == .mask("*.txt"), "custom mask specified")
            try expect(panel.model.showFilter.maskString == "*.txt", "mask string matches")
            panel.commitPath(dir.path)
            try expect(panel.model.showFilter == .all, "navigating to dir resets to *.* default unless specified")
            panel.commitPath(dir.path + "/*.txt")
            try expect(panel.model.showFilter == .mask("*.txt"), "dir with mask")
            let beforeDir = panel.model.directory
            panel.commitPath("/nonexistent_directory_12345")
            try expect(panel.model.directory == beforeDir, "nonexistent path refused")
            panel.beginEditPath()
            _ = panel.pathField?.control(panel.pathField!, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            try expect(panel.pathField == nil, "Esc cancels path editing")

            // Drawing with search results shown (path bar names the results).
            panel.model.showSearchResults([dir.appendingPathComponent("f01.txt")], title: "found", visibleRows: 20)
            _ = view.bitmapImageRepForCachingDisplay(in: view.bounds).map { view.cacheDisplay(in: view.bounds, to: $0) }
        }

        testRunner("UI: commander — hints, custom filter, terminal, folder sizes, function key bar") {
            defer { resetAnswers() }
            let dir = try tempDir("Commander")
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
            try Data(count: 10).write(to: dir.appendingPathComponent("folder/x.bin"))
            try Data(count: 3).write(to: dir.appendingPathComponent("a.txt"))
            let (window, view) = windowed(dir)
            defer { window.close() }
            view.showHint("hello", duration: 0.05)
            wait(1) { false }
            answer(.alertFirstButtonReturn, text: "*.txt")
            view.perform(.showCustomFilter)
            try expect(view.activeView.model.showFilter == .mask("*.txt"), "custom filter")
            answer(.cancel)
            view.perform(.showCustomFilter)
            var launched: TerminalLauncher.Launch?
            Modal.launched = { launched = $0 }
            defer { Modal.launched = { _ in } }
            view.perform(.openTerminal)
            try expect(launched != nil, "terminal launched")
            var opened: URL?
            Modal.opened = { opened = $0 }
            defer { Modal.opened = { _ in } }
            view.perform(.openInFinder)
            try expect(opened?.path == view.activeView.model.directory.path, "folder opened in Finder: \(String(describing: opened))")
            view.terminalFailed(FTPError.timeout)
            // Folder sizes in the background; leaving the folder cancels pending work.
            view.activeView.model.setShowFilter(.all, visibleRows: 20)
            view.activeView.model.focus(name: "folder", visibleRows: 20)
            view.perform(.toggleSelection)
            wait(5) { view.activeView.model.folderSize(for: view.activeView.model.entries.first { $0.name == "folder" }!) != nil }
            try expect(view.activeView.model.folderSize(for: view.activeView.model.entries.first { $0.name == "folder" }!) == 10, "folder size")
            view.activeView.model.focus(name: "folder", visibleRows: 20)
            view.perform(.toggleSelection)
            view.perform(.parentFolder)
            _ = view.bitmapImageRepForCachingDisplay(in: view.bounds).map { view.cacheDisplay(in: view.bounds, to: $0) }
            // Function key bar: draw, press and release on the first button.
            let bar = view.functionBar
            try expect(bar.acceptsFirstMouse(for: nil), "first mouse")
            var pressed: CommandAction?
            bar.onAction = { pressed = $0 }
            let first = NSPoint(x: bar.bounds.width / CGFloat(bar.shownActions.count * 2), y: bar.bounds.midY)
            bar.mouseDown(with: mouse(.leftMouseDown, at: first, in: bar))
            bar.mouseUp(with: mouse(.leftMouseUp, at: first, in: bar))
            try expect(pressed == bar.shownActions.first, "button pressed: \(String(describing: pressed))")
            _ = bar.bitmapImageRepForCachingDisplay(in: bar.bounds).map { bar.cacheDisplay(in: bar.bounds, to: $0) }
        }

        testRunner("UI: Quick Search, Lister and diff windows — keys, monitors, modes") {
            let dir = try tempDir("Windows")
            defer { try? FileManager.default.removeItem(at: dir) }
            for n in ["alpha.txt", "beta.txt", "alps.txt"] { try Data(n.utf8).write(to: dir.appendingPathComponent(n)) }
            let (window, view) = windowed(dir)
            defer { window.close() }
            let quick = view.quickSearch
            quick.open(in: view.activeView, mode: .search, text: "al")
            quick.jump(forward: true)
            quick.jump(forward: false)
            quick.field.stringValue = "be"
            quick.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            let tv = NSTextView()
            _ = quick.control(quick.field, textView: tv, doCommandBy: #selector(NSResponder.moveDown(_:)))
            _ = quick.control(quick.field, textView: tv, doCommandBy: #selector(NSResponder.moveUp(_:)))
            NSApp.sendEvent(key(1, "s", .control, window: window))        // ⌃S switches mode (through the key monitor)
            quick.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
            _ = quick.control(quick.field, textView: tv, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            // Lister: modes, encoding, wrap, find, hex rows, its key monitor.
            let lister = ListerWindowController(files: [dir.appendingPathComponent("alpha.txt"), dir.appendingPathComponent("beta.txt")], index: 0)
            var navigated: URL?
            lister.onNavigate = { url in navigated = url }
            lister.present()
            send(lister, "modeClicked")
            lister.show(mode: .hex)
            _ = lister.tableView(NSTableView(), viewFor: nil, row: 0)
            send(lister, "encodingChosen")
            send(lister, "toggleWrap")
            NSApp.sendEvent(key(3, "f", [], window: lister.window))     // f: find bar
            NSApp.sendEvent(key(45, "n", [], window: lister.window))    // n: next file
            try expect(navigated == dir.appendingPathComponent("beta.txt"), "n moved to beta.txt and called onNavigate")
            NSApp.sendEvent(key(35, "p", [], window: lister.window))    // p: previous file
            try expect(navigated == dir.appendingPathComponent("alpha.txt"), "p moved to alpha.txt and called onNavigate")
            lister.window?.close()
            // Diff: binary result, an error, keys and synchronized scrolling.
            let diff = DiffWindowController(leftTitle: "/a", rightTitle: "/b")
            diff.show(.binary(identical: false, firstDifference: 5))
            try expect(diff.statusLabel.stringValue.contains("byte 5"), diff.statusLabel.stringValue)
            diff.showError("broken")
            diff.show(.text(TextDiff(left: (0..<200).map(String.init), right: (0..<200).map { $0 == 150 ? "x" : String($0) })))
            diff.leftText.keyDown(with: key(45, "n"))
            diff.leftText.keyDown(with: key(35, "p"))
            diff.leftText.keyDown(with: key(125, "", .option))
            diff.leftText.keyDown(with: key(0, "a"))
            diff.leftText.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 40))
            diff.leftText.keyDown(with: key(53, "\u{1b}"))
        }

        testRunner("UI: Options and Shortcuts — terminal, transfers, export/import, preview, recording keys") {
            defer { resetAnswers() }
            let suite = "Coverage-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            let options = OptionsWindowController(store: store)
            options.present()
            try expect(options.window?.initialFirstResponder === options.searchField, "searchField is initialFirstResponder")
            let isSearchFocused = options.window?.firstResponder === options.searchField
                || (options.window?.firstResponder as? NSTextView)?.delegate === options.searchField
                || options.window?.firstResponder is NSTextView
            try expect(isSearchFocused, "searchField is autofocused on present")
            options.showPage(options.pageIndex(for: "Quick Search") ?? 2)
            try expect(options.visiblePageTitle == "Quick Search", "on quick search")
            try expect(store.settings.quickSearch.filterByDefault == true, "filterByDefault is true by default")
            let filterBox = try CommanderTests.findView(NSButton.self, in: options.window!.contentView!, where: { $0.title.contains("Filter files by default") })
            filterBox.state = .off
            send(options, "quickSearchChanged")
            try expect(store.settings.quickSearch.filterByDefault == false, "filterByDefault saved as false")
            filterBox.state = .on
            send(options, "quickSearchChanged")
            try expect(store.settings.quickSearch.filterByDefault == true, "filterByDefault saved as true")

            options.showPage(options.pageIndex(for: "FTP") ?? 3)
            try expect(options.visiblePageTitle == "FTP", "on FTP page")
            var ftpOpened = false
            options.onOpenFTPManager = { ftpOpened = true }
            options.openFTPManagerPressed()
            try expect(ftpOpened, "open FTP manager pressed")

            send(options, "quickSearchChanged")
            options.terminalPopup.selectItem(withTitle: "Other…")
            Modal.answerPanel = { _ in [URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")] }
            options.terminalChosen()
            options.terminalPopup.selectItem(withTitle: "Other…")
            Modal.answerPanel = { _ in [] }
            options.terminalChosen()
            options.transferFields[0].integerValue = 5
            options.transfersChanged(options.transferFields[0])
            try expect(store.settings.operation.maxTransfers == 5, "transfers saved")
            options.holdField.doubleValue = 1.26
            options.holdChanged(options.holdField)
            try expect(store.settings.operation.contextMenuHold == 1.3, "hold time saved, one decimal")
            options.holdField.doubleValue = 50
            options.holdChanged(options.holdField)
            try expect(store.settings.operation.contextMenuHold == 10, "hold time capped")
            options.finderPanelPopup.selectItem(at: 1)
            options.finderPanelChosen()
            try expect(store.settings.operation.finderOpensIn == .right, "Finder panel saved")
            options.tabBarPopup.selectItem(at: 1)
            options.sizeFormatPopup.selectItem(at: 0)
            send(options, "displayToggled")
            try expect(store.settings.display.sizeFormat == .bytes && store.settings.display.tabBar == .always, "size format and tab bar saved")
            // Search: pages that mention it stay listed, matches are highlighted, Shortcuts filters too.
            options.searchField.stringValue = "hidden files"
            options.searchChanged()
            try expect(options.visiblePageTitle == "Display" && !options.highlighted.isEmpty, "found on Display: \(String(describing: options.visiblePageTitle))")
            options.searchField.stringValue = "refresh"
            options.searchChanged()
            try expect(options.visiblePageTitle == "Operation" || options.visiblePageTitle == "Shortcuts", "refresh: \(String(describing: options.visiblePageTitle))")
            options.searchField.stringValue = "zzqqxx nothing"
            options.searchChanged()
            try expect(options.highlighted.isEmpty, "no match")
            options.searchField.stringValue = ""
            options.searchChanged()
            try expect(options.highlighted.isEmpty && OptionsWindowController.matches("Show Hidden", ["hidden", "show"]), "cleared")
            options.showPage(0)
            options.autoRefreshPopup.selectItem(at: 2)
            options.autoRefreshChosen()
            try expect(store.settings.operation.autoRefresh == .everything, "auto refresh saved")
            options.maskFoldersCheckbox.state = .off
            options.renameExtensionCheckbox.state = .on
            send(options, "operationToggled")
            try expect(!store.settings.operation.maskSelectsFolders && store.settings.operation.renameSelectsExtension, "rename / mask options saved")
            options.hideOthersCheckbox.state = .on
            send(options, "operationToggled")
            try expect(store.settings.operation.selectionHidesOthers, "hide others saved")
            // A quick location saved from the panels while Options is open survives Options' own changes.
            var withLocation = store.settings
            withLocation.quickLocations = [QuickLocation(name: "Kept", path: "/tmp")]
            store.save(withLocation)
            options.hideOthersCheckbox.state = .off
            send(options, "operationToggled")
            try expect(store.settings.quickLocations.map(\.name) == ["Kept"] && !store.settings.operation.selectionHidesOthers,
                       "Options keeps quick locations saved meanwhile")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("opts-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            Modal.answerPanel = { _ in [file] }
            send(options, "exportPressed")
            try expect(FileManager.default.fileExists(atPath: file.path), "exported")
            send(options, "importPressed")
            try Data("not json".utf8).write(to: file)
            send(options, "importPressed")                            // error is reported
            Modal.answerPanel = { _ in [URL(fileURLWithPath: "/nonexistent/settings.json")] }
            send(options, "importPressed")
            answer(.alertSecondButtonReturn)
            try expect(OptionsWindowController(store: store).confirmTerminalChange("cmd"), "default confirmation dialog")
            func previews(_ v: NSView) -> [NSView] { (String(describing: type(of: v)) == "PreviewPair" ? [v] : []) + v.subviews.flatMap(previews) }
            for p in previews(options.window!.contentView!) { _ = p.hitTest(NSPoint(x: 5, y: 5)) }
            // Shortcuts: filter typing, record a key through the monitor, remove.
            let page = options.shortcutsPage
            options.showPage(options.pageIndex(for: "Shortcuts") ?? 5)
            page.select(.refresh)
            page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            page.addPressed()
            NSApp.sendEvent(key(15, "r", [.control, .option], window: options.window))
            try expect(page.bindings.keys(for: .refresh).contains(KeyCombo(15, [.control, .option])), "recorded through the monitor")
            page.select(.refresh)
            send(page, "removePressed")
            try expect(page.bindings.keys(for: .refresh).isEmpty, "removed")

            // Test removing a single shortcut from an action with multiple shortcuts (e.g. parentFolder)
            page.select(.parentFolder)
            let parentKeys = page.bindings.keys(for: .parentFolder)
            try expect(parentKeys.count >= 2, "parentFolder has multiple shortcuts")
            let firstKey = parentKeys[0]
            page.removeSingle(combo: firstKey, from: .parentFolder)
            try expect(!page.bindings.keys(for: .parentFolder).contains(firstKey), "first key removed")
            try expect(page.bindings.keys(for: .parentFolder).count == parentKeys.count - 1, "other shortcuts preserved")
            options.window?.close()
        }

        testRunner("UI: menu-bar icon, file-operation dialogs, conflicts from the background") {
            defer { resetAnswers() }
            let status = StatusBarController()
            var opened = false, quit = false
            status.onOpenWindow = { opened = true }
            status.onQuitRequested = { quit = true }
            _ = status.currentStatusItem
            status.updateIcon()
            _ = StatusBarController.renderBadgeIcon(isDark: true)
            status.refreshMenu()
            send(status, "openWindowAction")
            send(status, "quitAction")
            try expect(opened && quit, "menu actions")
            status.onQuitRequested = nil
            var terminated = false
            Modal.terminated = { terminated = true }
            send(status, "quitAction")
            Modal.terminated = {}
            try expect(terminated, "quit without a handler")
            status.cleanup()
            // The real alert prompts, answered by the hooks.
            let prompts = AlertPrompts()
            answer(.alertFirstButtonReturn, text: "/tmp/x")
            try expect(prompts.askText(title: "t", message: "m", defaultValue: "d", okTitle: "OK") == "/tmp/x", "ask text")
            try expect(prompts.confirm(title: "t", message: "m", okTitle: "OK"), "confirm")
            let dir = try tempDir("Conflict")
            defer { try? FileManager.default.removeItem(at: dir) }
            let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
            try Data("a".utf8).write(to: a); try Data("bb".utf8).write(to: b)
            prompts.showProblems(title: "t", report: OperationReport())
            // Copy with a conflict, run in the background: the question comes back to the main thread.
            let left = dir.appendingPathComponent("L"), right = dir.appendingPathComponent("R")
            for d in [left, right] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            try Data("new".utf8).write(to: left.appendingPathComponent("same.txt"))
            try Data("old".utf8).write(to: right.appendingPathComponent("same.txt"))
            let view = commander(left)
            view.rightView.model.go(to: right, visibleRows: 20)
            let stub = StubPrompts()
            stub.conflict = .replace
            view.fileCommands.prompts = stub
            view.fileCommands.runInBackground = true
            view.leftView.model.focus(name: "same.txt", visibleRows: 20)
            view.perform(.copy)
            wait(10) { (try? String(contentsOf: right.appendingPathComponent("same.txt"))) == "new" }
            try expect((try? String(contentsOf: right.appendingPathComponent("same.txt"))) == "new", "overwritten after asking")
        }
    }

    // MARK: - Synchronize, Find Files, app delegate

    static func runBigWindows(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("UI: Synchronize window — async compare, marks, clicks, menu, keys, diff, browse, help, confirm, cancel") {
            defer { resetAnswers() }
            let (l, r) = try SyncTests.makePair()
            defer { try? FileManager.default.removeItem(at: l.deletingLastPathComponent()) }
            try Data("one\ntwo\n".utf8).write(to: l.appendingPathComponent("text.txt"))
            try Data("one\nTWO\n".utf8).write(to: r.appendingPathComponent("text.txt"))
            let (window, view) = windowed(l)
            defer { window.close() }
            view.rightView.model.go(to: r, visibleRows: 20)
            let suite = "Coverage-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let dialog = SyncWindowController(commander: view, defaults: defaults)
            dialog.present()
            dialog.maskField.stringValue = "*.txt"
            try click("Compare", in: dialog.window?.contentView)
            wait { !dialog.isComparing && !dialog.visibleRows.isEmpty }
            try expect(!dialog.visibleRows.isEmpty, "compared in the background")
            send(dialog, "optionChanged")
            dialog.table.selectRowIndexes(IndexSet(0..<dialog.visibleRows.count), byExtendingSelection: false)
            for action in ["markLeftToRight", "markRightToLeft", "markDefault", "unmark", "reverse", "markDeleteRight", "markDeleteLeft", "markDefault"] {
                send(dialog, action)
            }
            send(dialog, "tableClicked")
            send(dialog, "tableDoubleClicked")
            dialog.menuNeedsUpdate(NSMenu())
            let both = dialog.visibleRows.firstIndex { $0.left != nil && $0.right != nil && $0.path == "text.txt" }!
            dialog.table.selectRowIndexes(IndexSet(integer: both), byExtendingSelection: false)
            dialog.table.keyDown(with: key(124, ""))
            dialog.table.keyDown(with: key(0, "a"))
            send(dialog, "showLeftInPanel")
            send(dialog, "showRightInPanel")
            dialog.runSynchronously = false
            dialog.viewDifferences()
            wait { NSApp.windows.contains { ($0.windowController as? DiffWindowController)?.diff != nil } }
            for w in NSApp.windows where w.windowController is DiffWindowController { w.close() }
            wait(0.5) { false }                                   // the close observer runs on the main queue
            Modal.answerPanel = { _ in [l] }
            try click(">>", in: dialog.window?.contentView)
            // Confirm and run in the background; then cancel a second confirmation before it starts.
            dialog.runSynchronously = true
            dialog.compare()
            dialog.table.selectRowIndexes(IndexSet(0..<dialog.visibleRows.count), byExtendingSelection: false)
            send(dialog, "markDefault")
            try click("Synchronize…", in: dialog.window?.contentView)
            guard let sheet = dialog.confirmation else { throw Fail(description: "no confirmation") }
            _ = sheet.options
            for column in sheet.table.tableColumns { _ = sheet.tableView(sheet.table, viewFor: column, row: 0) }
            sheet.start()
            wait { dialog.confirmation == nil }
            try expect(dialog.statusLabel.stringValue.contains("Synchronized") || dialog.statusLabel.stringValue.contains("identical")
                       || dialog.statusLabel.stringValue.contains("Files found"), "synchronized: \(dialog.statusLabel.stringValue)")
            try Data("again".utf8).write(to: l.appendingPathComponent("new.txt"))
            dialog.compare()
            try click("Synchronize…", in: dialog.window?.contentView)
            if let second = dialog.confirmation { send(second, "cancel") }
            try click("Close", in: dialog.window?.contentView)
            // A confirmation built with default sessions, deleting locally, run synchronously.
            var cfg = SyncConfiguration(left: l, right: r)
            cfg.asymmetric = true
            try Data("extra".utf8).write(to: r.appendingPathComponent("extra-\(UUID().uuidString.prefix(6)).txt"))
            let plan = SyncPlan(rows: try SyncEngine.compare(cfg).rows, config: cfg)
            let standalone = SyncConfirmationController(plan: plan, config: cfg)
            standalone.runSynchronously = true
            standalone.deleteBox.state = .off
            standalone.start()
        }

        testRunner("UI: Find Files — async search with live results, buttons, steppers, drives, calendar") {
            defer { resetAnswers() }
            let dir = try tempDir("FindUI")
            defer { try? FileManager.default.removeItem(at: dir) }
            for i in 0..<30 { try Data("x".utf8).write(to: dir.appendingPathComponent("f\(i).txt")) }
            let (window, view) = windowed(dir)
            defer { window.close() }
            let suite = "Coverage-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let dialog = FindFilesWindowController(commander: view, defaults: defaults)
            dialog.present()
            dialog.searchFor.stringValue = "*.txt"
            dialog.searchIn.stringValue = dir.path
            dialog.startSearch()
            wait { !dialog.isSearching && dialog.rows.count == 30 }
            try expect(dialog.rows.count == 30, "found in the background: \(dialog.rows.count)")
            send(dialog, "controlChanged")
            send(dialog, "stepped:", NSStepper())
            _ = dialog.tableView(dialog.table, shouldSelectRow: 1)
            dialog.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            dialog.table.keyDown(with: key(0, "a"))
            let content = dialog.window!.contentView!
            Modal.answerPanel = { _ in [dir] }
            try click(">>", in: content)
            var drives: NSMenu?
            Modal.poppedUp = { drives = $0 }
            try click("Drives", in: content)
            Modal.poppedUp = { _ in }
            if let menu = drives, !menu.items.isEmpty { menu.performActionForItem(at: 0) }
            dialog.tabs.selectTabViewItem(at: 1)
            send(dialog, "showCalendar:", dialog.dateFromButton)
            send(dialog, "calendarPicked")
            dialog.tabs.selectTabViewItem(at: 0)
            try click("New search", in: content)
            try click("Cancel", in: content)
        }

        testRunner("UI: windows share the app name in their titles and the theme's colours") {
            try expect(AppWindows.title("Find Files") == AppWindows.appTitle + " - Find Files", "title prefix")
            let transfers = TransfersWindowController(manager: TransferManager())
            try expect(transfers.window?.title == AppWindows.title("Queue"), "secondary windows are prefixed")
            var dark = Theme.standard
            dark.chrome = RGBColor(hex: "#202020")!
            AppWindows.apply(dark)
            defer { AppWindows.apply(.standard) }
            try expect(NSApp.appearance?.name == .darkAqua, "dark window colour: dark controls")
            try expect(RGBColor(transfers.window!.backgroundColor) == dark.chrome, "open windows recoloured")
            AppWindows.apply(.standard)
            try expect(NSApp.appearance?.name == .aqua && RGBColor(transfers.window!.backgroundColor) == Theme.standard.chrome,
                       "light window colour: light controls")
            transfers.close()
        }

        testRunner("UI: app delegate — launch, menus, ticks, commands, options, settings, status icon, quit, reopen") {
            defer { resetAnswers() }
            let suite = "Coverage-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            // Panels open where they were last time; a folder that is gone gives its parent.
            let lastLeft = try tempDir("LastLeft"), lastRight = try tempDir("LastRight")
            defer { try? FileManager.default.removeItem(at: lastLeft); try? FileManager.default.removeItem(at: lastRight) }
            try expect(store.lastFolder(.left) == nil, "nothing remembered yet")
            store.rememberFolder(lastRight.appendingPathComponent("gone/deeper"), side: .right)
            try expect(store.lastFolder(.right)?.path == lastRight.path, "missing folder: nearest existing parent")
            store.rememberFolder(lastLeft, side: .left)
            store.rememberFolder(URL(string: "ccftp://session/www")!, side: .left)
            try expect(store.lastFolder(.left)?.path == lastLeft.path, "server folders aren't remembered")
            store.rememberFolder(lastRight, side: .right)
            let app = AppDelegate(settings: store, windowAutosaveName: "")
            app.activatesApp = false
            let savedMenu = NSApp.mainMenu
            defer { NSApp.mainMenu = savedMenu }
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            guard let commander = app.commanderView, let menu = NSApp.mainMenu else { throw Fail(description: "not launched") }
            try expect(commander.leftView.model.directory.path == lastLeft.path && commander.rightView.model.directory.path == lastRight.path,
                       "both panels reopened in their last folders: \(commander.rightView.model.directory.path)")
            commander.rightView.model.goUp(visibleRows: 20)
            try expect(store.lastFolder(.right)?.path == lastRight.deletingLastPathComponent().path, "a new folder is remembered right away")
            commander.swapPanels()
            try expect(store.lastFolder(.left)?.path == lastRight.deletingLastPathComponent().path
                       && store.lastFolder(.right)?.path == lastLeft.path, "swapping panels swaps the remembered folders")
            for item in menu.items { if let sub = item.submenu { app.menuNeedsUpdate(sub); sub.items.forEach { _ = app.validateMenuItem($0) } } }
            let sort = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            sort.representedObject = CommandAction.sortBySize.rawValue
            send(app, "netCommand:", sort)
            try expect(commander.activeView.model.sortOrder.column == .size, "menu command ran")
            send(app, "showOptions")
            commander.perform(.toggleFolderBrackets)          // saved, notified, applied
            try expect(store.display.showFolderBrackets == false, "setting saved through the delegate")
            app.statusBarController?.onOpenWindow?()
            let testFileURL = URL(fileURLWithPath: "/tmp/classic_commander_open_test.txt")
            app.application(NSApp, open: [testFileURL])
            let pb = NSPasteboard.withUniqueName()
            pb.writeObjects([testFileURL as NSURL])
            var err: NSString?
            app.openInClassicCommander(pb, userData: nil, error: &err)
            var s = store.settings
            s.display.showStatusBarIcon = false
            store.save(s)
            try expect(app.statusBarController == nil, "status icon removed")
            var opened: URL?
            Modal.opened = { opened = $0 }
            commander.onOpenFile?(URL(fileURLWithPath: "/tmp"))
            Modal.opened = { _ in }
            try expect(opened != nil, "files open with their app")
            send(app, "openWindowFromMenu")
            // Close the main window (another window stays open), then click the Dock icon.
            try expect(commander.window?.isReleasedWhenClosed == false, "main window survives closing")
            commander.window?.close()
            try expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true), "reopen")
            try expect(commander.window?.isVisible == true, "the Dock icon brings the main window back")
            try expect(!app.applicationShouldTerminateAfterLastWindowClosed(NSApp), "stays running")
            app.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            var quit = false
            Modal.terminated = { quit = true }
            send(app, "quitPressed")
            send(app, "quitPressed")
            Modal.terminated = {}
            try expect(quit, "double ⌘Q quits")
            commander.window?.close()
            for w in NSApp.windows where w.title == AppWindows.title("Options") { w.close() }
        }

        testRunner("UI: folder sizing (cancel check, cancel on leave), Lister find, terminal failures, host key trust") {
            let dir = try tempDir("Sizing")
            defer { try? FileManager.default.removeItem(at: dir) }
            for name in ["big", "big2"] {
                let sub = dir.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                for i in 0..<600 { FileManager.default.createFile(atPath: sub.appendingPathComponent("f\(i)").path, contents: Data([1])) }
            }
            let view = commander(dir)
            let panel = view.activeView
            panel.model.focus(name: "big", visibleRows: 20)
            view.perform(.toggleSelection)
            view.perform(.parentFolder)                           // leaving cancels the pending size
            panel.model.go(to: dir, visibleRows: 20)
            panel.model.focus(name: "big2", visibleRows: 20)
            view.perform(.toggleSelection)
            wait(10) { panel.model.folderSize(for: panel.model.entries.first { $0.name == "big2" }!) != nil }
            try expect(panel.model.folderSize(for: panel.model.entries.first { $0.name == "big2" }!) == 600, "size of 600 files")
            view.reportTerminalFailure(FTPError.timeout)
            wait(1) { false }
            let lister = ListerWindowController(files: [dir.appendingPathComponent("big/f1")], index: 0)
            lister.present()
            _ = lister.handleKey(key(26, "7"))
            lister.window?.close()
        }

        testRunner("UI Gallery: menu items, submenus, and window presentation") {
            let app = AppDelegate(settings: SettingsStore(), windowAutosaveName: "GalleryTest")
            app.activatesApp = false
            let savedMenu = NSApp.mainMenu
            defer { NSApp.mainMenu = savedMenu }
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            guard let menu = NSApp.mainMenu else { throw Fail(description: "menu not created") }
            let galleryItem = menu.items.first { $0.submenu?.title.contains("UI Gallery") == true }
            try expect(galleryItem != nil, "UI Gallery menu found in main menu")
            guard let galleryMenu = galleryItem?.submenu else { throw Fail(description: "gallery menu nil") }

            let titles = galleryMenu.items.compactMap { $0.submenu?.title ?? $0.title }
            try expect(titles.contains("Windows & Tools"), "Windows & Tools submenu present")
            try expect(titles.contains("Transfer & Operation Popups"), "Transfer & Operation Popups submenu present")
            try expect(titles.contains("Dialogs, Prompts & Alerts"), "Dialogs, Prompts & Alerts submenu present")

            let gallery = UIGallery.shared
            gallery.showGalleryPalette()
            gallery.openAllTools()
            gallery.openAllPopups()
            gallery.openAllDialogs()
            gallery.openAllWindows()
            gallery.closeAllGalleryWindows()
        }
    }
}
