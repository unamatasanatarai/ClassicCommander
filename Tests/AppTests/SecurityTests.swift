import Cocoa

/// Regression tests for the security audit alerts (.audit/security/alerts).
public enum SecurityTests {
    typealias Fail = CommanderTests.TestFailure
    static func expect(_ c: @autoclosure () throws -> Bool, _ m: String) throws {
        if try !c() { throw Fail(description: m) }
    }

    /// A server that answers every listing with one more subfolder (and many files), forever.
    final class EndlessClient: RemoteClient {
        var profile = FTPProfile()
        var startPath = "/"
        func connect(cancel: CancelFlag?) throws -> [RemoteEntry] { try list("/", cancel: cancel) }
        func list(_ path: String, cancel: CancelFlag?) throws -> [RemoteEntry] {
            [RemoteEntry(name: "deeper", isDirectory: true, isLink: false, size: 0, modified: nil, permissions: nil)]
                + (0..<3).map { RemoteEntry(name: "f\($0)", isDirectory: false, isLink: false, size: Int64.max, modified: nil, permissions: nil) }
        }
        func download(_ path: String, to local: URL, expectedSize: Int64?, resume: Bool, cancel: CancelFlag?, progress: ((Int64) -> Void)?) throws {}
        func upload(_ local: URL, to path: String, resume: Bool, cancel: CancelFlag?, progress: ((Int64) -> Void)?) throws {}
        func makeDirectory(_ path: String) throws {}
        func deleteFile(_ path: String) throws {}
        func removeDirectory(_ path: String) throws {}
        func rename(_ from: String, to: String) throws {}
        func chmod(_ mode: Int, of path: String) throws {}
        func setModificationDate(_ date: Date, of path: String) throws {}
        func close() {}
    }

    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("ALERT-001: line breaks in FTP credentials never reach curl's config") {
            var p = FTPProfile()
            p.name = "x"; p.host = "127.0.0.1"; p.port = 1; p.username = "u"; p.security = .none
            let evil = FTPClient(profile: p, password: "x\nwrite-out = INJECTED")
            do { _ = try evil.connect(cancel: nil); throw Fail(description: "accepted") } catch let e as FTPError {
                guard case .invalid(let m) = e, m.contains("password") else { throw e }
            }
            try expect(FTPClient.escape("a\nb\r\"\\") == #"a\nb\r\"\\"#, "escaped: \(FTPClient.escape("a\nb\r\"\\"))")
            try expect(FTPProfile.fromURL("ftp://u:x%0Aoutput%20=%20/tmp/evil@ftp.example.com/") == nil, "link with %0A refused")
            try expect(FTPProfile.fromURL("ftp://u%0D:x@ftp.example.com/") == nil, "user with CR refused")
            p.username = "bad\nname"
            try expect(p.problems.contains { $0.contains("control characters") }, "profile check")
        }

        testRunner("ALERT-002: hostile sizes are capped and totals never overflow") {
            let mlsd = "type=file;size=9223372036854775807; a\r\ntype=file;size=-5; b\r\n"
            let e = FTPListingParser.parse(mlsd, type: .mlsd)
            try expect(e.map(\.size) == [FTPListingParser.maxSize, 0], "capped: \(e.map(\.size))")
            let unix = FTPListingParser.parse("-rw-r--r-- 1 o g 99999999999999999999 Nov 21 12:00 big", type: .unixList)
            try expect(unix.isEmpty || unix[0].size <= FTPListingParser.maxSize, "unix size")
            try expect(Int64.max.addingSaturated(1) == .max && Int64(5).addingSaturated(6) == 11, "saturating add")
            let items = (0..<10).map { _ in TransferItem(source: .local(URL(fileURLWithPath: "/a")), destination: .local(URL(fileURLWithPath: "/b")), size: .max, isFolder: false) }
            try expect(TransferJob(title: "t", items: items, isMove: false).bytesTotal == .max, "total saturates")
            let entries = (0..<10).map { FileEntry(name: "f\($0)", url: URL(fileURLWithPath: "/f\($0)"), kind: .file, size: .max, modified: nil) }
            _ = EntryFormatter.shared.summary(entries[...], selected: (0, 0, 0))   // must not trap
        }

        testRunner("ALERT-003: SSH secret files are created 0600, never over an existing file or link") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Sec-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("s.pw")
            try expect(SFTPClient.writePrivateFile(file, Data("secret".utf8)), "written")
            let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
            try expect(mode == 0o600, "mode \(String(describing: mode))")
            try expect(!SFTPClient.writePrivateFile(file, Data("again".utf8)), "existing file not reused")
            let link = dir.appendingPathComponent("l.pw")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("target"))
            try expect(!SFTPClient.writePrivateFile(link, Data("x".utf8)), "symlink refused")
        }

        testRunner("ALERT-004: files downloaded from a server are quarantined") {
            let server = try FTPTests.TestServer()
            defer { server.stop() }
            let client = FTPClient(profile: server.profile(), password: "s3cret pass")
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("Q-\(UUID().uuidString)/index.html")
            defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
            try client.download("/www/index.html", to: local, expectedSize: 18, resume: false, cancel: nil, progress: nil)
            try expect(Quarantine.isMarked(local), "quarantine attribute set")
        }

        testRunner("ALERT-006: an imported settings file cannot silently change the terminal command") {
            let suite = "SecurityTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            let options = OptionsWindowController(store: store)
            var evil = store.settings
            evil.operation.terminalApp = "/tmp/Evil.app"
            evil.operation.terminalArguments = "--run {dir}"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("evil-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            try SettingsFile.export(evil).write(to: file)
            var shown = ""
            options.confirmTerminalChange = { shown = $0; return false }
            try options.importSettings(from: file)
            try expect(shown.contains("/tmp/Evil.app") && store.settings.operation.terminalApp == TerminalLauncher.defaultApp, "declined: kept")
            options.confirmTerminalChange = { _ in true }
            try options.importSettings(from: file)
            try expect(store.settings.operation.terminalApp == "/tmp/Evil.app", "accepted explicitly")
            options.window?.close()
        }

        testRunner("ALERT-008: names cannot disguise themselves with direction overrides or control characters") {
            let spoof = FileEntry(name: "invoice\u{202E}fdp.app", url: URL(fileURLWithPath: "/x"), kind: .file, size: 1, modified: nil)
            try expect(!EntryFormatter.shared.name(spoof).unicodeScalars.contains { $0.value == 0x202E }, "RLO replaced")
            try expect(EntryFormatter.visible("line\nbreak") == "line\u{FFFD}break" && EntryFormatter.visible("żółw.txt") == "żółw.txt", "control replaced, letters kept")
            var p = FTPProfile(); p.host = "h"; p.username = "u"; p.passive = true
            try expect(FTPClient(profile: p, password: nil).baseArguments().args.contains("--ftp-skip-pasv-ip"), "PASV address ignored")
        }

        testRunner("ALERT-009: names differing only in case cannot silently overwrite each other on download") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Case-\(UUID().uuidString)")
            let items = ["A.txt", "a.txt"].map { TransferItem(source: .local(URL(fileURLWithPath: "/src/" + $0)), destination: .local(dir.appendingPathComponent($0)), size: 1, isFolder: false) }
            try expect(try TransferPlanner.findConflicts(items) == [1], "second one is a conflict")
        }

        testRunner("ALERT-007: endless server folder trees stop at the limits") {
            let session = RemoteSession(client: EndlessClient())
            do { _ = try session.walk("/"); throw Fail(description: "endless walk returned") } catch let e as FTPError {
                guard case .invalid(let m) = e, m.contains("too deep") else { throw e }
            }
            var cfg = SyncConfiguration(left: FileManager.default.temporaryDirectory, right: session.url(for: "/"))
            cfg.subdirectories = true
            var errors: [String] = []
            let names = try NameMatcher(pattern: "*", regex: false)
            _ = SyncEngine.scanRemote(session.url(for: "/"), session: session, config: cfg, names: names, errors: &errors, isCancelled: { false })
            try expect(errors.contains { $0.contains("too deep") }, "scan stopped: \(errors.suffix(1))")
        }
    }
}
