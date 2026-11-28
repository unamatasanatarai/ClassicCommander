import Cocoa

/// FTP: profiles, credentials, listing parsers, the curl client against a local test server,
/// transfers, and the panel integration.
public enum FTPTests {
    typealias Fail = CommanderTests.TestFailure
    static func expect(_ c: @autoclosure () throws -> Bool, _ m: String) throws {
        if try !c() { throw Fail(description: m) }
    }

    /// A running ftp_test_server.py serving a temporary folder.
    final class TestServer {
        let root: URL
        let port: Int
        private let process: Process
        private let input = Pipe()

        init(flags: [String] = []) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("FTPTests-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root.appendingPathComponent("www/assets"), withIntermediateDirectories: true)
            try Data("<html>hello</html>".utf8).write(to: root.appendingPathComponent("www/index.html"))
            try Data(repeating: 0x41, count: 70_000).write(to: root.appendingPathComponent("www/assets/big.bin"))
            try Data("body{}".utf8).write(to: root.appendingPathComponent("www/assets/app.css"))
            try Data("file with spaces".utf8).write(to: root.appendingPathComponent("www/a name ż.txt"))
            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ftp_test_server.py").path
            process.arguments = ["python3", script, root.path, "tester", "s3cret pass"] + flags
            let out = Pipe()
            process.standardOutput = out
            process.standardInput = input
            process.standardError = FileHandle.nullDevice
            try process.run()
            var line = Data()
            while !line.contains(0x0A) {
                let d = out.fileHandleForReading.availableData
                if d.isEmpty { break }
                line.append(d)
            }
            guard let text = String(data: line, encoding: .utf8), text.hasPrefix("PORT "),
                  let p = Int(text.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw Fail(description: "test FTP server did not start (is python3 installed?)")
            }
            port = p
        }

        func stop() {
            try? input.fileHandleForWriting.close()
            process.terminate()
            try? FileManager.default.removeItem(at: root)
        }

        func profile(security: FTPSecurity = .none) -> FTPProfile {
            var p = FTPProfile()
            p.name = "Test"
            p.host = "127.0.0.1"
            p.port = port
            p.username = "tester"
            p.security = security
            p.remoteDirectory = "/www"
            return p
        }
    }

    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("FTP profiles: host[:port], URL import, validation, summary") {
            var p = FTPProfile()
            try expect(p.setHostAndPort("ftp.example.com:2121") && p.host == "ftp.example.com" && p.port == 2121, "host:port")
            try expect(p.setHostAndPort("[::1]:21") && p.host == "::1", "IPv6")
            try expect(!p.setHostAndPort("bad host/x") && !p.setHostAndPort("h:99999"), "invalid rejected")
            p.security = .implicitTLS
            try expect(p.setHostAndPort("secure.example.com") && p.port == 990, "implicit FTPS defaults to 990")
            guard let (u, pw) = FTPProfile.fromURL("ftp://deploy:pa%20ss@ftp.example.com:2121/var/www") else { throw Fail(description: "URL") }
            try expect(u.username == "deploy" && pw == "pa ss" && u.port == 2121 && u.remoteDirectory == "/var/www"
                       && u.security == .explicitTLS, "ftp URL: \(u)")
            try expect(FTPProfile.fromURL("ftps://mirror.example.org/")?.0.security == .implicitTLS, "ftps URL = implicit")
            try expect(FTPProfile.fromURL("ftp://mirror.example.org/")?.0.anonymous == true, "no user = anonymous")
            let sftp = FTPProfile.fromURL("sftp://deploy@files.example.com:2222/srv")?.0
            try expect(sftp?.isSFTP == true && sftp?.port == 2222 && sftp?.sshAuth == .keyFile && sftp?.anonymous == false
                       && sftp?.remoteDirectory == "/srv", "sftp URL: \(String(describing: sftp))")
            var bad = FTPProfile()
            try expect(bad.problems.count >= 3, "empty profile has problems: \(bad.problems)")
            bad.name = "x"; bad.host = "h"; bad.anonymous = true
            try expect(bad.problems.isEmpty, "anonymous needs no user: \(bad.problems)")
            bad.remoteDirectory = "relative"
            try expect(!bad.problems.isEmpty, "remote dir must be absolute")
            try expect(!FTPSecurity.allCases.map(\.label).joined().lowercased().contains("sftp"), "SFTP never offered as FTP security")
            try expect(FTPSecurity.none.label.contains("unencrypted"), "plain FTP says unencrypted")
        }

