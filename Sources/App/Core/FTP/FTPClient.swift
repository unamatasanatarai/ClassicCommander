import Foundation

/// What went wrong talking to a server, in words a user can act on. Never contains the password.
public enum FTPError: Error, Equatable {
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

    public var message: String {
        switch self {
        case .authentication: return "Login failed: the server rejected the user name or password."
        case .hostNotFound: return "Server not found: check the host name (DNS lookup failed)."
        case .refused: return "Connection refused: the server is not accepting connections on that port."
        case .timeout: return "The server did not answer in time (timeout)."
        case .tlsUnavailable: return "The server does not offer TLS. The connection was not made, because an encrypted connection was requested (it is never downgraded to plain FTP)."
        case .tlsFailed(let d): return "The encrypted (TLS) connection failed: \(d)"
        case .certificateUntrusted: return "The server's certificate is not trusted."
        case .pinnedKeyChanged: return "The server's key no longer matches the one you trusted. This can mean the certificate was replaced — or an attack. The connection was not made."
        case .hostKeyUnknown: return "The server's SSH host key is not known yet, so the connection was not made."
        case .hostKeyChanged: return "The server's SSH host key does not match the one known for it. This can mean the server was reinstalled — or an attack. The connection was not made."
        case .keyFile(let d): return "The key file could not be used: \(d)"
        case .permissionDenied(let d): return "Permission denied\(d.isEmpty ? "" : ": \(d)")."
        case .notFound(let d): return "Not found on the server\(d.isEmpty ? "" : ": \(d)")."
        case .quotaExceeded: return "The server refused the file: storage quota exceeded or no space left on the server."
        case .localDiskFull: return "Could not write the local file (disk full or not writable)."
        case .connectionLost: return "The connection was lost during the transfer."
        case .passiveFailed: return "Passive mode data connection failed. Try turning Passive mode off (or check the firewall)."
        case .activeFailed: return "Active mode data connection failed. Try Passive mode."
        case .cancelled: return "Cancelled."
        case .verificationFailed(let d): return "The transfer could not be verified: \(d)"
        case .invalid(let d): return d
        case .server(let d): return "Server error: \(d)"
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
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#%")
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
        var p = segments.joined(separator: "/")
        if path.hasPrefix("/") { p = "%2F" + p }
        if directory && !p.isEmpty && !p.hasSuffix("/") { p += "/" }
        return "\(scheme)://\(host):\(profile.port)/\(p)"
    }

    /// curl options for every call. The second value is the config text fed on stdin (credentials).
    func baseArguments(textMode: Bool = false) -> (args: [String], config: String) {
        var args = ["--disable", "-K", "-", "--silent", "--show-error", "--path-as-is",
                    "--connect-timeout", "20", "--speed-limit", "1", "--speed-time", "90"]
        switch profile.security {
        case .none: break
        case .explicitTLS: args.append("--ssl-reqd")          // TLS or nothing: never downgrade
        case .implicitTLS: break                               // ftps:// URL is TLS from the start
        }
        if profile.security.isEncrypted, let pin = profile.pinnedPublicKey {
            // The user trusted this exact key: skip CA validation but insist on the pinned key.
            args += ["--insecure", "--pinnedpubkey", pin]
        }
        // Passive mode connects to the control connection's host, never to an address the server names.
        args += profile.passive ? ["--ftp-pasv", "--ftp-skip-pasv-ip"] : ["--ftp-port", "-"]
        if textMode { args.append("--use-ascii") }
        for command in profile.commandsAfterLogin where !command.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-Q", command]
        }
        var config = "user = \"\(Self.escape(profile.loginName)):\(Self.escape(profile.anonymous ? "classiccommander@" : password ?? ""))\"\n"
        if profile.proxyKind != .none {
            let scheme = profile.proxyKind == .http ? "http" : "socks5h"
            args += ["--proxy", "\(scheme)://\(profile.proxyHost)"]
            if profile.proxyKind == .http { args.append("--proxytunnel") }
            if !profile.proxyUsername.isEmpty {
                config += "proxy-user = \"\(Self.escape(profile.proxyUsername)):\"\n"
            }
        }
        return (args, config)
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

    /// Maps curl's exit status (and the server reply in its message) to an FTPError.
    static func error(for result: Result, path: String = "") -> FTPError {
        let msg = result.errorText.components(separatedBy: "\n").first { $0.hasPrefix("curl:") }?
            .replacingOccurrences(of: "curl: ", with: "") ?? result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        func reply(_ code: String) -> Bool { msg.contains(" \(code)") || msg.hasSuffix(code) }
        switch result.exitCode {
        case 6: return .hostNotFound
        case 7: return .refused
        case 28: return .timeout
        case 67: return .authentication
        case 64: return .tlsUnavailable
        case 60, 51, 58, 59, 83: return .certificateUntrusted
        case 90: return .pinnedKeyChanged
        case 35, 80: return .tlsFailed(msg)
        case 9, 78:
            return reply("550") && msg.lowercased().contains("perm") ? .permissionDenied(path) : .notFound(path)
        case 25, 21, 19:
            if reply("552") || msg.contains("quota") { return .quotaExceeded }
            if reply("550") || reply("553") || reply("530") || msg.lowercased().contains("denied") { return .permissionDenied(path) }
            if reply("450") || reply("451") { return .server(msg) }
            return .server(msg.isEmpty ? "the server refused the command" : msg)
        case 23: return .localDiskFull
        case 18, 55, 56, 52: return .connectionLost
        case 13, 14, 15: return .passiveFailed
        case 30: return .activeFailed
        default: return .server(msg.isEmpty ? "curl exit code \(result.exitCode)" : msg)
        }
    }

    // MARK: Operations

    /// Logs in and lists the start directory; learns the login directory. Used by Connect and Test connection.
    @discardableResult
    public func connect(cancel: CancelFlag? = nil) throws -> [RemoteEntry] {
        let start = profile.remoteDirectory.isEmpty ? "" : profile.remoteDirectory
        let marker = "\n@@CC-ENTRY@@"
        let result = try run(listArguments(for: start, mlsd: profile.serverType != .unixList && profile.serverType != .dosList)
                                + ["-w", "\(marker)%{ftp_entry_path}"], cancel: cancel)
        var text = String(decoding: result.output, as: UTF8.self)
        if let r = text.range(of: marker, options: .backwards) {
            let entry = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.hasPrefix("/") { entryPath = entry }
            text = String(text[..<r.lowerBound])
        }
        if result.exitCode != 0 {
            let err = Self.error(for: result, path: start)
            // MLSD not understood: fall back to LIST (only for "server said no", not network/login problems).
            if case .server = err, profile.serverType == .automatic, useMLSD {
                useMLSD = false
                return try connect(cancel: cancel)
            }
            throw err
        }
        return FTPListingParser.parse(text, type: listingType)
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
            let err = Self.error(for: result, path: path)
            if case .server = err, profile.serverType == .automatic, useMLSD {
                useMLSD = false
                return try list(path, cancel: cancel)
            }
            throw err
        }
        return FTPListingParser.parse(String(decoding: result.output, as: UTF8.self), type: listingType)
    }

