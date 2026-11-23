import Cocoa

/// SFTP: profile fields and old-profile compatibility, argument safety, error mapping, and the
/// client against a real OpenSSH server (/usr/sbin/sshd run as the current user on a random port).
public enum SFTPTests {
    typealias Fail = CommanderTests.TestFailure
    static func expect(_ c: @autoclosure () throws -> Bool, _ m: String) throws {
        if try !c() { throw Fail(description: m) }
    }

    /// A private sshd serving the current user, with a plain key and a passphrase-protected key.
    final class TestSSHServer {
        let dir: URL
        let root: URL
        let port: Int
        let plainKey: String
        let protectedKey: String
        let passphrase = "correct horse"
        private let process = Process()

        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("SFTPTests-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
            root = dir.appendingPathComponent("srv")
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("www/assets"), withIntermediateDirectories: true)
            try Data("<html>hello</html>".utf8).write(to: root.appendingPathComponent("www/index.html"))
            try Data(repeating: 0x42, count: 90_000).write(to: root.appendingPathComponent("www/assets/big.bin"))
            try Data("odd".utf8).write(to: root.appendingPathComponent("www/odd [1] *\"q'.txt"))
            plainKey = dir.appendingPathComponent("user key").path          // a space in the path, on purpose
            protectedKey = dir.appendingPathComponent("user_pw").path
            try Self.tool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent("host").path])
            try Self.tool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", plainKey])
            try Self.tool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", passphrase, "-f", protectedKey])
            let keys = try String(contentsOfFile: plainKey + ".pub") + String(contentsOfFile: protectedKey + ".pub")
            try keys.write(to: dir.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
            port = Int.random(in: 30000...60000)
            let config = """
                Port \(port)
                ListenAddress 127.0.0.1
                HostKey \(dir.path)/host
                PidFile \(dir.path)/sshd.pid
                AuthorizedKeysFile \(dir.path)/authorized_keys
                StrictModes no
                UsePAM no
                PasswordAuthentication no
                KbdInteractiveAuthentication no
                Subsystem sftp internal-sftp
                """
            try config.write(to: dir.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            process.arguments = ["-D", "-f", dir.appendingPathComponent("sshd_config").path, "-E", dir.appendingPathComponent("sshd.log").path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Wait until it accepts connections.
            for _ in 0..<50 {
                if SFTPClient.fetchHostKeys(host: "127.0.0.1", port: port) != nil { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
            stop()
            throw Fail(description: "test sshd did not start")
        }

        @discardableResult
        static func tool(_ path: String, _ args: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw Fail(description: "\(path) failed") }
            return String(decoding: data, as: UTF8.self)
        }

        var hostKeys: [String] { SFTPClient.fetchHostKeys(host: "127.0.0.1", port: port)?.keys ?? [] }

        func profile(key: String? = nil, trusted: Bool = true) -> FTPProfile {
            var p = FTPProfile()
            p.name = "SFTP test"
            p.connectionProtocol = .sftp
            p.host = "127.0.0.1"
            p.port = port
            p.username = NSUserName()
            p.sshAuth = .keyFile
            p.keyFile = key ?? plainKey
            p.remoteDirectory = root.appendingPathComponent("www").path
            if trusted { p.trustedHostKeys = hostKeys }
            return p
        }

        func stop() {
            process.terminate()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Synchronize a local folder with a server folder (any protocol): compare, run, compare again
    /// (dates kept, so everything is then identical), and an asymmetric run that deletes on the server.
    /// `serverDisk` is where the server keeps `remoteRoot` on this Mac, so the test can prepare files.
    static func syncRoundTrip(session: RemoteSession, remoteRoot: String, serverDisk: URL) throws {
        let fm = FileManager.default
        let local = fm.temporaryDirectory.appendingPathComponent("SyncRemote-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: local); try? fm.removeItem(at: serverDisk) }
        try fm.createDirectory(at: local.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: serverDisk, withIntermediateDirectories: true)
        let hourAgo = Date().addingTimeInterval(-3600), twoHoursAgo = Date().addingTimeInterval(-7200)
        func put(_ dir: URL, _ name: String, _ text: String, _ date: Date) throws {
            try Data(text.utf8).write(to: dir.appendingPathComponent(name))
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        try put(local, "same.txt", "same", twoHoursAgo); try put(serverDisk, "same.txt", "same", twoHoursAgo)
        try put(local, "changed.txt", "old", twoHoursAgo); try put(serverDisk, "changed.txt", "newer", hourAgo)
        try put(local, "local-only.txt", "mine", hourAgo)
        try put(local.appendingPathComponent("sub"), "deep.txt", "deep", hourAgo)
        try put(serverDisk, "remote-only.txt", "theirs", hourAgo)

        let lookup: SyncSessionLookup = { RemoteSession.sessionID(of: $0) == session.id ? session : nil }
        var cfg = SyncConfiguration(left: local, right: session.url(for: remoteRoot))
        let first = try SyncEngine.compare(cfg, sessions: lookup)
        func action(_ c: SyncComparison, _ path: String) -> SyncAction? { c.rows.first { $0.path == path }?.action }
        try expect(first.rows.first { $0.path == "same.txt" }?.state == .identical, "same file: \(first.rows)")
        try expect(action(first, "local-only.txt") == .copyToRight && action(first, "sub/deep.txt") == .copyToRight, "upload planned")
        try expect(action(first, "remote-only.txt") == .copyToLeft && action(first, "changed.txt") == .copyToLeft, "download planned")
        let report = SyncExecutor.run(SyncPlan(rows: first.rows, config: cfg), options: SyncRunOptions(), sessions: lookup)
        try expect(report.errors.isEmpty && report.skipped.isEmpty && report.copied == 4, "sync: \(report)")
        try expect(fm.contents(atPath: serverDisk.appendingPathComponent("sub/deep.txt").path) == Data("deep".utf8), "uploaded into a new folder")
        try expect(fm.contents(atPath: local.appendingPathComponent("changed.txt").path) == Data("newer".utf8), "newer file downloaded")
        let second = try SyncEngine.compare(cfg, sessions: lookup)
        try expect(second.rows.allSatisfy { $0.state == .identical }, "identical after sync (dates kept): \(second.rows.filter { $0.state != .identical })")

        try put(serverDisk, "extra.txt", "x", hourAgo)
        cfg.asymmetric = true
        let third = try SyncEngine.compare(cfg, sessions: lookup)
        try expect(action(third, "extra.txt") == .deleteRight, "asymmetric: delete on the server")
        let plan = SyncPlan(rows: third.rows, config: cfg)
        let del = SyncExecutor.run(plan, options: SyncRunOptions(), sessions: lookup, trash: { _ in throw Fail(description: "local trash used") })
        try expect(del.deleted == 1 && del.errors.isEmpty && !fm.fileExists(atPath: serverDisk.appendingPathComponent("extra.txt").path), "deleted: \(del)")
        do { _ = try SyncEngine.compare(SyncConfiguration(left: local, right: session.url(for: remoteRoot)), sessions: { _ in nil }); throw Fail(description: "closed session") }
        catch let e as SearchValidationError { try expect(e.message.contains("closed"), e.message) }
    }

    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("SFTP profiles: protocol, port 22, key login, old saved profiles still load") {
            var p = FTPProfile()
            p.name = "s"; p.host = "files.example.com"; p.connectionProtocol = .sftp
            try expect(p.setHostAndPort("files.example.com") && p.port == 22, "SFTP defaults to port 22")
            try expect(p.hostAndPort == "files.example.com" && p.isEncrypted, "SFTP is encrypted")
            p.username = "deploy"; p.sshAuth = .keyFile; p.keyFile = ""
            try expect(p.problems.contains { $0.contains("key file") }, "key file required: \(p.problems)")
            p.keyFile = "~/definitely-missing-key"
            try expect(p.problems.contains { $0.contains("cannot be read") }, "missing key reported")
            p.sshAuth = .password
            try expect(p.problems.isEmpty, "password login needs no key: \(p.problems)")
            p.username = "-oProxyCommand=x"
            try expect(!p.problems.isEmpty, "user name that looks like an option is refused")
            p.username = "user@example.com"
            try expect(p.problems.isEmpty && p.summary.hasPrefix("SFTP (SSH password)"), "e-mail style user names: \(p.summary)")
            try expect(!FTPSecurity.allCases.map(\.label).joined().lowercased().contains("sftp"), "SFTP is not an FTP security mode")
            // A profile saved before SFTP existed (no new keys) still decodes, as FTP.
            let old = #"[{"id":"0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0","name":"Old","host":"h","port":21,"username":"u","anonymous":false,"remoteDirectory":"","localDirectory":"","security":"explicitTLS","passive":true,"savePassword":true,"serverType":"automatic","transferMode":"binary","commandsAfterLogin":[],"cacheListings":true,"proxyKind":"none","proxyHost":"","proxyUsername":""}]"#
            let decoded = try JSONDecoder().decode([FTPProfile].self, from: Data(old.utf8))
            try expect(decoded.first?.name == "Old" && decoded.first?.isSFTP == false, "old profile loads")
            var s = p
            s.keyFile = "~/.ssh/id_ed25519"; s.trustedHostKeys = ["ssh-ed25519 AAAAC3Nza"]
            let back = try JSONDecoder().decode(FTPProfile.self, from: JSONEncoder().encode(s))
            try expect(back == s, "SFTP fields round-trip")
        }

        testRunner("SFTP arguments: host keys checked, secrets never in arguments, names escaped") {
            var p = FTPProfile()
            p.connectionProtocol = .sftp; p.host = "files.example.com"; p.port = 2222; p.username = "deploy"
            p.sshAuth = .keyFile; p.keyFile = "~/keys/my key%1"
            let c = SFTPClient(profile: p, secret: "s3cret-pass")
            let args = c.arguments(interactiveSecret: true)
            let joined = args.joined(separator: " ")
            try expect(args.prefix(2) == ["-o", "BatchMode=no"] && args.firstIndex(of: "-b")! > 1, "BatchMode before -b")
            try expect(args.contains("StrictHostKeyChecking=yes") && args.contains("UpdateHostKeys=no"), "host keys always checked")
            try expect(!joined.contains("s3cret"), "secret not in arguments")
            try expect(args.contains(NSHomeDirectory() + "/keys/my key%%1") && args.contains("IdentitiesOnly=yes"), "key file: \(args)")
            try expect(args.last == "files.example.com" && args.contains("User=deploy") && args.contains("2222"), "destination")
            try expect(!c.arguments(interactiveSecret: false).contains("BatchMode=no"), "no secret = never prompts")
            p.sshAuth = .password
            try expect(SFTPClient(profile: p, secret: nil).arguments(interactiveSecret: false).contains("PubkeyAuthentication=no"), "password login")
            p.proxyKind = .socks5; p.proxyHost = "proxy.local:1080"
            try expect(SFTPClient(profile: p, secret: nil).arguments(interactiveSecret: false).contains("ProxyCommand=/usr/bin/nc -X 5 -x proxy.local:1080 %h %p"), "SOCKS proxy")
            try expect(try SFTPClient.quote("/a b/[x]*?\"q'.txt") == #"/a\ b/\[x\]\*\?\"q\'.txt"#, "escaping: \(try SFTPClient.quote("/a b/[x]*?\"q'.txt"))")
            try expect(try SFTPClient.quote("/żółw/x-1_2.txt") == "/żółw/x-1_2.txt", "non-ASCII kept")
            do { _ = try SFTPClient.quote("/a\nrm -r /"); throw Fail(description: "newline accepted") } catch let e as FTPError {
                guard case .invalid = e else { throw e }
            }
            try expect(SFTPClient.isValidHostKey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKcj+/=") && !SFTPClient.isValidHostKey("ssh-ed25519 AAAA\n[evil]:22 ssh-rsa B")
                       && !SFTPClient.isValidHostKey("@cert-authority * ssh-rsa AAAA"), "host key lines validated")
        }

        testRunner("SFTP errors: host keys, login, missing files and network problems are told apart") {
            func err(_ code: Int32, _ text: String) -> FTPError { SFTPClient.error(for: .init(exitCode: code, sections: [], errorText: text)) }
            try expect(err(255, "No ED25519 host key is known for [h]:22 and you have requested strict checking.\nHost key verification failed.\n") == .hostKeyUnknown, "unknown key")
            try expect(err(255, "@@@\nWARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.") == .hostKeyChanged, "changed key")
            try expect(err(255, "deploy@h: Permission denied (publickey).\r\nConnection closed") == .authentication, "login failed")
            try expect(err(255, "ssh: Could not resolve hostname nope: nodename nor servname provided") == .hostNotFound, "DNS")
            try expect(err(255, "ssh: connect to host h port 22: Connection refused") == .refused, "refused")
            try expect(err(1, "remote open(\"/x\"): Permission denied") == .permissionDenied("/x") || err(1, "remote open(\"/x\"): Permission denied") == .permissionDenied(""), "permission")
            try expect(err(1, "File \"/x\" not found.") == .notFound(""), "missing file")
            if case .keyFile = err(255, "Load key \"/k\": invalid format") {} else { throw Fail(description: "bad key file") }
        }

        let server: TestSSHServer
        do { server = try TestSSHServer() } catch {
            testRunner("SFTP live server") { throw error }
            return
        }
        defer { server.stop() }
        let www = server.root.appendingPathComponent("www").path

        testRunner("SFTP host keys: unknown keys stop the connection, trusted keys connect, changed keys are refused") {
            do { _ = try SFTPClient(profile: server.profile(trusted: false), secret: nil).connect(cancel: nil); throw Fail(description: "unknown host accepted") }
            catch let e as FTPError { try expect(e == .hostKeyUnknown, "unknown: \(e)") }
            let found = SFTPClient.fetchHostKeys(host: "127.0.0.1", port: server.port)
            try expect(found?.summary.contains("SHA256:") == true && found?.keys.isEmpty == false, "fingerprints shown: \(String(describing: found))")
            let client = SFTPClient(profile: server.profile(), secret: nil)
            defer { client.close() }
            let entries = try client.connect(cancel: nil)
            try expect(Set(entries.map(\.name)) == ["assets", "index.html", "odd [1] *\"q'.txt"], "listing: \(entries.map(\.name))")
            try expect(client.startPath == www && client.entryPath?.hasPrefix("/") == true, "start \(client.startPath)")
            var wrong = server.profile(trusted: false)
            wrong.trustedHostKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKcj5ehxb+vCiyWgIYNhuhrAyeAp1JDoKT6naTUR/TsW"]
            do { _ = try SFTPClient(profile: wrong, secret: nil).connect(cancel: nil); throw Fail(description: "changed key accepted") }
            catch let e as FTPError { try expect(e == .hostKeyChanged, "changed: \(e)") }
        }

        testRunner("SFTP key with passphrase: detected, unlocked through the helper, secret file removed, wrong one fails") {
            try expect(SFTPClient.keyNeedsPassphrase(server.protectedKey) && !SFTPClient.keyNeedsPassphrase(server.plainKey), "passphrase detection")
            let profile = server.profile(key: server.protectedKey)
            do { _ = try SFTPClient(profile: profile, secret: "wrong one").connect(cancel: nil); throw Fail(description: "wrong passphrase") }
            catch let e as FTPError { try expect(e == .authentication, "wrong passphrase: \(e)") }
            let client = SFTPClient(profile: profile, secret: server.passphrase)
            defer { client.close() }
            try expect(try client.connect(cancel: nil).contains { $0.name == "index.html" }, "logged in with passphrase")
            try expect(try client.list(www + "/assets", cancel: nil).first?.size == 90_000, "reuses the connection")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: SFTPClient.workDirectory.path)) ?? []
            try expect(!leftovers.contains { $0.hasSuffix(".pw") }, "no secret file left: \(leftovers)")
        }

        testRunner("SFTP files: download, upload into new folders, odd names, rename, delete, verified sizes") {
            let client = SFTPClient(profile: server.profile(), secret: nil)
            defer { client.close() }
            _ = try client.connect(cancel: nil)
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("SFTPLocal-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: local) }
            var seen: Int64 = 0
            try client.download(www + "/assets/big.bin", to: local.appendingPathComponent("big.bin"), expectedSize: 90_000,
                                resume: false, cancel: nil) { seen = $0 }
            try expect(FTPClient.fileSize(local.appendingPathComponent("big.bin")) == 90_000 && seen == 90_000, "download")
            try client.download(www + "/odd [1] *\"q'.txt", to: local.appendingPathComponent("odd.txt"), expectedSize: 3, resume: false, cancel: nil, progress: nil)
            try expect(try String(contentsOf: local.appendingPathComponent("odd.txt")) == "odd", "odd remote name")
            do {
                try client.download(www + "/index.html", to: local.appendingPathComponent("x.html"), expectedSize: 5, resume: false, cancel: nil, progress: nil)
                throw Fail(description: "size mismatch accepted")
            } catch FTPError.verificationFailed {}
            try expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("x.html").path), "unverified file not put in place")
            try Data("upload [me]".utf8).write(to: local.appendingPathComponent("up [1].txt"))
            try client.upload(local.appendingPathComponent("up [1].txt"), to: www + "/new dir/deep/up *.txt", resume: false, cancel: nil, progress: nil)
            try expect(FileManager.default.contents(atPath: www + "/new dir/deep/up *.txt") == Data("upload [me]".utf8), "upload into new folders")
            try client.makeDirectory(www + "/made")
            try client.rename(www + "/new dir/deep/up *.txt", to: www + "/made/renamed.txt")
            try expect(FileManager.default.fileExists(atPath: www + "/made/renamed.txt"), "rename")
            try client.deleteFile(www + "/made/renamed.txt")
            try client.removeDirectory(www + "/made")
            try expect(!FileManager.default.fileExists(atPath: www + "/made"), "delete and rmdir")
            do { try client.deleteFile(www + "/nothing-here"); throw Fail(description: "missing") } catch let e as FTPError {
                try expect(e == .notFound(www + "/nothing-here"), "missing file: \(e)")
            }
            do { _ = try client.list(www + "/nope", cancel: nil); throw Fail(description: "missing dir") } catch let e as FTPError {
                guard case .notFound = e else { throw e }
            }
        }

        testRunner("SFTP panel: double-click and → enter a link to a folder; a link to a file is not entered") {
            let fm = FileManager.default
            try fm.createSymbolicLink(atPath: www + "/link-to-assets", withDestinationPath: "assets")
            try fm.createSymbolicLink(atPath: www + "/link-to-index", withDestinationPath: "index.html")
            defer { try? fm.removeItem(atPath: www + "/link-to-assets"); try? fm.removeItem(atPath: www + "/link-to-index") }
            let local = fm.temporaryDirectory
            let view = CommanderView(model: CommanderModel(left: PanelModel(directory: local), right: PanelModel(directory: local)))
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            view.layout()
            let suite = "SFTPTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let ftp = view.ftp
            ftp.repository = FTPProfileRepository(defaults: defaults, credentials: MemoryCredentialStore())
            ftp.runSynchronously = true
            var messages: [String] = []
            ftp.showMessage = { title, text in messages.append(title + ": " + text) }
            var outcome: Result<Void, FTPError>?
            ftp.connect(server.profile(), password: nil, side: .right) { outcome = $0 }
            guard case .success = outcome else { throw Fail(description: "connect: \(String(describing: outcome))") }
            let right = view.rightView
            defer { ftp.disconnect(.right) }
            try expect(right.remote?.insecure == false && right.remote?.status.hasPrefix("SFTP") == true, "SFTP marked encrypted")
            right.model.focus(name: "link-to-assets", visibleRows: 20)
            try expect(right.model.currentEntry?.isSymlink == true, "link listed as a link")
            right.onOpen?()                                            // double-click
            try expect(RemoteSession.path(of: right.model.directory) == www + "/link-to-assets"
                       && right.model.entries.contains { $0.name == "big.bin" }, "entered the linked folder: \(right.model.directory) \(messages)")
            view.perform(.parentFolder)
            try expect(RemoteSession.path(of: right.model.directory) == www, "back up")
            // ⌃U swaps panels: the server moves to the left with its marks; disconnecting still returns to the local folder.
            let leftBefore = view.leftView.model.directory
            right.model.focus(name: "index.html", visibleRows: 20)
            view.perform(.toggleSelection)
            view.model.activate(.left)
            view.perform(.swapPanels)
            try expect(view.leftView.model.isRemote && RemoteSession.path(of: view.leftView.model.directory) == www
                       && view.leftView.model.marked == ["index.html"] && view.leftView.remote?.status.hasPrefix("SFTP") == true, "server now on the left")
            try expect(view.rightView.model.directory == leftBefore && view.rightView.remote == nil && view.model.activeSide == .left, "local folder now on the right")
            view.perform(.swapPanels)
            try expect(right.model.isRemote && view.leftView.model.directory == leftBefore, "swapped back")
            view.model.activate(.right)
            right.model.focus(name: "link-to-index", visibleRows: 20)
            view.perform(.enterFolder)                                 // → on a link to a file
            try expect(RemoteSession.path(of: right.model.directory) == www, "a file link is not entered")
        }

        testRunner("SFTP Find Files: names and text on the server") {
            let session = RemoteSession(client: SFTPClient(profile: server.profile(), secret: nil))
            defer { session.client.close() }
            _ = try session.client.connect(cancel: nil)
            var c = FileSearchConfiguration()
            c.general.searchPaths = [session.url(for: www).absoluteString]
            c.general.filenamePattern = "*"
            c.general.content.enabled = true
            c.general.content.expression = "hello"
            let r = try FileSearch(config: c, base: URL(fileURLWithPath: "/"),
                                   sessions: { RemoteSession.sessionID(of: $0) == session.id ? session : nil }).run()
            try expect(r.found.map { RemoteSession.path(of: $0.url) } == [www + "/index.html"], "found: \(r.found.map(\.url)) \(r.errors)")
        }

        testRunner("SFTP Synchronize: local folder against a server folder, dates kept, deletions on the server") {
            let session = RemoteSession(client: SFTPClient(profile: server.profile(), secret: nil))
            defer { session.client.close() }
            _ = try session.client.connect(cancel: nil)
            try syncRoundTrip(session: session, remoteRoot: www + "/sync", serverDisk: URL(fileURLWithPath: www + "/sync"))
        }

        testRunner("SFTP in panels and transfers: session, tree download and upload, close ends the connection") {
            let session = RemoteSession(client: SFTPClient(profile: server.profile(), secret: nil))
            let listing = try session.client.connect(cancel: nil)
            session.store(listing, for: session.client.startPath)
            try expect(session.addressLabel.hasPrefix("sftp://") && session.statusLabel.hasPrefix("SFTP · CONNECTED"), "labels")
            let entries = try RemoteLister(session: session).entries(in: session.url(for: www))
            try expect(entries.contains { $0.name == "assets" && $0.kind == .directory }, "panel entries")
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("SFTPTree-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: local) }
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            let manager = TransferManager()
            manager.runSynchronously = true
            let down = try TransferPlanner.plan([.init(location: .remote(session, www + "/assets"), isFolder: true, size: 0)], into: .local(local))
            let job = TransferJob(title: "down", items: down.items, isMove: false)
            manager.enqueue(job)
            try expect(job.failedCount == 0 && FTPClient.fileSize(local.appendingPathComponent("assets/big.bin")) == 90_000, "tree download: \(job.results)")
            let up = try TransferPlanner.plan([.init(location: .local(local.appendingPathComponent("assets")), isFolder: true, size: 0)],
                                              into: .remote(session, www + "/copy"))
            let upJob = TransferJob(title: "up", items: up.items, isMove: false)
            manager.enqueue(upJob)
            try expect(upJob.failedCount == 0 && FileManager.default.contents(atPath: www + "/copy/assets/big.bin")?.count == 90_000, "tree upload: \(upJob.results)")
            let socket = (session.client as! SFTPClient).controlPath
            try expect(FileManager.default.fileExists(atPath: socket), "shared connection open")
            session.client.close()
            var open = true
            for _ in 0..<40 where open {
                open = FileManager.default.fileExists(atPath: socket)
                if open { Thread.sleep(forTimeInterval: 0.05) }
            }
            try expect(!open, "connection closed")
        }
    }
}