        testRunner("FTP profile repository: save, duplicate, folders, delete; passwords only in the credential store") {
            let suite = "FTPTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = MemoryCredentialStore()
            let repo = FTPProfileRepository(defaults: defaults, credentials: store)
            var p = FTPProfile()
            p.name = "Prod"; p.host = "h"; p.username = "u"; p.folder = "Work"
            repo.save(p, password: "secret!")
            try expect(store.password(for: p.id) == "secret!", "password stored")
            let raw = String(decoding: defaults.data(forKey: "ftp.profiles") ?? Data(), as: UTF8.self)
            try expect(!raw.contains("secret!") && raw.contains("Prod"), "profile JSON has no password")
            try expect(repo.folders == ["Work"] && repo.profiles(in: "Work").count == 1, "folder")
            let copy = repo.duplicate(p.id)!
            try expect(copy.name == "Prod (copy)" && store.password(for: copy.id) == "secret!", "duplicate with password")
            repo.deleteFolder("Work")
            try expect(repo.profiles(in: nil).count == 2 && repo.profile(p.id)?.host == "h", "folder removal keeps profiles")
            repo.delete(p.id)
            try expect(repo.profile(p.id) == nil && store.password(for: p.id) == nil, "delete removes password")
            var noSave = copy
            noSave.savePassword = false
            repo.save(noSave, password: "x")
            try expect(store.password(for: copy.id) == nil, "not saved when unticked")
            try expect(FTPProfileRepository(defaults: defaults, credentials: store).profiles.count == 1, "persisted")
        }

        testRunner("FTP listing parsers: MLSD, Unix, Windows; unsafe names dropped") {
            let mlsd = "type=cdir; .\r\ntype=dir;modify=20261120101500; assets\r\ntype=file;size=8192;modify=20261121120000;UNIX.mode=0644; index.html\r\ntype=file;size=1; ../evil\r\n"
            let m = FTPListingParser.parse(mlsd, type: .automatic)
            try expect(m.map(\.name) == ["assets", "index.html"], "MLSD: \(m.map(\.name))")
            try expect(m[1].size == 8192 && m[1].permissions == 0o644 && m[0].isDirectory, "MLSD facts")
            let now = ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z")!
            let unix = """
            drwxr-xr-x   2 owner group     4096 Nov 20 10:15 assets
            -rw-r--r--   1 owner group     8192 Mar  3  2025 old file.txt
            lrwxrwxrwx   1 owner group        7 Nov 21 12:00 current -> release
            -rw-r--r--   1 owner group        1 Nov 21 12:00 bad\u{0007}name
            """
            let u = FTPListingParser.parse(unix, type: .unixList, now: now)
            try expect(u.map(\.name) == ["assets", "old file.txt", "current"], "Unix: \(u.map(\.name))")
            try expect(u[1].size == 8192 && u[2].isLink && u[0].permissions == 0o755, "Unix facts")
            let dos = "11-20-26  10:15AM       <DIR>          assets\r\n11-21-2026  02:00PM             8192 index page.html\r\n"
            let d = FTPListingParser.parse(dos, type: .dosList)
            try expect(d.map(\.name) == ["assets", "index page.html"] && d[0].isDirectory && d[1].size == 8192, "DOS: \(d)")
            try expect(FTPListingParser.parse("garbage line\nanother", type: .automatic).isEmpty, "garbage ignored")
        }

        testRunner("FTP client arguments: TLS never downgraded, pinning, passive/active, password only on stdin") {
            var p = FTPProfile()
            p.host = "ftp.example.com"; p.port = 21; p.username = "u"; p.security = .explicitTLS
            let c = FTPClient(profile: p, password: "top\"secret")
            let (args, config) = c.baseArguments()
            try expect(args.contains("--ssl-reqd") && !args.contains("--ssl"), "explicit FTPS requires TLS")
            try expect(!args.joined(separator: " ").contains("top"), "password not in arguments")
            try expect(config.contains("user = \"u:top\\\"secret\""), "password escaped in stdin config: \(config)")
            try expect(args.contains("--ftp-pasv") && args.first == "--disable", "passive; no ~/.curlrc")
            try expect(c.url(for: "/var/www/a b.txt", directory: false) == "ftp://ftp.example.com:21/%2Fvar/www/a%20b.txt", c.url(for: "/var/www/a b.txt", directory: false))
            p.security = .implicitTLS; p.passive = false; p.pinnedPublicKey = "sha256//abc="
            let c2 = FTPClient(profile: p, password: nil)
            let a2 = c2.baseArguments().args
            try expect(c2.url(for: "/", directory: true).hasPrefix("ftps://"), "implicit uses ftps://")
            try expect(a2.contains("--pinnedpubkey") && a2.contains("sha256//abc=") && a2.contains("--ftp-port"), "pin + active")
            try expect(c2.redact("PASS top") == "PASS top", "nothing to redact without password")
            try expect(FTPClient(profile: p, password: "hunter22").redact("error hunter22") == "error ••••", "redaction")
            func err(_ code: Int32, _ text: String = "") -> FTPError {
                FTPClient.error(for: FTPClient.Result(exitCode: code, output: Data(), errorText: text))
            }
            try expect(err(67) == .authentication && err(6) == .hostNotFound && err(7) == .refused && err(28) == .timeout, "errors")
            try expect(err(64) == .tlsUnavailable && err(60) == .certificateUntrusted && err(90) == .pinnedKeyChanged, "TLS errors")
            try expect(err(25, "curl: (25) Failed FTP upload: 552") == .quotaExceeded && err(23) == .localDiskFull && err(56) == .connectionLost, "transfer errors")
            try expect(err(35, "curl: tls bad") == .tlsFailed("tls bad") && err(80, "ssl") == .tlsFailed("ssl"), "tlsFailed")
            try expect(err(9, "curl: (9) 550 permission") == .permissionDenied("") && err(78, "curl: (78) 550 missing") == .notFound(""), "9/78 perm vs notFound")
            try expect(err(25, "curl: (25) 550 denied") == .permissionDenied("") && err(21, "curl: (21) 450 busy") == .server("(21) 450 busy"), "25/21 denied/450")
            try expect(err(19, "") == .server("the server refused the command"), "19 empty")
            try expect(err(13) == .passiveFailed && err(30) == .activeFailed, "passive/active")
            try expect(err(99, "") == .server("curl exit code 99") && err(99, "boom") == .server("boom"), "default curl error")

            let allErrors: [FTPError] = [
                .authentication, .hostNotFound, .refused, .timeout, .tlsUnavailable,
                .tlsFailed("handshake"), .certificateUntrusted, .pinnedKeyChanged,
                .hostKeyUnknown, .hostKeyChanged, .keyFile("bad key"),
                .permissionDenied(""), .permissionDenied("chmod"),
                .notFound(""), .notFound("/x"),
                .quotaExceeded, .localDiskFull, .connectionLost,
                .passiveFailed, .activeFailed, .cancelled,
                .verificationFailed("hash"), .invalid("bad url"), .server("500")
            ]
            for e in allErrors {
                try expect(!e.message.isEmpty, "Empty message for \(e)")
            }

            // FTPListingParser.parseDOS edge cases
            try expect(FTPListingParser.parseDOS("11-21-2026  14:30  8192 file.txt")?.size == 8192, "24-hour DOS time")
            try expect(FTPListingParser.parseDOS("11-21-98  12:00PM  <DIR> old")?.isDirectory == true, "1998 2-digit year")
            try expect(FTPListingParser.parseDOS("short") == nil, "short DOS line")
            try expect(FTPListingParser.parseDOS("bad-date 12:00PM <DIR> x") == nil, "bad DOS date")
            try expect(FTPListingParser.parseDOS("11-21-26 badtime <DIR> x") == nil, "bad DOS time")
        }

