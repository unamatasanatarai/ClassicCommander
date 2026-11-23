import Foundation
import Security

// FTP connection profiles, their folders, and where passwords live (the macOS Keychain).
// Profiles are stored without passwords; exported settings never contain them.

/// How the connection is secured. SFTP is a different protocol (SSH) and is deliberately not listed.
public enum FTPSecurity: String, Codable, CaseIterable {
    /// Plain FTP: user name, password and data travel unencrypted.
    case none
    /// FTP upgraded to TLS with AUTH TLS (usually port 21). Never falls back to plain FTP.
    case explicitTLS
    /// TLS from the first byte (usually port 990).
    case implicitTLS

    public var label: String {
        switch self {
        case .none: return "FTP — unencrypted"
        case .explicitTLS: return "FTPS — explicit TLS (AUTH TLS)"
        case .implicitTLS: return "FTPS — implicit TLS"
        }
    }

    public var shortLabel: String {
        switch self {
        case .none: return "FTP (unencrypted)"
        case .explicitTLS: return "FTPS explicit"
        case .implicitTLS: return "FTPS implicit"
        }
    }

    public var defaultPort: Int { self == .implicitTLS ? 990 : 21 }
    public var isEncrypted: Bool { self != .none }
}

/// How directory listings are read. Automatic tries MLSD (machine-readable) and falls back to LIST.
public enum FTPServerType: String, Codable, CaseIterable {
    case automatic, mlsd, unixList, dosList

    public var label: String {
        switch self {
        case .automatic: return "Automatic detection (recommended)"
        case .mlsd: return "MLSD (RFC 3659)"
        case .unixList: return "Unix LIST format"
        case .dosList: return "Windows/IIS LIST format"
        }
    }
}

public enum FTPTransferMode: String, Codable, CaseIterable {
    /// Every byte as is — safe for any file. The default.
    case binary
    /// Line endings converted by the server — only for plain text files.
    case text
    /// Text mode for common text extensions, binary for everything else.
    case automatic

    public var label: String {
        switch self {
        case .binary: return "Binary (all files, safe default)"
        case .text: return "Text (ASCII line-ending conversion)"
        case .automatic: return "Automatic (text for .txt, .html, … binary otherwise)"
        }
    }

    static let textExtensions: Set<String> = ["txt", "htm", "html", "css", "csv", "xml", "ini", "cfg", "conf", "log", "md", "php", "js", "json", "sh", "pl", "py"]

    func usesText(for filename: String) -> Bool {
        switch self {
        case .binary: return false
        case .text: return true
        case .automatic: return Self.textExtensions.contains((filename as NSString).pathExtension.lowercased())
        }
    }
}

public enum FTPProxyKind: String, Codable, CaseIterable {
    case none, http, socks5
    public var label: String {
        switch self {
        case .none: return "No proxy"
        case .http: return "HTTP CONNECT proxy"
        case .socks5: return "SOCKS5 proxy"
        }
    }
}

/// The protocol of a connection. SFTP is a different protocol (file transfer over SSH), not an FTP security mode.
public enum RemoteProtocol: String, Codable, CaseIterable {
    case ftp, sftp

    public var label: String {
        switch self {
        case .ftp: return "FTP / FTPS"
        case .sftp: return "SFTP (SSH file transfer)"
        }
    }
}

/// How an SFTP connection logs in.
public enum SSHAuthMethod: String, Codable, CaseIterable {
    case keyFile, password

    public var label: String {
        switch self {
        case .keyFile: return "Key file (private key, optional passphrase)"
        case .password: return "Password"
        }
    }
}

