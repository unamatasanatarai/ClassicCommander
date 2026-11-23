import Foundation

/// Talks SFTP through the system's OpenSSH client (/usr/bin/sftp in batch mode).
///
/// - Login with a private key file (and its passphrase, if it has one) or a password.
/// - Host keys are always checked (StrictHostKeyChecking): against ~/.ssh/known_hosts and the keys
///   the user trusted for this profile. Unknown and changed keys stop the connection.
/// - Secrets never appear in arguments or the environment: ssh asks a tiny helper script
///   (SSH_ASKPASS), which reads a 0600 file in a private folder that exists only while ssh runs.
/// - One SSH connection is kept open per session (ControlMaster), so browsing does not log in again.
public final class SFTPClient: RemoteClient {
    public let profile: FTPProfile
    private let secret: String?
    var sftpPath = "/usr/bin/sftp"
    /// The login directory (from pwd).
    public private(set) var entryPath: String?
    private let token = String(UUID().uuidString.prefix(8)).lowercased()

    public init(profile: FTPProfile, secret: String?) {
        self.profile = profile
        self.secret = secret?.isEmpty == true ? nil : secret
    }

    deinit { close() }

    // MARK: Private files

    /// A short private folder (Unix socket paths are limited to 104 bytes).
    static let workDirectory: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cc-ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // Secrets left behind by a session that crashed are removed.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".pw") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        return dir
    }()

    /// Writes a file only this user can read: created 0600 from the start (no moment with wider rights).
    static func writePrivateFile(_ url: URL, _ data: Data) -> Bool {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return data.withUnsafeBytes { buffer in Darwin.write(fd, buffer.baseAddress, buffer.count) == buffer.count }
    }

    /// The socket of this session's shared SSH connection (exists while it is open).
    var controlPath: String { Self.workDirectory.appendingPathComponent(token).path }
    private var knownHostsPath: String { Self.workDirectory.appendingPathComponent(token + ".kh").path }

    /// The helper ssh runs to get the passphrase or password: prints the file named in CC_SECRET_FILE.
    static let askPassPath: String = {
        let url = workDirectory.appendingPathComponent("askpass")
        let script = "#!/bin/sh\nexec /bin/cat \"$CC_SECRET_FILE\"\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700])
        }
        return url.path
    }()

    /// "host" for port 22, "[host]:port" otherwise — the known_hosts spelling.
    static func knownHostsName(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// Writes the keys the user trusted for this profile as a known_hosts file.
    private func writeKnownHosts() {
        let name = Self.knownHostsName(host: profile.host, port: profile.port)
        let lines = profile.trustedHostKeys.filter(Self.isValidHostKey).map { "\(name) \($0)\n" }.joined()
        FileManager.default.createFile(atPath: knownHostsPath, contents: Data(lines.utf8), attributes: [.posixPermissions: 0o600])
    }

    /// "type base64" with nothing else on the line.
    static func isValidHostKey(_ line: String) -> Bool {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return false }
        let type = parts[0], blob = parts[1]
        let typeOK = ["ssh-", "ecdsa-", "sk-"].contains { type.hasPrefix($0) }
            && type.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-@.".unicodeScalars.contains($0) }
        let blobOK = blob.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+/=".unicodeScalars.contains($0)) }
        return typeOK && blobOK
    }

    // MARK: Arguments

    /// sftp's options (the destination host comes last).
    func arguments(interactiveSecret: Bool) -> [String] {
        var args = [
            // BatchMode must come before -b (ssh keeps the first value): "no" lets ssh ask the helper.
            "-o", "BatchMode=\(interactiveSecret ? "no" : "yes")",
            "-b", "-",
            "-P", String(profile.port),
            "-o", "User=\(profile.username)",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsPath) ~/.ssh/known_hosts",
            "-o", "UpdateHostKeys=no",
            "-o", "ConnectTimeout=20",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=120",
        ]
        switch profile.sshAuth {
        case .keyFile:
            // "%" starts an ssh token in IdentityFile; a literal one is written "%%".
            args += ["-i", profile.keyFilePath.replacingOccurrences(of: "%", with: "%%"),
                     "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey"]
        case .password:
            args += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"]
        }
        if profile.proxyKind != .none,
           let (host, port) = FTPProfile.parseHostPort(profile.proxyHost, defaultPort: profile.proxyKind == .http ? 8080 : 1080) {
            // Validated host and port only: ProxyCommand runs through the shell.
            let kind = profile.proxyKind == .http ? "connect" : "5"
            let proxy = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
            args += ["-o", "ProxyCommand=/usr/bin/nc -X \(kind) -x \(proxy) %h %p"]
        }
        args.append(profile.host.contains(":") ? "[\(profile.host)]" : profile.host)
        return args
    }

    /// A path as one sftp batch argument: every ASCII character other than letters, digits and
    /// "/._-+,=:@%" gets a backslash (so spaces, quotes and glob characters stay literal).
    static func quote(_ path: String) throws -> String {
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw FTPError.invalid("Invalid characters in a remote name: \(path)")
        }
        var out = ""
        for c in path.unicodeScalars {
            if c.isASCII && !(CharacterSet.alphanumerics.contains(c) || "/._-+,=:@%".unicodeScalars.contains(c)) {
                out += "\\"
            }
            out.unicodeScalars.append(c)
        }
        return out
    }

    // MARK: Running sftp

    struct Result {
        let exitCode: Int32
        /// Output of each command, in order (split at sftp's "sftp> command" echo lines).
        let sections: [String]
        let errorText: String
    }

    /// Runs one sftp batch. A failing command stops the batch, unless it starts with "-".
    func run(_ commands: [String], cancel: CancelFlag? = nil, poll: (() -> Void)? = nil) throws -> Result {
        writeKnownHosts()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sftpPath)
        process.arguments = arguments(interactiveSecret: secret != nil)
        var env = ProcessInfo.processInfo.environment
        var secretFile: URL?
        if let secret = secret {
            let file = Self.workDirectory.appendingPathComponent("\(token)-\(UUID().uuidString.prefix(8)).pw")
            guard Self.writePrivateFile(file, Data(secret.utf8)) else {
                throw FTPError.invalid("Could not prepare the login (temporary folder not writable).")
            }
            secretFile = file
            env["SSH_ASKPASS"] = Self.askPassPath
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["CC_SECRET_FILE"] = file.path
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        }
        defer { if let f = secretFile { try? FileManager.default.removeItem(at: f) } }
        process.environment = env

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        var outData = Data(), errData = Data()
        let lock = NSLock()
        output.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); outData.append(d); lock.unlock()
        }
        errors.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); errData.append(d); lock.unlock()
        }
        func stopReading() {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
        }
        // Exit is signalled, not polled: the loop below only wakes to check Cancel and report progress.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        input.fileHandleForWriting.write(Data((commands.joined(separator: "\n") + "\n").utf8))
        try? input.fileHandleForWriting.close()
        while exited.wait(timeout: .now() + 0.25) == .timedOut {
            if cancel?.isCancelled == true {
                process.terminate()
                process.waitUntilExit()
                stopReading()
                throw FTPError.cancelled
            }
            poll?()
        }
        process.waitUntilExit()
        stopReading()
        lock.lock()
        outData.append(output.fileHandleForReading.readDataToEndOfFile())
        errData.append(errors.fileHandleForReading.readDataToEndOfFile())
        let out = String(decoding: outData, as: UTF8.self)
        let err = redact(String(decoding: errData, as: UTF8.self))
        lock.unlock()
        return Result(exitCode: process.terminationStatus, sections: Self.sections(out), errorText: err)
    }

    /// Splits batch output at the "sftp> …" lines sftp echoes before each command.
    static func sections(_ output: String) -> [String] {
        var result: [String] = []
        var current: [String]?
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("sftp> ") {
                if let c = current { result.append(c.joined(separator: "\n")) }
                current = []
            } else {
                current?.append(line)
            }
        }
        if let c = current { result.append(c.joined(separator: "\n")) }
        return result
    }

    func redact(_ text: String) -> String {
        guard let s = secret, s.count >= 2 else { return text }
        return text.replacingOccurrences(of: s, with: "••••")
    }

    /// Maps ssh/sftp failures to the same errors FTP uses (plus host key problems).
    static func error(for result: Result, path: String = "") -> FTPError {
        let text = result.errorText
        let lower = text.lowercased()
        let first = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("Connection closed") } ?? ""
        if lower.contains("remote host identification has changed") || lower.contains("host key for") && lower.contains("has changed") {
            return .hostKeyChanged
        }
        if lower.contains("host key verification failed") || lower.contains("no ") && lower.contains("host key is known") {
            return .hostKeyUnknown
        }
        if lower.contains("could not resolve hostname") || lower.contains("nodename nor servname") { return .hostNotFound }
        if lower.contains("connection refused") { return .refused }
        if lower.contains("timed out") { return .timeout }
        if lower.contains("load key") || lower.contains("invalid format") || lower.contains("bad permissions")
            || lower.contains("identity file") && lower.contains("not accessible") {
            return .keyFile(first)
        }
        if lower.contains("permission denied (") || lower.contains("too many authentication failures") { return .authentication }
        if lower.contains("couldn't open local file") || lower.contains("no space left") && lower.contains("local") { return .localDiskFull }
        if lower.contains("quota") || lower.contains("no space left") { return .quotaExceeded }
        if lower.contains("permission denied") { return .permissionDenied(path) }
        if lower.contains("not found") || lower.contains("no such file") { return .notFound(path) }
        if result.exitCode == 255 {
            if lower.contains("broken pipe") || lower.contains("reset by peer") || lower.contains("closed by remote host") || first.isEmpty {
                return .connectionLost
            }
        }
        return .server(first.isEmpty ? "sftp exit code \(result.exitCode)" : first)
    }

    private func check(_ result: Result, path: String = "") throws {
        guard result.exitCode == 0 else { throw Self.error(for: result, path: path) }
    }

    // MARK: Operations

    @discardableResult
    public func connect(cancel: CancelFlag? = nil) throws -> [RemoteEntry] {
        let start = profile.remoteDirectory
        // pwd first (the login folder), then list the start folder from inside it (plain names).
        let result = try run(["pwd"] + (start.isEmpty ? [] : ["cd \(try Self.quote(start))"]) + ["ls -lan"], cancel: cancel)
        try check(result, path: start)
        if let pwd = result.sections.first?.components(separatedBy: "\n").first(where: { $0.hasPrefix("Remote working directory: ") }) {
            let dir = String(pwd.dropFirst("Remote working directory: ".count)).trimmingCharacters(in: .whitespaces)
            if dir.hasPrefix("/") { entryPath = dir }
        }
        return FTPListingParser.parse(result.sections.last ?? "", type: .unixList)
    }

    public var startPath: String {
        if !profile.remoteDirectory.isEmpty { return profile.remoteDirectory }
        return entryPath ?? "/"
    }

    public func list(_ path: String, cancel: CancelFlag? = nil) throws -> [RemoteEntry] {
        // "cd" first: it fails unless the path is a folder (ls alone would also "list" a single file).
        // "ls -n" is formatted by sftp itself: numeric owners, dates in this Mac's time zone.
        let result = try run(["cd \(try Self.quote(path))", "ls -lan"], cancel: cancel)
        try check(result, path: path)
        return FTPListingParser.parse(result.sections.dropFirst().first ?? "", type: .unixList)
    }

    public func download(_ path: String, to local: URL, expectedSize: Int64?, resume: Bool = false,
                         cancel: CancelFlag? = nil, progress: ((Int64) -> Void)? = nil) throws {
        let part = local.appendingPathExtension("ccpart")
        let fm = FileManager.default
        if !resume { try? fm.removeItem(at: part) }
        try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        // -p keeps the modification date (Synchronize compares dates).
        let verb = resume && fm.fileExists(atPath: part.path) ? "reget -p" : "get -p"
        let result: Result
        do {
            result = try run(["\(verb) \(try Self.quote(path)) \(try Self.quote(part.path))"], cancel: cancel,
                             poll: { progress?(FTPClient.fileSize(part)) })
        } catch FTPError.cancelled {
            try? fm.removeItem(at: part)
            throw FTPError.cancelled
        }
        try check(result, path: path)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: Data()) }
        let got = FTPClient.fileSize(part)
        if let expected = expectedSize, got != expected {
            throw FTPError.verificationFailed("received \(got) of \(expected) bytes")
        }
        if fm.fileExists(atPath: local.path) { try fm.removeItem(at: local) }
        try fm.moveItem(at: part, to: local)
        Quarantine.mark(local, origin: "sftp://\(profile.host.contains(":") ? "[\(profile.host)]" : profile.host):\(profile.port)")
        progress?(got)
    }

    public func upload(_ local: URL, to path: String, resume: Bool = false, cancel: CancelFlag? = nil,
                       progress: ((Int64) -> Void)? = nil) throws {
        let size = FTPClient.fileSize(local)
        // Create missing parent folders; "-" ignores "already exists".
        var commands: [String] = []
        var parent = ""
        for part in RemoteSession.normalize(path).split(separator: "/").dropLast() {
            parent += "/" + part
            commands.append("-mkdir \(try Self.quote(parent))")
        }
        let target = try Self.quote(path)
        commands.append("\(resume ? "reput -p" : "put -p") \(try Self.quote(local.path)) \(target)")
        commands.append("ls -l \(target)")
        let result = try run(commands, cancel: cancel)
        try check(result, path: path)
        // The listing of the uploaded file is the last section: check its size.
        if let line = result.sections.last?.components(separatedBy: "\n").first(where: { !$0.isEmpty }),
           let remote = Self.sizeField(line), remote != size {
            throw FTPError.verificationFailed("the server has \(remote) of \(size) bytes")
        }
        progress?(size)
    }

    /// The size in an "ls -l" line ("-rw-r--r--  ? 501  0  1234 Nov 22 18:21 /path").
    static func sizeField(_ line: String) -> Int64? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        return fields.count > 4 ? Int64(fields[4]) : nil
    }

    /// Creates a folder and any missing parents; the folder itself must not exist yet.
    public func makeDirectory(_ path: String) throws {
        let parts = RemoteSession.normalize(path).split(separator: "/")
        var commands: [String] = []
        var parent = ""
        for part in parts.dropLast() {
            parent += "/" + part
            commands.append("-mkdir \(try Self.quote(parent))")
        }
        commands.append("mkdir \(try Self.quote(path))")
        try check(try run(commands), path: path)
    }
    public func deleteFile(_ path: String) throws { try simple("rm", path) }
    public func removeDirectory(_ path: String) throws { try simple("rmdir", path) }

    public func rename(_ from: String, to: String) throws {
        try check(try run(["rename \(try Self.quote(from)) \(try Self.quote(to))"]), path: from)
    }

    /// Nothing to do: uploads use "put -p", which keeps the local file's date.
    public func setModificationDate(_ date: Date, of path: String) throws {}

    private func simple(_ verb: String, _ path: String) throws {
        try check(try run(["\(verb) \(try Self.quote(path))"]), path: path)
    }

    /// Stops the shared SSH connection and removes this session's files.
    public func close() {
        let socket = controlPath
        if FileManager.default.fileExists(atPath: socket) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "ControlPath=\(socket)", "-O", "exit", "-p", String(profile.port),
                           profile.host.contains(":") ? "[\(profile.host)]" : profile.host]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { p.waitUntilExit() }
        }
        try? FileManager.default.removeItem(atPath: knownHostsPath)
    }

    // MARK: Keys

    /// The server's host keys and their fingerprints, for the trust dialog (ssh-keyscan; public data only).
    public static func fetchHostKeys(host: String, port: Int) -> (summary: String, keys: [String])? {
        guard FTPProfile.isValidHost(host), !host.hasPrefix("-"), (1...65535).contains(port) else { return nil }
        guard let scan = runTool("/usr/bin/ssh-keyscan", ["-T", "10", "-p", String(port), host]) else { return nil }
        let keys = String(decoding: scan, as: UTF8.self).components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .compactMap { line -> String? in
                let parts = line.split(separator: " ")
                guard parts.count >= 3 else { return nil }
                let key = "\(parts[1]) \(parts[2])"
                return isValidHostKey(key) ? key : nil
            }
        guard !keys.isEmpty else { return nil }
        var fingerprints: [String] = []
        for key in keys {
            if let fp = runTool("/usr/bin/ssh-keygen", ["-l", "-f", "-"], input: Data("x \(key)\n".utf8)) {
                let parts = String(decoding: fp, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                if parts.count >= 2 { fingerprints.append("\(parts.last ?? "")  \(parts[1])") }
            }
        }
        return (fingerprints.joined(separator: "\n"), keys)
    }

    /// Whether a private key is protected by a passphrase (it cannot be read with an empty one).
    public static func keyNeedsPassphrase(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-y", "-P", "", "-f", (path as NSString).expandingTildeInPath]
        let err = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        guard (try? p.run()) != nil else { return false }
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus != 0 && text.lowercased().contains("passphrase")
    }

    private static func runTool(_ path: String, _ args: [String], input: Data? = nil) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let inPipe = Pipe(), out = Pipe()
        p.standardInput = inPipe
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        if let input = input { inPipe.fileHandleForWriting.write(input) }
        try? inPipe.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
