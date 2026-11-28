import Foundation

/// What went wrong talking to a server, in words a user can act on. Never contains the password.
public enum FTPError: Error, Hashable {
    case authentication
    case hostNotFound
    case refused
    case timeout
    case tlsUnavailable
    case tlsFailed(String)
    case certificateUntrusted
    case pinnedKeyChanged
    case hostKeyUnknown
    case hostKeyChanged
    case keyFile(String)
    case permissionDenied(String)
    case notFound(String)
    case quotaExceeded
    case localDiskFull
    case connectionLost
    case passiveFailed
    case activeFailed
    case cancelled
    case verificationFailed(String)
    case invalid(String)
    case server(String)

    private static let simpleMessages: [FTPError: String] = [
        .authentication: "Login failed: the server rejected the user name or password.",
        .hostNotFound: "Server not found: check the host name (DNS lookup failed).",
        .refused: "Connection refused: the server is not accepting connections on that port.",
        .timeout: "The server did not answer in time (timeout).",
        .tlsUnavailable: "The server does not offer TLS. The connection was not made, because an encrypted connection was requested (it is never downgraded to plain FTP).",
        .certificateUntrusted: "The server's certificate is not trusted.",
        .pinnedKeyChanged: "The server's key no longer matches the one you trusted. This can mean the certificate was replaced — or an attack. The connection was not made.",
        .hostKeyUnknown: "The server's SSH host key is not known yet, so the connection was not made.",
        .hostKeyChanged: "The server's SSH host key does not match the one known for it. This can mean the server was reinstalled — or an attack. The connection was not made.",
        .quotaExceeded: "The server refused the file: storage quota exceeded or no space left on the server.",
        .localDiskFull: "Could not write the local file (disk full or not writable).",
        .connectionLost: "The connection was lost during the transfer.",
        .passiveFailed: "Passive mode data connection failed. Try turning Passive mode off (or check the firewall).",
        .activeFailed: "Active mode data connection failed. Try Passive mode.",
        .cancelled: "Cancelled.",
    ]

    public var message: String {
        if let fixed = Self.simpleMessages[self] { return fixed }
        return payloadMessage
    }

    private var payloadMessage: String {
        switch self {
        case .tlsFailed(let d): return "The encrypted (TLS) connection failed: \(d)"
        case .keyFile(let d): return "The key file could not be used: \(d)"
        case .verificationFailed(let d): return "The transfer could not be verified: \(d)"
        case .invalid(let d): return d
        default: return pathOrServerMessage
        }
    }

    private var pathOrServerMessage: String {
        switch self {
        case .permissionDenied(let d): return "Permission denied\(d.isEmpty ? "" : ": \(d)")."
        case .notFound(let d): return "Not found on the server\(d.isEmpty ? "" : ": \(d)")."
        case .server(let d): return "Server error: \(d)"
        default: return ""
        }
    }
}

/// Talks FTP / FTPS through the system's curl (/usr/bin/curl), one short connection per operation.
/// Credentials are written to curl's stdin as a config file, so they never appear in `ps` or logs.
public final class FTPClient: RemoteClient {
    public let profile: FTPProfile
    private let password: String?
    var curlPath = "/usr/bin/curl"
    /// The login directory reported by the server (from PWD). Absolute paths are used once it is known.
    public private(set) var entryPath: String?
    /// For automatic listing: MLSD stays on until the server rejects it.
    private var useMLSD = true

    public init(profile: FTPProfile, password: String?) {
        self.profile = profile
        self.password = password
    }

    // MARK: URLs and arguments

    /// The URL of a remote path. Absolute paths start with %2F so the server's root is used, not the login folder.
    public func url(for path: String, directory: Bool) -> String {
        let scheme = profile.security == .implicitTLS ? "ftps" : "ftp"
        let host = profile.host.contains(":") ? "[\(profile.host)]" : profile.host
        return "\(scheme)://\(host):\(profile.port)/\(Self.encodePath(path, directory: directory))"
    }