public struct FTPProfile: Codable, Equatable {
    public var id = UUID()
    public var name = ""
    /// Folder (group) in the connection manager; nil = top level.
    public var folder: String?
    public var host = ""
    public var port = 21
    public var username = ""
    public var anonymous = false
    public var remoteDirectory = ""
    public var localDirectory = ""
    public var security: FTPSecurity = .explicitTLS
    public var passive = true
    /// Keep the password in the Keychain; otherwise it is asked for on each connect.
    public var savePassword = true
    public var serverType: FTPServerType = .automatic
    public var transferMode: FTPTransferMode = .binary
    /// Sent to the server after each login (e.g. SITE UMASK 022). Shown with a security warning.
    public var commandsAfterLogin: [String] = []
    public var cacheListings = true
    public var proxyKind: FTPProxyKind = .none
    public var proxyHost = ""
    public var proxyUsername = ""
    /// A server key the user chose to trust after a failed certificate check ("sha256//base64").
    public var pinnedPublicKey: String?
    /// FTP (with its security mode) or SFTP.
    public var connectionProtocol: RemoteProtocol = .ftp
    /// SFTP: log in with a private key file or a password.
    public var sshAuth: SSHAuthMethod = .keyFile
    /// SFTP: the private key ("~/.ssh/id_ed25519"). Its passphrase, if any, is kept like a password.
    public var keyFile = ""
    /// SFTP: server host keys the user trusted ("ssh-ed25519 AAAA…"), besides ~/.ssh/known_hosts.
    public var trustedHostKeys: [String] = []

    public init() {}

    // Profiles saved by older versions lack newer fields: every field falls back to its default.
    private enum CodingKeys: String, CodingKey {
        case id, name, folder, host, port, username, anonymous, remoteDirectory, localDirectory, security, passive,
             savePassword, serverType, transferMode, commandsAfterLogin, cacheListings, proxyKind, proxyHost,
             proxyUsername, pinnedPublicKey, connectionProtocol, sshAuth, keyFile, trustedHostKeys
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        id = get(.id, UUID())
        name = get(.name, "")
        folder = get(.folder, nil as String?)
        host = get(.host, "")
        port = get(.port, 21)
        username = get(.username, "")
        anonymous = get(.anonymous, false)
        remoteDirectory = get(.remoteDirectory, "")
        localDirectory = get(.localDirectory, "")
        security = get(.security, FTPSecurity.explicitTLS)
        passive = get(.passive, true)
        savePassword = get(.savePassword, true)
        serverType = get(.serverType, FTPServerType.automatic)
        transferMode = get(.transferMode, FTPTransferMode.binary)
        commandsAfterLogin = get(.commandsAfterLogin, [String]())
        cacheListings = get(.cacheListings, true)
        proxyKind = get(.proxyKind, FTPProxyKind.none)
        proxyHost = get(.proxyHost, "")
        proxyUsername = get(.proxyUsername, "")
        pinnedPublicKey = get(.pinnedPublicKey, nil as String?)
        connectionProtocol = get(.connectionProtocol, RemoteProtocol.ftp)
        sshAuth = get(.sshAuth, SSHAuthMethod.keyFile)
        keyFile = get(.keyFile, "")
        trustedHostKeys = get(.trustedHostKeys, [String]())
    }

    public var isSFTP: Bool { connectionProtocol == .sftp }

    /// 22 for SFTP, 21 or 990 for FTP.
    public var defaultPort: Int { isSFTP ? 22 : security.defaultPort }

    /// Whether names, passwords and files travel encrypted.
    public var isEncrypted: Bool { isSFTP || security.isEncrypted }

    /// "SFTP (SSH key)", "FTPS explicit", "FTP (unencrypted)", …
    public var securityLabel: String {
        guard isSFTP else { return security.shortLabel }
        return sshAuth == .keyFile ? "SFTP (SSH key)" : "SFTP (SSH password)"
    }

    /// SFTP logging in with a key file.
    public var usesKeyFile: Bool { isSFTP && sshAuth == .keyFile }

    /// The key file with "~" expanded.
    public var keyFilePath: String { (keyFile as NSString).expandingTildeInPath }

    /// The first usual private key in ~/.ssh, as "~/.ssh/…" (a starting point for new SFTP profiles).
    public static func defaultKeyFile(home: String = NSHomeDirectory()) -> String {
        for name in ["id_ed25519", "id_ecdsa", "id_rsa"] where FileManager.default.fileExists(atPath: home + "/.ssh/" + name) {
            return "~/.ssh/" + name
        }
        return ""
    }

