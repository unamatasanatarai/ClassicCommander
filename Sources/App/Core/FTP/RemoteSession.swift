import Foundation

/// A connected FTP/FTPS/SFTP server shown in a panel. Panel locations are `ccftp://<session id>/path`,
/// so the normal file list, sorting, marking and filters work unchanged; listings are fetched
/// in the background and handed to the panel through `RemoteLister`.
public final class RemoteSession {
    public static let scheme = "ccftp"
    /// Limits for walking a server folder tree (copy, delete, synchronize).
    public static let maxDepth = 128
    public static let maxEntries = 2_000_000
    static let tooLarge = FTPError.invalid("The folder tree on the server is too deep or too large (over \(maxDepth) levels or \(maxEntries) entries).")

    public let id = UUID()
    public let client: RemoteClient
    public var profile: FTPProfile { client.profile }
    private var cache: [String: [RemoteEntry]] = [:]
    private let lock = NSLock()

    public init(client: RemoteClient) {
        self.client = client
    }

    // MARK: Locations

    public var rootURL: URL { url(for: "/") }

    public func url(for path: String) -> URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = id.uuidString.lowercased()
        c.path = Self.normalize(path)
        return c.url!
    }

    /// The remote path of a panel location ("/" for the root).
    public static func path(of url: URL) -> String {
        normalize(url.path)
    }

    /// The session id in a panel location, if it is remote.
    public static func sessionID(of url: URL) -> UUID? {
        guard url.scheme == scheme, let host = url.host else { return nil }
        return UUID(uuidString: host)
    }

    /// "/a/b/" and "a//b" → "/a/b"; "" → "/".
    public static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for p in path.split(separator: "/") where p != "." && !p.isEmpty {
            if p == ".." { _ = parts.popLast() } else { parts.append(String(p)) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// e.g. "ftp://deploy@ftp.example.com" — shown in the path bar.
    public var addressLabel: String {
        let scheme = profile.isSFTP ? "sftp" : profile.security == .implicitTLS ? "ftps" : "ftp"
        return "\(scheme)://\(profile.loginName)@\(profile.hostAndPort)"
    }

    /// The drive bar text: who and how securely.
    public var statusLabel: String {
        "\(profile.isSFTP ? "SFTP" : "FTP") · CONNECTED · \(profile.name) · \(profile.securityLabel)"
    }

    // MARK: Listings

    public func cached(_ path: String) -> [RemoteEntry]? {
        lock.lock(); defer { lock.unlock() }
        return cache[Self.normalize(path)]
    }

    /// Fetches a listing from the server (or the cache when allowed) and keeps it for the panel.
    @discardableResult
    /// `store: false` (tree walks for copy/delete/sync) reads without keeping the listing, so a large
    /// tree does not stay in memory for the rest of the session.
    public func fetch(_ path: String, useCache: Bool = true, store: Bool = true, cancel: CancelFlag? = nil) throws -> [RemoteEntry] {
        let p = Self.normalize(path)
        if useCache, profile.cacheListings, let hit = cached(p) { return hit }
        let entries = try client.list(p, cancel: cancel)
        lock.lock()
        // Folders already shown stay fresh; others are only kept when asked.
        if store || cache[p] != nil { cache[p] = entries }
        lock.unlock()
        return entries
    }

    /// Stores a listing obtained elsewhere (e.g. from connecting).
    func store(_ entries: [RemoteEntry], for path: String) {
        lock.lock(); cache[Self.normalize(path)] = entries; lock.unlock()
    }

    /// Forgets cached listings for a folder (or everything), so the next visit re-reads the server.
    public func invalidate(_ path: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let p = path { cache[Self.normalize(p)] = nil } else { cache.removeAll() }
    }

    /// A remote listing as panel entries.
    public func fileEntries(for path: String, entries: [RemoteEntry]) -> [FileEntry] {
        let base = Self.normalize(path)
        return entries.map { e in
            FileEntry(name: e.name, url: url(for: base == "/" ? "/" + e.name : base + "/" + e.name),
                      kind: e.isDirectory ? .directory : .file, size: e.isDirectory ? nil : e.size,
                      modified: e.modified, isSymlink: e.isLink, permissions: e.permissions)
        }
    }

    /// Every file below a remote folder, with paths relative to it, plus its subfolders (for recursive copies).
    public func walk(_ path: String, cancel: CancelFlag? = nil) throws -> (files: [(path: String, size: Int64, modified: Date?)], folders: [String]) {
        var files: [(String, Int64, Date?)] = []
        var folders: [String] = []
        let root = Self.normalize(path)
        let rootDepth = root.split(separator: "/").count
        var queue = [root]
        var next = 0
        while next < queue.count {
            let dir = queue[next]
            next += 1
            if cancel?.isCancelled == true { throw FTPError.cancelled }
            for e in try fetch(dir, useCache: false, store: false, cancel: cancel) {
                let child = dir == "/" ? "/" + e.name : dir + "/" + e.name
                if e.isDirectory {
                    // A hostile or broken server could present endless folders: stop at sane limits.
                    guard child.split(separator: "/").count - rootDepth <= Self.maxDepth else { throw Self.tooLarge }
                    folders.append(child)
                    queue.append(child)
                } else {
                    files.append((child, e.size, e.modified))
                }
                if files.count + folders.count > Self.maxEntries { throw Self.tooLarge }
            }
        }
        return (files, folders)
    }
}

/// The panel's view of a remote folder: what the session has fetched. A folder not fetched yet is
/// reported as an error, so the panel never blocks on the network.
public struct RemoteLister: DirectoryListing {
    public let session: RemoteSession

    public struct NotLoaded: Error {}

    public func entries(in directory: URL) throws -> [FileEntry] {
        let path = RemoteSession.path(of: directory)
        guard let listing = session.cached(path) else { throw NotLoaded() }
        return session.fileEntries(for: path, entries: listing)
    }
}

extension URL {
    /// Panel locations compare equal however they were built: standardized file URLs,
    /// or remote locations with a normalized path.
    public var normalizedLocation: URL {
        if isFileURL { return standardizedFileURL }
        guard scheme == RemoteSession.scheme, var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        c.path = RemoteSession.normalize(path)
        return c.url ?? self
    }

    public var isRemoteLocation: Bool { scheme == RemoteSession.scheme }
}