    private static func encodePath(_ path: String, directory: Bool) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#%")
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
        var p = segments.joined(separator: "/")
        if path.hasPrefix("/") { p = "%2F" + p }
        if directory && !p.isEmpty && !p.hasSuffix("/") { p += "/" }
        return p
    }

    /// curl options for every call. The second value is the config text fed on stdin (credentials).
    func baseArguments(textMode: Bool = false) -> (args: [String], config: String) {
        var args = ["--disable", "-K", "-", "--silent", "--show-error", "--path-as-is",
                    "--connect-timeout", "20", "--speed-limit", "1", "--speed-time", "90"]
        appendSecurityAndTransferArgs(to: &args, textMode: textMode)
        for command in profile.commandsAfterLogin where !command.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-Q", command]
        }
        var config = "user = \"\(Self.escape(profile.loginName)):\(Self.escape(profile.anonymous ? "classiccommander@" : password ?? ""))\"\n"
        appendProxyArguments(to: &args, config: &config)
        return (args, config)
    }

    private func appendSecurityAndTransferArgs(to args: inout [String], textMode: Bool) {
        if profile.security == .explicitTLS {
            args.append("--ssl-reqd")          // TLS or nothing: never downgrade
        }
        if profile.security.isEncrypted, let pin = profile.pinnedPublicKey {
            // The user trusted this exact key: skip CA validation but insist on the pinned key.
            args += ["--insecure", "--pinnedpubkey", pin]
        }
        // Passive mode connects to the control connection's host, never to an address the server names.
        args += profile.passive ? ["--ftp-pasv", "--ftp-skip-pasv-ip"] : ["--ftp-port", "-"]
        if textMode { args.append("--use-ascii") }
    }

    private func appendProxyArguments(to args: inout [String], config: inout String) {
        guard profile.proxyKind != .none else { return }
        args += ["--proxy", "\(proxyScheme())://\(profile.proxyHost)"]
        if profile.proxyKind == .http { args.append("--proxytunnel") }
        appendProxyUserConfig(to: &config)
    }

    private func proxyScheme() -> String {
        profile.proxyKind == .http ? "http" : "socks5h"
    }

    private func appendProxyUserConfig(to config: inout String) {
        if !profile.proxyUsername.isEmpty {
            config += "proxy-user = \"\(Self.escape(profile.proxyUsername)):\"\n"
        }
    }

    /// A value inside a quoted curl config string. Line breaks would end the line and start a new
    /// curl option, so control characters are refused before curl runs (see `checkCredentials`);
    /// they are escaped here as well, as a second line of defence.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// True for text with a control character (line breaks, NUL, …).
    static func hasControlCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// User name, password and proxy user go into curl's config and the FTP USER/PASS commands:
    /// control characters there could inject curl options or FTP commands, so they are refused.
    func checkCredentials() throws {
        for (what, value) in [("user name", profile.loginName), ("password", password ?? ""), ("proxy user", profile.proxyUsername)]
        where Self.hasControlCharacters(value) {
            throw FTPError.invalid("The \(what) contains invalid characters (line breaks or other control characters).")
        }
    }

    // MARK: Running curl

    struct Result {
        let exitCode: Int32
        let output: Data
        let errorText: String
    }

    /// Runs curl; `progress` gets the percentage curl reports (uploads), `poll` runs every 0.2 s.
    func run(_ extra: [String], textMode: Bool = false, cancel: CancelFlag? = nil,
             poll: (() -> Void)? = nil, progress: ((Double) -> Void)? = nil) throws -> Result {
        try checkCredentials()
        let (base, config) = baseArguments(textMode: textMode)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: curlPath)
        // --silent hides the progress bar, so it is dropped when progress is wanted (errors still show).
        let common = progress != nil ? base.filter { $0 != "--silent" } + ["--progress-bar"] : base
        process.arguments = common + extra
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        var outData = Data()
        var errText = ""
        let lock = NSLock()
        output.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); outData.append(d); lock.unlock()
        }
        errors.fileHandleForReading.readabilityHandler = { h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            lock.lock(); errText += chunk; lock.unlock()
            if let progress = progress, let pct = Self.lastPercentage(chunk) { progress(pct) }
        }
        // Exit is signalled, not polled: the loop below only wakes to check Cancel and report progress.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        input.fileHandleForWriting.write(Data(config.utf8))
        try? input.fileHandleForWriting.close()

        while exited.wait(timeout: .now() + RemoteTiming.pollInterval) == .timedOut {
            if cancel?.isCancelled == true {
                process.terminate()
                process.waitUntilExit()
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                throw FTPError.cancelled
            }
            poll?()
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        // Collect anything left in the pipes.
        let restOut = output.fileHandleForReading.readDataToEndOfFile()
        let restErr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lock.lock(); outData.append(restOut); errText += restErr; lock.unlock()
        return Result(exitCode: process.terminationStatus, output: outData, errorText: redact(errText))
    }

    static func lastPercentage(_ text: String) -> Double? {
        let matches = text.components(separatedBy: CharacterSet(charactersIn: "\r\n#"))
            .compactMap { part -> Double? in
                let t = part.trimmingCharacters(in: .whitespaces)
                guard t.hasSuffix("%") else { return nil }
                return Double(t.dropLast().trimmingCharacters(in: .whitespaces))
            }
        return matches.last
    }

    /// Removes the password from any text that might be shown.
    func redact(_ text: String) -> String {
        guard let p = password, p.count >= 2 else { return text }
        return text.replacingOccurrences(of: p, with: "••••")
    }

    private static let fixedExitErrors: [Int32: FTPError] = [
        6: .hostNotFound, 7: .refused, 28: .timeout, 67: .authentication, 64: .tlsUnavailable,
        60: .certificateUntrusted, 51: .certificateUntrusted, 58: .certificateUntrusted, 59: .certificateUntrusted, 83: .certificateUntrusted,
        90: .pinnedKeyChanged, 23: .localDiskFull,
        18: .connectionLost, 55: .connectionLost, 56: .connectionLost, 52: .connectionLost,
        13: .passiveFailed, 14: .passiveFailed, 15: .passiveFailed, 30: .activeFailed,
    ]

    /// Maps curl's exit status (and the server reply in its message) to an FTPError.
    static func error(for result: Result, path: String = "") -> FTPError {
        let msg = extractCurlMessage(from: result.errorText)
        if let fixed = fixedExitErrors[result.exitCode] { return fixed }
        return exitCodeError(result.exitCode, msg: msg, path: path)
    }

    private static func exitCodeError(_ code: Int32, msg: String, path: String) -> FTPError {
        if code == 35 || code == 80 { return .tlsFailed(msg) }
        if code == 9 || code == 78 { return notFoundOrPermissionError(msg: msg, path: path) }
        return nonTLSError(code, msg: msg, path: path)
    }

    private static func nonTLSError(_ code: Int32, msg: String, path: String) -> FTPError {
        if [25, 21, 19].contains(code) { return commandRefusedError(msg: msg, path: path) }
        return .server(msg.isEmpty ? "curl exit code \(code)" : msg)
    }

    private static func notFoundOrPermissionError(msg: String, path: String) -> FTPError {
        hasReply(msg, "550") && msg.lowercased().contains("perm") ? .permissionDenied(path) : .notFound(path)
    }

    private static func extractCurlMessage(from errorText: String) -> String {
        errorText.components(separatedBy: "\n").first { $0.hasPrefix("curl:") }?
            .replacingOccurrences(of: "curl: ", with: "")
            ?? errorText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasReply(_ msg: String, _ code: String) -> Bool {
        msg.contains(" \(code)") || msg.hasSuffix(code)
    }

    private static func commandRefusedError(msg: String, path: String) -> FTPError {
        if hasReply(msg, "552") || msg.contains("quota") { return .quotaExceeded }
        if isPermissionReply(msg) { return .permissionDenied(path) }
        return .server(msg.isEmpty ? "the server refused the command" : msg)
    }

    private static func isPermissionReply(_ msg: String) -> Bool {
        hasReply(msg, "550") || hasReply(msg, "553") || hasReply(msg, "530") || msg.lowercased().contains("denied")
    }

    // MARK: Operations

    /// Logs in and lists the start directory; learns the login directory. Used by Connect and Test connection.
    @discardableResult
    public func connect(cancel: CancelFlag? = nil) throws -> [RemoteEntry] {
        let start = profile.remoteDirectory
        let marker = "\n@@CC-ENTRY@@"
        let result = try run(listArguments(for: start, mlsd: profile.serverType != .unixList && profile.serverType != .dosList)
                                + ["-w", "\(marker)%{ftp_entry_path}"], cancel: cancel)
        let text = stripEntryPathMarker(from: String(decoding: result.output, as: UTF8.self), marker: marker)
        if result.exitCode != 0 {
            let err = Self.error(for: result, path: start)
            if shouldFallbackFromMLSD(err) { return try connect(cancel: cancel) }
            throw err
        }
        return FTPListingParser.parse(text, type: listingType)
    }

    private func stripEntryPathMarker(from raw: String, marker: String) -> String {
        guard let r = raw.range(of: marker, options: .backwards) else { return raw }
        let entry = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.hasPrefix("/") { entryPath = entry }
        return String(raw[..<r.lowerBound])
    }

    private func shouldFallbackFromMLSD(_ error: FTPError) -> Bool {
        // MLSD not understood: fall back to LIST (only for "server said no", not network/login problems).
        guard case .server = error, profile.serverType == .automatic, useMLSD else { return false }
        useMLSD = false
        return true
    }

    /// The directory to show after login: the profile's remote dir, else the server's login directory.
    public var startPath: String {
        if !profile.remoteDirectory.isEmpty { return profile.remoteDirectory }
        return entryPath ?? "/"
    }

    private var listingType: FTPServerType {
        switch profile.serverType {
        case .automatic: return useMLSD ? .mlsd : .automatic
        default: return profile.serverType
        }
    }

    private func listArguments(for path: String, mlsd: Bool) -> [String] {
        // An empty path lists the login directory (a URL without %2F is relative to it).
        return (mlsd && useMLSD ? ["-X", "MLSD"] : []) + [url(for: path, directory: true)]
    }

    /// The entries of a remote directory.
    public func list(_ path: String, cancel: CancelFlag? = nil) throws -> [RemoteEntry] {
        let mlsd = profile.serverType == .mlsd || (profile.serverType == .automatic && useMLSD)
        let result = try run(listArguments(for: path, mlsd: mlsd), cancel: cancel)
        if result.exitCode != 0 {
            return try retryOrThrowListError(result: result, path: path, cancel: cancel)
        }
        return FTPListingParser.parse(String(decoding: result.output, as: UTF8.self), type: listingType)
    }

    private func retryOrThrowListError(result: Result, path: String, cancel: CancelFlag?) throws -> [RemoteEntry] {
        let err = Self.error(for: result, path: path)
        if shouldFallbackFromMLSD(err) { return try list(path, cancel: cancel) }
        throw err
    }

    /// Downloads to `local` + ".ccpart" and renames it into place only after curl reports success
    /// and the size matches, so a broken transfer never leaves a file that looks complete.
    public func download(_ path: String, to local: URL, expectedSize: Int64?, resume: Bool = false,
                         cancel: CancelFlag? = nil, progress: ((Int64) -> Void)? = nil) throws {
        let part = local.appendingPathExtension("ccpart")
        let fm = FileManager.default
        if !resume { try? fm.removeItem(at: part) }
        try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let args = downloadArguments(for: path, part: part, resume: resume)
        let textMode = profile.transferMode.usesText(for: local.lastPathComponent)
        let result = try runDownload(args, part: part, textMode: textMode, cancel: cancel, progress: progress)
        guard result.exitCode == 0 else { throw Self.error(for: result, path: path) }
        let got = try finalizeDownload(part: part, to: local, remotePath: path, expectedSize: expectedSize, textMode: textMode)
        progress?(got)
    }

    private func downloadArguments(for path: String, part: URL, resume: Bool) -> [String] {
        var args = ["-o", part.path]
        if resume && FileManager.default.fileExists(atPath: part.path) { args += ["-C", "-"] }
        args.append(url(for: path, directory: false))
        return args
    }

    private func runDownload(
        _ args: [String], part: URL, textMode: Bool, cancel: CancelFlag?, progress: ((Int64) -> Void)?
    ) throws -> Result {
        do {
            return try run(args, textMode: textMode, cancel: cancel, poll: { progress?(Self.fileSize(part)) })
        } catch FTPError.cancelled {
            try? FileManager.default.removeItem(at: part)
            throw FTPError.cancelled
        }
    }

    private func finalizeDownload(part: URL, to local: URL, remotePath: String, expectedSize: Int64?, textMode: Bool) throws -> Int64 {
        let fm = FileManager.default
        let got = Self.fileSize(part)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: Data()) }   // empty file
        if let expected = expectedSize, !textMode, got != expected {
            throw FTPError.verificationFailed("received \(got) of \(expected) bytes")
        }
        try LocalCopy.replace(local, with: part)
        Quarantine.mark(local, origin: url(for: remotePath, directory: false))
        return got
    }

    /// Uploads a file, creating missing remote folders, then checks the size the server reports.
    public func upload(_ local: URL, to path: String, resume: Bool = false, cancel: CancelFlag? = nil,
                       progress: ((Int64) -> Void)? = nil) throws {
        let size = Self.fileSize(local)
        let textMode = profile.transferMode.usesText(for: local.lastPathComponent)
        let args = uploadArguments(local: local, path: path, resume: resume)
        let result = try run(args, textMode: textMode, cancel: cancel,
                             progress: { pct in progress?(Int64(Double(size) * pct / 100)) })
        guard result.exitCode == 0 else { throw Self.error(for: result, path: path) }
        try verifyUpload(localSize: size, path: path, textMode: textMode)
        progress?(size)
    }

    private func uploadArguments(local: URL, path: String, resume: Bool) -> [String] {
        var args = ["--ftp-create-dirs", "-T", local.path]
        if resume { args += ["-C", "-"] }
        args.append(url(for: path, directory: false))
        return args
    }

    private func verifyUpload(localSize: Int64, path: String, textMode: Bool) throws {
        if !textMode, let remote = try? self.size(of: path), remote != localSize {
            throw FTPError.verificationFailed("the server has \(remote) of \(localSize) bytes")
        }
    }

    /// The size of a remote file (SIZE command), or nil when the server does not say.
    public func size(of path: String) throws -> Int64? {
        let result = try run(["-I", url(for: path, directory: false)])
        guard result.exitCode == 0 else { throw Self.error(for: result, path: path) }
        let text = String(decoding: result.output, as: UTF8.self)
        for line in text.components(separatedBy: "\n") where line.lowercased().hasPrefix("content-length:") {
            return Int64(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Sends raw commands (MKD, DELE, RMD, RNFR/RNTO, …) after login, from the given directory.
    func quote(_ commands: [String], in directory: String = "/") throws {
        for c in commands where Self.hasControlCharacters(c) {
            throw FTPError.invalid("Invalid characters in a remote name: \(c)")
        }
        let args = commands.flatMap { ["-Q", $0] } + ["--list-only", "-o", "/dev/null", url(for: directory, directory: true)]
        let result = try run(args)
        guard result.exitCode == 0 else { throw Self.error(for: result, path: commands.last ?? "") }
    }

    public func makeDirectory(_ path: String) throws { try quote(["MKD \(path)"], in: parent(path)) }
    public func deleteFile(_ path: String) throws { try quote(["DELE \(path)"], in: parent(path)) }
    public func removeDirectory(_ path: String) throws { try quote(["RMD \(path)"], in: parent(path)) }
    public func rename(_ from: String, to: String) throws { try quote(["RNFR \(from)", "RNTO \(to)"], in: parent(from)) }

    public func chmod(_ mode: Int, of path: String) throws {
        let octal = String(mode & 0o777, radix: 8)
        try quote(["SITE CHMOD \(octal) \(path)"], in: parent(path))
    }

    func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    /// MFMT (RFC draft, supported by most servers); servers without it keep the upload time.
    public func setModificationDate(_ date: Date, of path: String) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        try quote(["MFMT \(f.string(from: date)) \(path)"], in: parent(path))
    }

    /// Nothing to close: every curl call is its own connection.
    public func close() {}

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Certificates

    /// The server's certificate summary and public-key pin ("sha256//…"), for the trust dialog.
    /// Uses LibreSSL's s_client (with STARTTLS for explicit FTPS). Reads only public data.
    public static func fetchCertificate(host: String, port: Int, explicit: Bool) -> (summary: String, pin: String)? {
        guard FTPProfile.isValidHost(host), (1...65535).contains(port) else { return nil }
        let starttls = explicit ? "-starttls ftp " : ""
        guard let pem = runShell("/usr/bin/openssl s_client \(starttls)-connect '\(host):\(port)' -servername '\(host)' </dev/null 2>/dev/null | /usr/bin/openssl x509"),
              !pem.isEmpty,
              let info = runShell("/usr/bin/openssl x509 -noout -subject -issuer -dates -fingerprint -sha256", input: pem),
              let pin = runShell("/usr/bin/openssl x509 -pubkey -noout | /usr/bin/openssl pkey -pubin -outform der | /usr/bin/openssl dgst -sha256 -binary | /usr/bin/openssl base64", input: pem)
        else { return nil }
        let pinText = String(decoding: pin, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pinText.isEmpty else { return nil }
        return (String(decoding: info, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "sha256//" + pinText)
    }

    private static func runShell(_ command: String, input: Data? = nil) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let inPipe = Pipe(), out = Pipe()
        p.standardInput = inPipe
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        if let input = input { inPipe.fileHandleForWriting.write(input) }
        try? inPipe.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}