        testRunner("FTP against a local server: connect, list (MLSD and LIST fallback), wrong password, TLS refused") {
            let server = try TestServer()
            defer { server.stop() }
            let client = FTPClient(profile: server.profile(), password: "s3cret pass")
            let entries = try client.connect()
            try expect(Set(entries.map(\.name)) == ["assets", "index.html", "a name ż.txt"], "listing: \(entries.map(\.name))")
            try expect(client.entryPath == "/", "login directory: \(client.entryPath ?? "nil")")
            try expect(try client.list("/www/assets").first { $0.name == "big.bin" }?.size == 70_000, "sizes")

            let noMLSD = try TestServer(flags: ["--no-mlsd"])
            defer { noMLSD.stop() }
            let fallback = FTPClient(profile: noMLSD.profile(), password: "s3cret pass")
            try expect(try fallback.connect().count == 3, "LIST fallback when MLSD is refused")

            let bad = FTPClient(profile: server.profile(), password: "wrong")
            do { _ = try bad.connect(); throw Fail(description: "should fail") } catch let e as FTPError {
                try expect(e == .authentication && !e.message.contains("wrong"), "auth failure without password: \(e)")
            }
            let tls = FTPClient(profile: server.profile(security: .explicitTLS), password: "s3cret pass")
            do { _ = try tls.connect(); throw Fail(description: "should refuse") } catch let e as FTPError {
                try expect(e == .tlsUnavailable, "server without TLS is refused, never downgraded: \(e)")
            }
            var refused = server.profile()
            refused.port = 1
            do { _ = try FTPClient(profile: refused, password: "x").connect(); throw Fail(description: "refused") } catch let e as FTPError {
                try expect(e == .refused, "refused: \(e)")
            }
        }