    /// Downloads to `local` + ".ccpart" and renames it into place only after curl reports success
    /// and the size matches, so a broken transfer never leaves a file that looks complete.
    public func download(_ path: String, to local: URL, expectedSize: Int64?, resume: Bool = false,
                         cancel: CancelFlag? = nil, progress: ((Int64) -> Void)? = nil) throws {
        let part = local.appendingPathExtension("ccpart")
        let fm = FileManager.default
        if !resume { try? fm.removeItem(at: part) }
        try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        var args = ["-o", part.path]
        if resume && fm.fileExists(atPath: part.path) { args += ["-C", "-"] }
        args.append(url(for: path, directory: false))
        let result: Result
        do {
            result = try run(args, textMode: profile.transferMode.usesText(for: local.lastPathComponent), cancel: cancel,
                             poll: { progress?(Self.fileSize(part)) })
        } catch FTPError.cancelled {
            try? fm.removeItem(at: part)
            throw FTPError.cancelled
        }
        guard result.exitCode == 0 else { throw Self.error(for: result, path: path) }
        let got = Self.fileSize(part)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: Data()) }   // empty file
        if let expected = expectedSize, !profile.transferMode.usesText(for: local.lastPathComponent), got != expected {
            throw FTPError.verificationFailed("received \(got) of \(expected) bytes")
        }
        if fm.fileExists(atPath: local.path) { try fm.removeItem(at: local) }
        try fm.moveItem(at: part, to: local)
        Quarantine.mark(local, origin: url(for: path, directory: false))
        progress?(got)
    }

    /// Uploads a file, creating missing remote folders, then checks the size the server reports.
    public func upload(_ local: URL, to path: String, resume: Bool = false, cancel: CancelFlag? = nil,
                       progress: ((Int64) -> Void)? = nil) throws {
        let size = Self.fileSize(local)
        var args = ["--ftp-create-dirs", "-T", local.path]
        if resume { args += ["-C", "-"] }
        args.append(url(for: path, directory: false))
        let result = try run(args, textMode: profile.transferMode.usesText(for: local.lastPathComponent), cancel: cancel,
                             progress: { pct in progress?(Int64(Double(size) * pct / 100)) })
        guard result.exitCode == 0 else { throw Self.error(for: result, path: path) }
        if !profile.transferMode.usesText(for: local.lastPathComponent), let remote = try? self.size(of: path), remote != size {
            throw FTPError.verificationFailed("the server has \(remote) of \(size) bytes")
        }
        progress?(size)
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
        for c in commands where c.contains("\r") || c.contains("\n") || c.contains("\0") {
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
        func shell(_ command: String, input: Data? = nil) -> Data? {
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
        guard FTPProfile.isValidHost(host), (1...65535).contains(port) else { return nil }
        let starttls = explicit ? "-starttls ftp " : ""
        guard let pem = shell("/usr/bin/openssl s_client \(starttls)-connect '\(host):\(port)' -servername '\(host)' </dev/null 2>/dev/null | /usr/bin/openssl x509"),
              !pem.isEmpty,
              let info = shell("/usr/bin/openssl x509 -noout -subject -issuer -dates -fingerprint -sha256", input: pem),
              let pin = shell("/usr/bin/openssl x509 -pubkey -noout | /usr/bin/openssl pkey -pubin -outform der | /usr/bin/openssl dgst -sha256 -binary | /usr/bin/openssl base64", input: pem)
        else { return nil }
        let pinText = String(decoding: pin, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pinText.isEmpty else { return nil }
        return (String(decoding: info, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "sha256//" + pinText)
    }
}
