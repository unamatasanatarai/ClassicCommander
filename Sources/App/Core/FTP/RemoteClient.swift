import Foundation

/// What panels, transfers and file commands need from a server connection. FTP/FTPS (`FTPClient`)
/// and SFTP (`SFTPClient`) both provide it, so everything above works the same for both.
public protocol RemoteClient: AnyObject {
    var profile: FTPProfile { get }
    /// The folder to show after login.
    var startPath: String { get }
    /// Logs in and lists the start folder (Connect and Test connection).
    @discardableResult
    func connect(cancel: CancelFlag?) throws -> [RemoteEntry]
    func list(_ path: String, cancel: CancelFlag?) throws -> [RemoteEntry]
    /// Downloads into a ".ccpart" file and moves it into place only after it was verified.
    func download(_ path: String, to local: URL, expectedSize: Int64?, resume: Bool,
                  cancel: CancelFlag?, progress: ((Int64) -> Void)?) throws
    /// Uploads (creating missing folders) and checks the size the server then reports.
    func upload(_ local: URL, to path: String, resume: Bool, cancel: CancelFlag?,
                progress: ((Int64) -> Void)?) throws
    func makeDirectory(_ path: String) throws
    func deleteFile(_ path: String) throws
    func removeDirectory(_ path: String) throws
    func rename(_ from: String, to: String) throws
    /// Sets a file's modification date on the server (where supported; Synchronize keeps dates).
    func setModificationDate(_ date: Date, of path: String) throws
    /// Ends any connection kept open for the session.
    func close()
}

/// How often a running curl/sftp is checked for Cancel and asked for progress.
public enum RemoteTiming {
    public static var pollInterval: TimeInterval = 0.25
}

public enum RemoteClients {
    /// The client for a profile's protocol. `secret` is the password, or the key passphrase for SFTP key logins.
    public static func make(_ profile: FTPProfile, secret: String?) -> RemoteClient {
        profile.isSFTP ? SFTPClient(profile: profile, secret: secret) : FTPClient(profile: profile, password: secret)
    }
}