        testRunner("FTP file operations: download (verified, atomic), upload, resume, mkdir, rename, delete, errors per file") {
            let server = try TestServer()
            defer { server.stop() }
            let client = FTPClient(profile: server.profile(), password: "s3cret pass")
            _ = try client.connect()
            let local = server.root.deletingLastPathComponent().appendingPathComponent("FTPLocal-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: local) }
            var seen: Int64 = 0
            try client.download("/www/assets/big.bin", to: local.appendingPathComponent("big.bin"), expectedSize: 70_000) { seen = $0 }
            try expect(FTPClient.fileSize(local.appendingPathComponent("big.bin")) == 70_000 && seen == 70_000, "download")
            try expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("big.bin.ccpart").path), "no .ccpart left")
            do {
                try client.download("/www/assets/app.css", to: local.appendingPathComponent("x.css"), expectedSize: 999)
                throw Fail(description: "size mismatch must fail")
            } catch FTPError.verificationFailed {
                try expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("x.css").path), "unverified file not placed")
            }
            try client.download("/www/a name ż.txt", to: local.appendingPathComponent("u.txt"), expectedSize: 16)
            try expect(String(decoding: try Data(contentsOf: local.appendingPathComponent("u.txt")), as: UTF8.self) == "file with spaces", "spaces and Unicode in names")

            // Resume: a partial .ccpart continues where it stopped.
            try Data(repeating: 0x41, count: 30_000).write(to: local.appendingPathComponent("r.bin.ccpart"))
            try client.download("/www/assets/big.bin", to: local.appendingPathComponent("r.bin"), expectedSize: 70_000, resume: true)
            try expect(FTPClient.fileSize(local.appendingPathComponent("r.bin")) == 70_000, "resumed download complete")

            try Data("uploaded!".utf8).write(to: local.appendingPathComponent("up.txt"))
            try client.upload(local.appendingPathComponent("up.txt"), to: "/www/new/deep/up.txt")
            try expect(try Data(contentsOf: server.root.appendingPathComponent("www/new/deep/up.txt")) == Data("uploaded!".utf8), "upload creates folders")
            try client.makeDirectory("/www/made")
            try expect(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/made").path), "mkdir")
            try client.rename("/www/new/deep/up.txt", to: "/www/made/renamed.txt")
            try expect(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/made/renamed.txt").path), "rename")
            try client.deleteFile("/www/made/renamed.txt")
            try client.removeDirectory("/www/made")
            try expect(!FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/made").path), "delete + rmdir")
            do { try client.deleteFile("/www/nothing-here"); throw Fail(description: "missing") } catch let e as FTPError {
                if case .server = e {} else if case .notFound = e {} else if case .permissionDenied = e {} else { throw Fail(description: "\(e)") }
            }
            do {
                try client.upload(local.appendingPathComponent("up.txt"), to: "/www/denied.txt")
                throw Fail(description: "denied upload must fail")
            } catch let e as FTPError {
                if case .permissionDenied = e {} else { throw Fail(description: "expected permission denied: \(e)") }
            }
            do {
                try client.makeDirectory("/www/bad\r\nDELE x")
                throw Fail(description: "a line break must not reach the server as a second command")
            } catch FTPError.invalid {}
        }

        testRunner("FTP transfers: plan folder trees both ways, conflicts, run with per-file results, move, retry") {
            let server = try TestServer()
            defer { server.stop() }
            let session = RemoteSession(client: FTPClient(profile: server.profile(), password: "s3cret pass"))
            _ = try session.client.connect(cancel: nil)
            let local = server.root.deletingLastPathComponent().appendingPathComponent("FTPLocal-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: local) }
            let manager = TransferManager()
            manager.runSynchronously = true

            // Download the remote "assets" folder.
            var plan = try TransferPlanner.plan([.init(location: .remote(session, "/www/assets"), isFolder: true, size: 0)], into: .local(local))
            try expect(plan.items.count == 3 && plan.conflicts.isEmpty, "folder + 2 files: \(plan.items.count)")
            let down = TransferJob(title: "down", items: plan.items, isMove: false)
            manager.enqueue(down)
            try expect(down.state == .finished && down.failedCount == 0 && down.bytesDone == 70_006, "downloaded: \(down.statusText)")
            try expect(FTPClient.fileSize(local.appendingPathComponent("assets/big.bin")) == 70_000, "structure kept")

            // Upload it back under a new name; one file is refused by the server → per-file failure.
            try FileManager.default.moveItem(at: local.appendingPathComponent("assets"), to: local.appendingPathComponent("site"))
            try Data("x".utf8).write(to: local.appendingPathComponent("site/denied.txt"))
            plan = try TransferPlanner.plan([.init(location: .local(local.appendingPathComponent("site")), isFolder: true, size: 0)],
                                            into: .remote(session, "/www"))
            let up = TransferJob(title: "up", items: plan.items, isMove: false)
            manager.enqueue(up)
            try expect(up.failedCount == 1 && up.doneCount == up.items.count - 1, "one refused: \(up.statusText)")
            try expect(up.statusText.contains("1 failed"), up.statusText)
            let report = zip(up.items, up.results).map { "\($0.0.destination.displayPath) \($0.1)" }.joined(separator: "; ")
            try expect(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/site/big.bin").path), "uploaded: \(report)")
            try expect(up.retryJob()?.items.count == 1, "retry only the failed file")

            // Conflicts are found before anything is copied.
            plan = try TransferPlanner.plan([.init(location: .local(local.appendingPathComponent("site/app.css")), isFolder: false, size: 6)],
                                            into: .remote(session, "/www/site"))
            try expect(plan.conflicts == [0], "existing remote file reported")

            // Move remote → local: the server copy is deleted only after a verified download.
            plan = try TransferPlanner.plan([.init(location: .remote(session, "/www/index.html"), isFolder: false, size: 18)], into: .local(local))
            let move = TransferJob(title: "move", items: plan.items, isMove: true)
            manager.enqueue(move)
            try expect(move.failedCount == 0 && FileManager.default.fileExists(atPath: local.appendingPathComponent("index.html").path)
                       && !FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/index.html").path), "moved")

            // Cancelling: nothing is reported as done.
            let cancelled = TransferJob(title: "c", items: plan.items, isMove: false)
            cancelled.cancel()
            manager.enqueue(cancelled)
            try expect(cancelled.state == .cancelled && cancelled.doneCount == 0, "cancelled job")
        }

        testRunner("Remote panel: connect a panel, browse with the normal list, back to local") {
            let server = try TestServer()
            defer { server.stop() }
            let session = RemoteSession(client: FTPClient(profile: server.profile(), password: "s3cret pass"))
            let listing = try session.client.connect(cancel: nil)
            session.store(listing, for: "/www")
            let panel = PanelModel(directory: FileManager.default.temporaryDirectory)
            try expect(panel.switchSource(RemoteLister(session: session), to: session.url(for: "/www"), visibleRows: 20) == .navigated, "switched")
            try expect(panel.isRemote && panel.entries.map(\.name) == ["..", "assets", "a name ż.txt", "index.html"], "\(panel.entries.map(\.name))")
            try session.fetch("/www/assets")
            panel.focus(name: "assets", visibleRows: 20)
            try expect(panel.openCurrent(visibleRows: 20) == .navigated && RemoteSession.path(of: panel.directory) == "/www/assets", "entered")
            panel.goUp(visibleRows: 20)
            try expect(RemoteSession.path(of: panel.directory) == "/www" && panel.currentEntry?.name == "assets", "up, cursor on folder")
            try expect(RemoteSession.sessionID(of: panel.directory) == session.id, "location knows its session")
            try expect(panel.switchSource(FileSystemLister(), to: FileManager.default.temporaryDirectory, visibleRows: 20) == .navigated && !panel.isRemote, "back to local")
        }

        testRunner("FTP in the commander: connect a panel, browse, download, upload, rename, mkdir, delete, view, disconnect") {
            let server = try TestServer()
            defer { server.stop() }
            let local = server.root.deletingLastPathComponent().appendingPathComponent("FTPLocal-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: local) }
            try Data("local file".utf8).write(to: local.appendingPathComponent("from-mac.txt"))

            let model = CommanderModel(left: PanelModel(directory: local), right: PanelModel(directory: local))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            let suite = "FTPTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let ftp = view.ftp
            ftp.repository = FTPProfileRepository(defaults: defaults, credentials: MemoryCredentialStore())
            ftp.runSynchronously = true
            var messages: [String] = []
            ftp.showMessage = { title, text in messages.append(title + ": " + text) }
            let prompts = StubPrompts()
            view.fileCommands.prompts = prompts
            view.fileCommands.runInBackground = false

            // Connect the right panel.
            var outcome: Result<Void, FTPError>?
            ftp.connect(server.profile(), password: "s3cret pass", side: .right) { outcome = $0 }
            guard case .success = outcome else { throw Fail(description: "connect: \(String(describing: outcome))") }
            let right = view.rightView
            try expect(right.model.isRemote && model.activeSide == .right, "right panel shows the server and is active")
            try expect(right.remote?.insecure == true && right.remote?.status.contains("FTP") == true, "plain FTP marked unencrypted")
            try expect(view.functionBar.shownActions.last == .ftpDisconnect, "FTP Disconnect button")
            try expect(right.model.entries.map(\.name).contains("index.html"), "listing shown")
            var openedInFinder: URL?
            Modal.opened = { openedInFinder = $0 }
            view.perform(.openInFinder)
            Modal.opened = { _ in }
            try expect(openedInFinder == nil, "a server folder isn't opened in Finder")

            // Navigate: into assets and back up.
            right.model.focus(name: "assets", visibleRows: 20)
            view.perform(.enterFolder)
            try expect(RemoteSession.path(of: right.model.directory) == "/www/assets", "entered: \(right.model.directory)")
            try expect(Set(right.model.entries.map(\.name)) == ["..", "big.bin", "app.css"], "\(right.model.entries.map(\.name))")
            view.perform(.parentFolder)
            try expect(RemoteSession.path(of: right.model.directory) == "/www" && right.model.currentEntry?.name == "assets", "back up")

            // 5 on a remote folder downloads it into the left (local) panel.
            right.model.focus(name: "assets", visibleRows: 20)
            view.perform(.copy)
            try expect(prompts.lastMessage == "Copy folder “assets” to:" && prompts.lastDefault == local.path + "/", "dialog: \(prompts.lastDefault)")
            try expect(FTPClient.fileSize(local.appendingPathComponent("assets/big.bin")) == 70_000, "downloaded tree")
            try expect(ftp.transfers.jobs.last?.state == .finished && ftp.transfers.jobs.last?.failedCount == 0, "job finished")

            // 5 from the local panel uploads into the remote folder.
            view.activate(.left)
            model.left.reload(visibleRows: 20)
            model.left.focus(name: "from-mac.txt", visibleRows: 20)
            view.perform(.copy)
            try expect(try Data(contentsOf: server.root.appendingPathComponent("www/from-mac.txt")) == Data("local file".utf8), "uploaded")
            try expect(right.model.entries.contains { $0.name == "from-mac.txt" }, "remote panel refreshed after the transfer")
            // Again: the file is on the server now, so "target file exists" asks (here: rename it).
            prompts.conflict = .rename("from-mac-2.txt")
            model.left.focus(name: "from-mac.txt", visibleRows: 20)
            view.perform(.copy)
            try expect(prompts.conflicts.count == 1 && prompts.conflicts.first?.targetSize == 10, "asked with the server's size")
            try expect(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/from-mac-2.txt").path), "uploaded under the new name")
            try FileManager.default.removeItem(at: server.root.appendingPathComponent("www/from-mac-2.txt"))
            prompts.conflict = .skip

            // 6 with just a new name renames on the server.
            view.activate(.right)
            right.model.focus(name: "from-mac.txt", visibleRows: 20)
            prompts.answer = "renamed.txt"
            view.perform(.move)
            try expect(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/renamed.txt").path), "renamed on server")

            // ⇧6 on the server: renamed there, cursor on the new name; a failure is reported.
            right.model.reload(visibleRows: 20)
            right.model.focus(name: "renamed.txt", visibleRows: 20)
            view.rename(right.model.currentEntry!, to: "inplace.txt", in: right)
            try expect(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/inplace.txt").path)
                       && right.model.currentEntry?.name == "inplace.txt", "renamed in place on the server")
            view.rename(FileEntry(name: "nope", url: right.model.directory.appendingPathComponent("nope"), kind: .file), to: "x", in: right)
            try expect(messages.last?.contains("Rename failed") == true, "failure reported: \(messages.last ?? "")")
            view.rename(right.model.currentEntry!, to: "renamed.txt", in: right)

            // Multi-Rename on the server: the marked file gets a new name there, and Undo brings it back.
            right.model.reload(visibleRows: 20)
            right.model.setMarks(["renamed.txt"])
            let tool = MultiRenameWindowController(commander: view, defaults: UserDefaults(suiteName: suite)!)
            tool.present(for: right)
            tool.nameField.stringValue = "[N]_srv"
            tool.changed()
            tool.startPressed()
            try expect(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/renamed_srv.txt").path), "multi-renamed on the server")
            tool.startPressed()   // nothing changes now (same mask on the new name would add _srv again: allowed, then undone)
            tool.undoPressed()
            tool.close()
            right.model.reload(visibleRows: 20)
            for name in ["renamed_srv.txt", "renamed_srv_srv.txt"] where FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/" + name).path) {
                try FileManager.default.moveItem(at: server.root.appendingPathComponent("www/" + name), to: server.root.appendingPathComponent("www/renamed.txt"))
            }
            right.model.clearMarks()

            // 7 creates a folder on the server; 8 deletes (permanently, after confirmation naming the server path).
            prompts.answer = "made"
            view.perform(.newFolder)
            try expect(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/made").path), "mkdir")
            // Drag & drop with the server: a file from Finder onto the remote folder row "made",
            // and a remote file dragged onto the local panel.
            let fromFinder = local.appendingPathComponent("dropped.txt")
            try Data("dropped".utf8).write(to: fromFinder)
            right.model.reload(visibleRows: 20)
            guard let madeRow = right.model.entries.firstIndex(where: { $0.name == "made" }),
                  let finderEntry = PanelView.droppedEntry(fromFinder) else { throw Fail(description: "no made row") }
            view.drop(PanelDrop(entries: [finderEntry], source: nil, target: right, folder: right.model.entries[madeRow].url,
                                folderRow: madeRow, move: false))
            try expect(prompts.lastDefault.hasSuffix("/www/made/"), "uploads into the folder under the mouse: \(prompts.lastDefault)")
            try expect(try Data(contentsOf: server.root.appendingPathComponent("www/made/dropped.txt")) == Data("dropped".utf8),
                       "uploaded from Finder into the remote folder")
            let page = right.model.entries.filter { $0.name == "index.html" }
            view.drop(PanelDrop(entries: page, source: right, target: view.leftView, folder: local, folderRow: nil, move: false))
            try expect(try Data(contentsOf: local.appendingPathComponent("index.html")) == Data("<html>hello</html>".utf8),
                       "dragged from the server to the local panel")
            try FileManager.default.removeItem(at: server.root.appendingPathComponent("www/made/dropped.txt"))
            view.activate(.right)
            right.model.focus(name: "renamed.txt", visibleRows: 20)
            prompts.confirmAnswer = false
            view.perform(.delete)
            try expect(FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/renamed.txt").path), "declined: kept")
            try expect(prompts.lastMessage.contains("Permanently delete") && prompts.lastMessage.contains("127.0.0.1"), prompts.lastMessage)
            prompts.confirmAnswer = true
            view.perform(.delete)
            try expect(!FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/renamed.txt").path), "deleted")
            right.model.reload(visibleRows: 20)
            right.model.focus(name: "assets", visibleRows: 20)
            view.perform(.delete)
            try expect(!FileManager.default.fileExists(atPath: server.root.appendingPathComponent("www/assets").path), "folder tree deleted")

            // 3 on a remote file opens a temporary copy in Lister.
            right.model.focus(name: "index.html", visibleRows: 20)
            view.perform(.view)
            try expect(view.listers.last?.textView.string == "<html>hello</html>", "viewed remote file")
            view.listers.last?.window?.close()

            // Errors are reported, the panel stays where it was.
            let before = right.model.directory
            try FileManager.default.removeItem(at: server.root.appendingPathComponent("www/made"))
            right.model.focus(name: "made", visibleRows: 20)
            view.perform(.enterFolder)
            try expect(right.model.directory == before && messages.last?.contains("Cannot open") == true, "missing folder reported: \(messages)")

            // Disconnect: back to the local folder it came from.
            view.perform(.ftpDisconnect)
            try expect(!right.model.isRemote && right.model.directory == local.normalizedLocation && right.remote == nil, "disconnected")
            try expect(view.functionBar.shownActions.last != .ftpDisconnect, "button gone")
        }

        testRunner("FTP Synchronize: local folder against an FTP folder (MFMT keeps dates)") {
            let server = try TestServer()
            defer { server.stop() }
            let session = RemoteSession(client: FTPClient(profile: server.profile(), password: "s3cret pass"))
            _ = try session.client.connect(cancel: nil)
            try SFTPTests.syncRoundTrip(session: session, remoteRoot: "/www/sync", serverDisk: server.root.appendingPathComponent("www/sync"))
        }

        testRunner("Transfer limits: several files at once, never more uploads/downloads than allowed (0 = total)") {
            let limits = TransferLimits(total: 3, uploads: 0, downloads: 1)
            try expect(limits.effectiveUploads == 3 && limits.effectiveDownloads == 1, "0 means the total")
            try expect(TransferLimits(total: 2, uploads: 5).effectiveUploads == 2 && TransferLimits(total: 0).total == 1, "clamped")
            try expect(OperationOptions.standard.transferLimits == TransferLimits(total: 3, uploads: 0, downloads: 0), "defaults")
            let old = try JSONDecoder().decode(OperationOptions.self, from: Data(#"{"spaceCalculatesFolderSize":false,"spaceMovesCursorDown":true}"#.utf8))
            try expect(old.maxTransfers == 3 && !old.spaceCalculatesFolderSize, "old settings load with default limits")

            let server = try TestServer()
            defer { server.stop() }
            let session = RemoteSession(client: FTPClient(profile: server.profile(), password: "s3cret pass"))
            _ = try session.client.connect(cancel: nil)
            let local = server.root.deletingLastPathComponent().appendingPathComponent("FTPLimits-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: local) }
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            for i in 0..<8 { try Data(repeating: UInt8(i), count: 300_000).write(to: local.appendingPathComponent("f\(i).bin")) }

            func run(_ limits: TransferLimits, _ make: () throws -> TransferJob) throws -> TransferManager {
                let manager = TransferManager()
                manager.limits = limits
                let done = DispatchSemaphore(value: 0)
                manager.onChange = { job in if job.state == .finished || job.state == .cancelled { done.signal() } }
                let job = try make()
                manager.enqueue(job)
                // onChange is delivered on the main thread: keep it running while waiting.
                let deadline = Date().addingTimeInterval(60)
                while done.wait(timeout: .now()) == .timedOut && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                try expect(job.state == .finished && job.failedCount == 0 && job.doneCount == job.items.count, "job: \(job.statusText) \(job.results)")
                return manager
            }
            let up = try run(TransferLimits(total: 3, uploads: 0, downloads: 1)) {
                let plan = try TransferPlanner.plan([.init(location: .local(local), isFolder: true, size: 0)], into: .remote(session, "/www/up"))
                return TransferJob(title: "up", items: plan.items, isMove: false)
            }
            try expect(up.peakUploads > 1 && up.peakUploads <= 3 && up.peakConcurrency <= 3, "uploads use the total: \(up.peakUploads)")
            let downTarget = local.appendingPathComponent("down")
            let down = try run(TransferLimits(total: 3, uploads: 0, downloads: 1)) {
                let plan = try TransferPlanner.plan([.init(location: .remote(session, "/www/up/\(local.lastPathComponent)"), isFolder: true, size: 0)],
                                                    into: .local(downTarget))
                return TransferJob(title: "down", items: plan.items, isMove: false)
            }
            try expect(down.peakDownloads == 1, "one download at a time: \(down.peakDownloads)")
            try expect(FileManager.default.contents(atPath: downTarget.appendingPathComponent("\(local.lastPathComponent)/f7.bin").path)?.count == 300_000, "files arrived")
        }

        testRunner("Find Files on a server: names, depth, size, text (downloaded and removed), errors, the dialog") {
            let server = try TestServer()
            defer { server.stop() }
            let session = RemoteSession(client: FTPClient(profile: server.profile(), password: "s3cret pass"))
            _ = try session.client.connect(cancel: nil)
            let lookup: SyncSessionLookup = { RemoteSession.sessionID(of: $0) == session.id ? session : nil }
            func search(_ edit: (inout FileSearchConfiguration) -> Void, root: String = "/www", selected: [URL] = []) throws -> FileSearch.Report {
                var c = FileSearchConfiguration()
                c.general.searchPaths = [session.url(for: root).absoluteString]
                edit(&c)
                return try FileSearch(config: c, selectedItems: selected, base: URL(fileURLWithPath: "/"), sessions: lookup).run()
            }
            func names(_ r: FileSearch.Report) -> [String] { r.found.map { RemoteSession.path(of: $0.url) }.sorted() }
            var r = try search { $0.general.filenamePattern = "*.css;*.bin" }
            try expect(names(r) == ["/www/assets/app.css", "/www/assets/big.bin"] && r.errors.isEmpty, "masks, recursive: \(names(r)) \(r.errors)")
            try expect(r.found.allSatisfy { $0.url.isRemoteLocation }, "results stay on the server")
            r = try search { $0.general.filenamePattern = "*.css"; $0.general.depth = .currentOnly }
            try expect(r.found.isEmpty, "current folder only: \(names(r))")
            r = try search { $0.general.filenamePattern = "*"; $0.advanced.fileSize.enabled = true; $0.advanced.fileSize.comparison = .greater; $0.advanced.fileSize.value = 50_000; $0.advanced.fileSize.unit = .bytes }
            try expect(names(r) == ["/www/assets/big.bin"], "size filter: \(names(r))")
            r = try search { $0.general.filenamePattern = "*"; $0.general.content.enabled = true; $0.general.content.expression = "hello" }
            try expect(names(r) == ["/www/index.html"], "text found in a downloaded copy: \(names(r)) \(r.errors)")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("cc-find-") }
            try expect(leftovers.isEmpty, "temporary copies removed: \(leftovers)")
            r = try search({ $0.general.filenamePattern = "*"; $0.general.selectedItemsOnly = true }, selected: [session.url(for: "/www/index.html")])
            try expect(names(r) == ["/www/index.html"], "a selected server file: \(names(r))")
            do {
                _ = try search { $0.advanced.duplicates = DuplicateSearchConfiguration(enabled: true, sameContents: true) }
                throw Fail(description: "duplicates by content allowed")
            } catch is SearchValidationError {}
            var closed = FileSearchConfiguration()
            closed.general.searchPaths = [session.url(for: "/www").absoluteString]
            let gone = try FileSearch(config: closed, base: URL(fileURLWithPath: "/")).run()
            try expect(gone.errors.contains { $0.contains("closed") }, "closed connection reported")

            // The dialog: a connected panel searches its server.
            let local = FileManager.default.temporaryDirectory
            let view = CommanderView(model: CommanderModel(left: PanelModel(directory: local), right: PanelModel(directory: local)))
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            let suite = "FTPFind-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            view.ftp.repository = FTPProfileRepository(defaults: defaults, credentials: MemoryCredentialStore())
            view.ftp.runSynchronously = true
            var outcome: Result<Void, FTPError>?
            view.ftp.connect(server.profile(), password: "s3cret pass", side: .right) { outcome = $0 }
            guard case .success = outcome else { throw Fail(description: "connect") }
            let dialog = FindFilesWindowController(commander: view, defaults: defaults)
            dialog.runSynchronously = true
            dialog.present()
            try expect(dialog.searchIn.stringValue.hasPrefix("ftp://tester@127.0.0.1"), "searches the server: \(dialog.searchIn.stringValue)")
            dialog.searchFor.stringValue = "*.html"
            dialog.startSearch()
            try expect(dialog.rows.map { RemoteSession.path(of: $0.item.url) } == ["/www/index.html"], "dialog results: \(dialog.rows.map(\.item.url))")
            dialog.feedToListbox()
            try expect(dialog.statusLabel.stringValue.contains("Feed to listbox works for files on this Mac"), "feed refused: \(dialog.statusLabel.stringValue)")
            dialog.window?.close()
            view.ftp.disconnect(.right)
        }

        testRunner("FTP connection manager: failed connect keeps the dialog and the profile selected; success closes it") {
            let server = try TestServer()
            defer { server.stop() }
            let model = CommanderModel(left: PanelModel(directory: server.root), right: PanelModel(directory: server.root))
            let view = CommanderView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            let suite = "FTPTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = MemoryCredentialStore()
            view.ftp.repository = FTPProfileRepository(defaults: defaults, credentials: store)
            view.ftp.runSynchronously = true
            var good = server.profile()
            good.folder = "Tests"
            var bad = server.profile()
            bad.name = "Bad"
            view.ftp.repository.save(good, password: "s3cret pass")
            view.ftp.repository.save(bad, password: "nope")
            let manager = view.ftp.managerWindow
            manager.present()
            try expect(manager.outline.numberOfRows == 3, "folder + 2 profiles: \(manager.outline.numberOfRows)")
            manager.reload(select: bad.id)
            manager.connectSelected()
            try expect(manager.window?.isVisible == true && manager.selectedProfile?.id == bad.id, "still open, profile kept")
            try expect(!view.leftView.model.isRemote, "nothing connected")
            manager.reload(select: good.id)
            manager.connectSelected()
            try expect(manager.window?.isVisible == false && view.leftView.model.isRemote, "connected with the Keychain password, dialog closed")
            view.ftp.disconnect(.left)
        }
    }
}