    /// "host" or "host:port" as typed in "Host name[:Port]".
    public var hostAndPort: String {
        port == defaultPort ? host : "\(host):\(port)"
    }

    /// Fills host and port from "host[:port]" (IPv6 as "[::1]:21"). Returns false when it is not valid.
    @discardableResult
    public mutating func setHostAndPort(_ text: String) -> Bool {
        guard let (h, p) = Self.parseHostPort(text, defaultPort: defaultPort) else { return false }
        host = h
        port = p
        return true
    }

    static func parseHostPort(_ text: String, defaultPort: Int) -> (String, Int)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var host = t, port = defaultPort
        if t.hasPrefix("[") {                                   // [IPv6]:port
            guard let close = t.firstIndex(of: "]") else { return nil }
            host = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            if rest.hasPrefix(":") { guard let p = Int(rest.dropFirst()) else { return nil }; port = p }
            else if !rest.isEmpty { return nil }
        } else if t.filter({ $0 == ":" }).count == 1, let colon = t.lastIndex(of: ":") {
            host = String(t[..<colon])
            guard let p = Int(t[t.index(after: colon)...]) else { return nil }
            port = p
        }
        guard (1...65535).contains(port), isValidHost(host) else { return nil }
        return (host, port)
    }

    /// Host names, IPv4 and IPv6 addresses; no spaces, slashes or other URL characters.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:_"))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) } && !host.hasPrefix("-")
    }

    /// Problems that stop the profile from being saved or used, in the order shown to the user.
    public var problems: [String] {
        var list: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { list.append("Enter a session name.") }
        if !Self.isValidHost(host) { list.append("Enter a valid host name or IP address.") }
        if !(1...65535).contains(port) { list.append("The port must be between 1 and 65535.") }
        if isSFTP {
            if username.isEmpty { list.append("Enter a user name.") }
            if !Self.isValidSSHUser(username) { list.append("The user name must not contain spaces or control characters, or start with -.") }
            if sshAuth == .keyFile {
                if keyFile.trimmingCharacters(in: .whitespaces).isEmpty { list.append("Choose a private key file.") }
                else if !FileManager.default.isReadableFile(atPath: keyFilePath) { list.append("The key file \(keyFile) cannot be read.") }
            }
        } else if !anonymous && username.isEmpty { list.append("Enter a user name, or tick Anonymous login.") }
        if !remoteDirectory.isEmpty && !remoteDirectory.hasPrefix("/") { list.append("The remote directory must start with /.") }
        if remoteDirectory.contains("\0") || remoteDirectory.contains("\n") { list.append("The remote directory contains invalid characters.") }
        if FTPClient.hasControlCharacters(username) || FTPClient.hasControlCharacters(proxyUsername) {
            list.append("User names must not contain line breaks or other control characters.")
        }
        if proxyKind != .none && FTPProfile.parseHostPort(proxyHost, defaultPort: proxyKind == .http ? 8080 : 1080) == nil {
            list.append("Enter the proxy as host:port.")
        }
        return list
    }

    /// SSH user names go to ssh as an option value: no whitespace, control characters or leading "-".
    static func isValidSSHUser(_ user: String) -> Bool {
        user.isEmpty || (!user.hasPrefix("-") && !user.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7F })
    }

    /// The name used to log in (anonymous logins use "anonymous"; SFTP has no anonymous login).
    public var loginName: String { anonymous && !isSFTP ? "anonymous" : username }

    /// Builds a profile from "ftp://user:pass@host:port/path", "ftps://…" (implicit TLS) or "sftp://user@host/path".
    /// The password (if any) is returned separately so it never ends up in the profile.
    public static func fromURL(_ text: String) -> (FTPProfile, password: String?)? {
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = comps.scheme?.lowercased(), ["ftp", "ftps", "sftp"].contains(scheme),
              let host = comps.host, isValidHost(host) else { return nil }
        // Line breaks hidden in a link (%0A) would reach the login commands: such links are refused.
        for part in [comps.user, comps.password, comps.path] where FTPClient.hasControlCharacters(part ?? "") { return nil }
        var p = FTPProfile()
        p.security = scheme == "ftps" ? .implicitTLS : .explicitTLS
        p.connectionProtocol = scheme == "sftp" ? .sftp : .ftp
        p.host = host
        p.port = comps.port ?? p.defaultPort
        p.username = comps.user ?? ""
        if p.isSFTP {
            p.sshAuth = comps.password == nil ? .keyFile : .password
            if p.sshAuth == .keyFile { p.keyFile = defaultKeyFile() }
        } else {
            p.anonymous = p.username.isEmpty || p.username.lowercased() == "anonymous"
        }
        if p.anonymous { p.username = "" }
        p.remoteDirectory = comps.path.isEmpty ? "" : comps.path
        p.name = host
        return (p, comps.password)
    }

    /// One line describing the profile in the connection manager.
    public var summary: String {
        var parts = [securityLabel]
        parts.append("\(loginName)@\(hostAndPort)")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Credential store

/// Where passwords are kept. The app uses the Keychain; tests use memory.
public protocol FTPCredentialStore: AnyObject {
    func password(for id: UUID) -> String?
    func setPassword(_ password: String?, for id: UUID)
}

/// Passwords in the macOS Keychain (generic passwords, service "ClassicCommander FTP").
public final class KeychainCredentialStore: FTPCredentialStore {
    private let service: String

    public init(service: String = "ClassicCommander FTP") {
        self.service = service
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    public func password(for id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
        guard let password = password, !password.isEmpty else { return }
        var q = query(id)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "ClassicCommander FTP password"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(q as CFDictionary, nil)
    }
}

public final class MemoryCredentialStore: FTPCredentialStore {
    private var passwords: [UUID: String] = [:]
    public init() {}
    public func password(for id: UUID) -> String? { passwords[id] }
    public func setPassword(_ password: String?, for id: UUID) { passwords[id] = password }
}

// MARK: - Profile repository

/// Saved profiles and folders (UserDefaults, JSON, no passwords).
public final class FTPProfileRepository {
    public private(set) var profiles: [FTPProfile] = []
    public private(set) var folders: [String] = []
    private let defaults: UserDefaults
    public let credentials: FTPCredentialStore

    private enum Key {
        static let profiles = "ftp.profiles"
        static let folders = "ftp.folders"
    }

    public init(defaults: UserDefaults = .standard, credentials: FTPCredentialStore = KeychainCredentialStore()) {
        self.defaults = defaults
        self.credentials = credentials
        if let data = defaults.data(forKey: Key.profiles),
           let saved = try? JSONDecoder().decode([FTPProfile].self, from: data) {
            profiles = saved
        }
        folders = defaults.stringArray(forKey: Key.folders) ?? []
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Key.profiles) }
        defaults.set(folders, forKey: Key.folders)
    }

    public func profile(_ id: UUID) -> FTPProfile? { profiles.first { $0.id == id } }

    /// Adds or replaces a profile; the password goes to the credential store (or is removed).
    public func save(_ profile: FTPProfile, password: String?) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        if let folder = profile.folder, !folders.contains(folder) { folders.append(folder) }
        credentials.setPassword(profile.savePassword && !profile.anonymous ? password : nil, for: profile.id)
        persist()
    }

    /// A copy with a new id and "(copy)" name; the saved password is copied too.
    @discardableResult
    public func duplicate(_ id: UUID) -> FTPProfile? {
        guard var copy = profile(id) else { return nil }
        let password = credentials.password(for: id)
        copy.id = UUID()
        copy.name += " (copy)"
        save(copy, password: password)
        return copy
    }

    /// Removes the profile and its saved password. Remote files are never touched.
    public func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        credentials.setPassword(nil, for: id)
        persist()
    }

    public func addFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !folders.contains(trimmed) else { return }
        folders.append(trimmed)
        persist()
    }

    /// Deletes a folder; its profiles move to the top level (their settings are unchanged).
    public func deleteFolder(_ name: String) {
        folders.removeAll { $0 == name }
        for i in profiles.indices where profiles[i].folder == name { profiles[i].folder = nil }
        persist()
    }

    public func profiles(in folder: String?) -> [FTPProfile] {
        profiles.filter { $0.folder == folder }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
