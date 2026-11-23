import AppKit

/// Connects panels to FTP servers and makes the normal commands work on them:
/// navigation (listings load in the background), 3 view, Enter open, 5 copy / 6 move (queued in the
/// Transfers window), 7 new folder, 8 delete (permanent, confirmed), refresh, and disconnect.
public final class FTPController {
    weak var commander: CommanderView?
    public var repository: FTPProfileRepository
    public let transfers = TransferManager()
    public private(set) var sessions: [UUID: RemoteSession] = [:]
    /// Where each panel was before it connected, to return there on disconnect.
    private var localBefore: [CommanderModel.Side: URL] = [:]
    /// Tests run network work synchronously.
    public var runSynchronously = false {
        didSet { transfers.runSynchronously = runSynchronously }
    }
    /// Shows a message (errors, results). Replaceable in tests.
    public var showMessage: (String, String) -> Void = { title, text in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
    /// Asks whether to trust an unverified certificate (summary). Replaceable in tests.
    public var askTrust: (String) -> Bool = { summary in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The server's certificate could not be verified"
        alert.informativeText = summary + "\n\nOnly trust it if you know this is the right server. ClassicCommander will remember exactly this key and refuse a different one later."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Trust This Certificate")
        return alert.runModal() == .alertSecondButtonReturn
    }
    /// Asks whether to trust an SSH server's host key (fingerprints). Replaceable in tests.
    public var askHostKeyTrust: (String) -> Bool = { text in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This server's SSH host key is not known yet"
        alert.informativeText = text + "\n\nOnly trust it if the fingerprint is right. ClassicCommander will remember these keys and refuse different ones later."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Trust This Host Key")
        return alert.runModal() == .alertSecondButtonReturn
    }
    public private(set) lazy var managerWindow = FTPConnectionManagerController(ftp: self)
    public private(set) lazy var transfersWindow = TransfersWindowController(manager: transfers)

    init(commander: CommanderView, repository: FTPProfileRepository = FTPProfileRepository()) {
        self.commander = commander
        self.repository = repository
        Self.removeOldTemporaryCopies()
        transfers.onChange = { [weak self] job in
            self?.transfersWindow.refresh()
            if job.state == .finished || job.state == .cancelled { self?.commander?.reloadPanels() }
        }
    }

    public func session(for panel: PanelView) -> RemoteSession? {
        RemoteSession.sessionID(of: panel.model.directory).flatMap { sessions[$0] }
    }

    private func side(of panel: PanelView) -> CommanderModel.Side {
        commander?.leftView === panel ? .left : .right
    }

    private func background<T>(_ work: @escaping () throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        if runSynchronously { done(Result { try work() }); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try work() }
            DispatchQueue.main.async { done(r) }
        }
    }

    // MARK: Connecting

    /// Logs in and shows the start directory in the panel on `side`. The local start directory,
    /// if set, opens in the other panel. Untrusted certificates go through the trust dialog.
    public func connect(_ profile: FTPProfile, password: String?, side: CommanderModel.Side,
                        completion: ((Result<Void, FTPError>) -> Void)? = nil) {
        guard let commander = commander else { return }
        let panel = commander.view(for: side)
        let client = RemoteClients.make(profile, secret: password)
        panel.busyText = "Connecting to \(profile.hostAndPort)…"
        background({ try client.connect(cancel: nil) }) { [weak self] result in
            guard let self = self else { return }
            panel.busyText = nil
            switch result {
            case .success(let listing):
                let session = RemoteSession(client: client)
                session.store(listing, for: client.startPath)
                if !panel.model.isRemote { self.localBefore[side] = panel.model.directory }
                else if let old = self.session(for: panel) { self.sessions[old.id] = nil; old.client.close() }
                self.sessions[session.id] = session
                panel.model.switchSource(RemoteLister(session: session), to: session.url(for: client.startPath), visibleRows: panel.visibleRows)
                panel.remote = (session.statusLabel, session.addressLabel, !profile.isEncrypted)
                if !profile.localDirectory.isEmpty {
                    let other = commander.view(for: side.other)
                    let url = URL(fileURLWithPath: (profile.localDirectory as NSString).expandingTildeInPath)
                    if !other.model.isRemote { other.model.go(to: url, visibleRows: other.visibleRows); other.needsDisplay = true }
                }
                commander.activate(side)
                commander.updateFunctionBar()
                panel.needsDisplay = true
                completion?(.success(()))
            case .failure(let error):
                let ftpError = error as? FTPError ?? .server(error.localizedDescription)
                if ftpError == .certificateUntrusted, profile.pinnedPublicKey == nil {
                    self.offerTrust(profile, password: password, side: side, completion: completion)
                    return
                }
                if ftpError == .hostKeyUnknown {
                    self.offerHostKeyTrust(profile, password: password, side: side, completion: completion)
                    return
                }
                completion?(.failure(ftpError))
            }
        }
    }

    /// Shows the certificate and, if the user trusts it, pins its key in the profile and retries.
    private func offerTrust(_ profile: FTPProfile, password: String?, side: CommanderModel.Side,
                           completion: ((Result<Void, FTPError>) -> Void)?) {
        background({ FTPClient.fetchCertificate(host: profile.host, port: profile.port, explicit: profile.security == .explicitTLS) }) { [weak self] result in
            guard let self = self else { return }
            guard case .success(let cert?) = result else {
                completion?(.failure(.certificateUntrusted))
                return
            }
            guard self.askTrust("Server: \(profile.hostAndPort)\n\n\(cert.summary)\n\nKey: \(cert.pin)") else {
                completion?(.failure(.certificateUntrusted))
                return
            }
            var pinned = profile
            pinned.pinnedPublicKey = cert.pin
            if self.repository.profile(profile.id) != nil {
                self.repository.save(pinned, password: password ?? self.repository.credentials.password(for: profile.id))
            }
            self.connect(pinned, password: password, side: side, completion: completion)
        }
    }

    /// SFTP: shows the server's host key fingerprints; if the user trusts them, they are kept in the
    /// profile and the connection is retried. Keys that changed are never offered (that is an error).
    private func offerHostKeyTrust(_ profile: FTPProfile, password: String?, side: CommanderModel.Side,
                                   completion: ((Result<Void, FTPError>) -> Void)?) {
        background({ SFTPClient.fetchHostKeys(host: profile.host, port: profile.port) }) { [weak self] result in
            guard let self = self else { return }
            guard case .success(let found?) = result else {
                completion?(.failure(.hostKeyUnknown))
                return
            }
            let text = "Server: \(profile.hostAndPort)\n\nHost key fingerprints:\n\(found.summary)\n\n"
                + "Compare them with the fingerprints your server administrator gave you (ssh-keygen -lf on the server)."
            guard self.askHostKeyTrust(text) else {
                completion?(.failure(.hostKeyUnknown))
                return
            }
            var trusted = profile
            trusted.trustedHostKeys = found.keys
            if self.repository.profile(profile.id) != nil {
                self.repository.save(trusted, password: password ?? self.repository.credentials.password(for: profile.id))
            }
            self.connect(trusted, password: password, side: side, completion: completion)
        }
    }

    /// Ends the session in a panel and shows the local folder it came from.
    public func disconnect(_ side: CommanderModel.Side) {
        guard let commander = commander else { return }
        let panel = commander.view(for: side)
        guard let session = session(for: panel) else { return NSSound.beep() }
        sessions[session.id] = nil
        session.client.close()
        let back = localBefore[side] ?? FileManager.default.homeDirectoryForCurrentUser
        panel.model.switchSource(commander.localLister, to: back, visibleRows: panel.visibleRows)
        panel.remote = nil
        panel.needsDisplay = true
        commander.updateFunctionBar()
    }

    /// Swap panels: remote sessions (and where each panel was before connecting) change sides too.
    func panelsSwapped() {
        let left = localBefore[.left]
        localBefore[.left] = localBefore[.right]
        localBefore[.right] = left
    }

    public func disconnectActive() {
        guard let commander = commander else { return }
        disconnect(commander.model.activeSide)
    }

    // MARK: Navigation

    /// Handles navigation in a remote panel (the listing is fetched first). Returns false for local panels.
    func navigate(_ panel: PanelView, _ action: CommandAction) -> Bool {
        guard let session = session(for: panel) else { return false }
        let model = panel.model
        let rows = panel.visibleRows
        let current = RemoteSession.path(of: model.directory)
        switch action {
        case .open, .enterFolder:
            guard let entry = model.currentEntry else { return true }
            switch entry.kind {
            case .parent:
                return navigate(panel, .parentFolder)
            case .directory:
                load(session, RemoteSession.path(of: entry.url), in: panel) { model.openCurrent(visibleRows: rows) }
            case .file where entry.isSymlink:
                // A link: a link to a folder is entered, a link to a file is opened like a file.
                let path = RemoteSession.path(of: entry.url)
                panel.busyText = "Reading \(path)…"
                background({ try session.fetch(path) }) { [weak self] result in
                    panel.busyText = nil
                    switch result {
                    case .success:
                        model.go(to: session.url(for: path), visibleRows: rows)
                        panel.needsDisplay = true
                    case .failure:
                        if action == .open { self?.openRemoteFile(entry, session: session) } else { NSSound.beep() }
                    }
                }
            case .file:
                if action == .open { openRemoteFile(entry, session: session) }
            }
        case .parentFolder:
            guard current != "/" else { return true }
            load(session, (current as NSString).deletingLastPathComponent, in: panel) { model.goUp(visibleRows: rows) }
        case .goRoot:
            load(session, "/", in: panel) { model.go(to: session.rootURL, visibleRows: rows) }
        case .goHome:
            // "~" is the Mac's home folder: leave the server.
            disconnect(side(of: panel))
            model.goHome(visibleRows: rows)
        default:
            return false
        }
        return true
    }

    /// Fetches a listing in the background, then runs `then` (which shows it).
    private func load(_ session: RemoteSession, _ path: String, in panel: PanelView, useCache: Bool = true,
                      then: @escaping () -> Void) {
        panel.busyText = "Reading \(path)…"
        background({ try session.fetch(path, useCache: useCache) }) { [weak self] result in
            panel.busyText = nil
            switch result {
            case .success:
                then()
                panel.needsDisplay = true
            case .failure(let error):
                self?.report(error, title: "Cannot open \(path)")
            }
        }
    }

    /// Shows a server file in a panel connected to the same session (reading its folder first).
    func reveal(_ url: URL, in panel: PanelView) -> Bool {
        guard let session = session(for: panel), RemoteSession.sessionID(of: url) == session.id else { return false }
        let path = RemoteSession.path(of: url)
        let folder = (path as NSString).deletingLastPathComponent
        load(session, folder.isEmpty ? "/" : folder, in: panel) {
            panel.model.go(to: session.url(for: folder.isEmpty ? "/" : folder), visibleRows: panel.visibleRows)
            panel.model.focus(name: (path as NSString).lastPathComponent, visibleRows: panel.visibleRows)
        }
        return true
    }

    /// Finds the session of a `ccftp://` location, from a snapshot safe to use off the main thread.
    var sessionLookup: SyncSessionLookup {
        let snapshot = sessions
        return { url in RemoteSession.sessionID(of: url).flatMap { snapshot[$0] } }
    }

    /// "sftp://user@host/path" for a panel location (what Synchronize shows), and back.
    func displayAddress(of url: URL) -> String? {
        guard let id = RemoteSession.sessionID(of: url), let s = sessions[id] else { return nil }
        let path = RemoteSession.path(of: url)
        return s.addressLabel + (path == "/" ? "/" : path)
    }

    func location(fromAddress text: String) -> URL? {
        for s in sessions.values where text.hasPrefix(s.addressLabel) {
            let rest = String(text.dropFirst(s.addressLabel.count))
            if rest.isEmpty || rest.hasPrefix("/") { return s.url(for: rest.isEmpty ? "/" : rest) }
        }
        return nil
    }

    /// Re-reads the remote folder (Refresh, and after transfers).
    func refresh(_ panel: PanelView) {
        guard let session = session(for: panel) else { return }
        let path = RemoteSession.path(of: panel.model.directory)
        session.invalidate(path)
        load(session, path, in: panel, useCache: false) { panel.model.reload(visibleRows: panel.visibleRows) }
    }

    private func report(_ error: Error, title: String) {
        showMessage(title, (error as? FTPError)?.message ?? error.localizedDescription)
    }

    // MARK: View / open

    /// Downloads a remote file to a private temporary folder (for viewing or opening).
    /// Where View (3) / Enter put copies of server files (one folder per file, so names never clash).
    static let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ClassicCommander-Remote")
    private static var cleanedTemporaryCopies = false

    /// Copies left by earlier sessions are removed once per launch (current ones may still be open in other apps).
    static func removeOldTemporaryCopies() {
        guard !cleanedTemporaryCopies else { return }
        cleanedTemporaryCopies = true
        let fm = FileManager.default
        try? fm.removeItem(at: temporaryRoot)
        // Older versions used one folder per copy directly in the temporary folder.
        for name in (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? [] where name.hasPrefix("ClassicCommander-FTP-") {
            try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent(name))
        }
    }

    private func downloadTemporary(_ entry: FileEntry, session: RemoteSession, then: @escaping (URL) -> Void) {
        let folder = Self.temporaryRoot.appendingPathComponent(UUID().uuidString)
        let local = folder.appendingPathComponent(entry.name)
        commander?.showHint("Downloading \(entry.name)…", duration: 30)
        background({
            try session.client.download(RemoteSession.path(of: entry.url), to: local, expectedSize: entry.size,
                                       resume: false, cancel: nil, progress: nil)
        }) { [weak self] result in
            self?.commander?.showHint("", duration: 0.01)
            switch result {
            case .success: then(local)
            case .failure(let e): self?.report(e, title: "Cannot download \(entry.name)")
            }
        }
    }

    /// "3" on a remote file: download a temporary copy and show it in Lister.
    func view(_ panel: PanelView) -> Bool {
        guard let session = session(for: panel) else { return false }
        guard let entry = panel.model.currentEntry, entry.kind == .file else { NSSound.beep(); return true }
        downloadTemporary(entry, session: session) { [weak self] url in self?.commander?.openLister(files: [url], index: 0) }
        return true
    }

    /// Lister on a server file found elsewhere (Find Files): downloaded to a temporary copy first.
    func viewRemote(_ url: URL, size: Int64?) {
        guard let id = RemoteSession.sessionID(of: url), let session = sessions[id] else {
            showMessage("View", "The server connection is closed.")
            return
        }
        let entry = FileEntry(name: url.lastPathComponent, url: url, kind: .file, size: size, modified: nil)
        downloadTemporary(entry, session: session) { [weak self] local in self?.commander?.openLister(files: [local], index: 0) }
    }

    private func openRemoteFile(_ entry: FileEntry, session: RemoteSession) {
        downloadTemporary(entry, session: session) { url in NSWorkspace.shared.open(url) }
    }

    // MARK: File commands

    private func location(for entry: FileEntry, in panel: PanelView) -> TransferLocation {
        if let s = session(for: panel) { return .remote(s, RemoteSession.path(of: entry.url)) }
        return .local(entry.url)
    }

    private func folderLocation(_ panel: PanelView) -> TransferLocation {
        if let s = session(for: panel) { return .remote(s, RemoteSession.path(of: panel.model.directory)) }
        return .local(panel.model.directory)
    }

    /// 5 / 6 when either panel is remote. Returns false when both panels are local.
    func transfer(move: Bool, prompts: FileCommandPrompts) -> Bool {
        guard let commander = commander else { return false }
        let source = commander.activeView
        let target = commander.view(for: commander.model.activeSide.other)
        guard source.model.isRemote || target.model.isRemote else { return false }
        let items = source.model.operationTargets
        guard !items.isEmpty else { NSSound.beep(); return true }

        let destination = folderLocation(target)
        let verb = move ? "Move" : "Copy"
        let what = FileCommands.describe(items)
        let defaultText = destination.displayPath.hasSuffix("/") ? destination.displayPath : destination.displayPath + "/"
        guard let typed = prompts.askText(title: verb, message: "\(verb) \(what) to:", defaultValue: defaultText, okTitle: verb) else { return true }

        // Typing just a new name for one item of a remote folder renames it on the server.
        if move, let session = session(for: source), items.count == 1, !typed.contains("/"), !typed.isEmpty {
            let from = RemoteSession.path(of: items[0].url)
            let to = RemoteSession.normalize((from as NSString).deletingLastPathComponent + "/" + typed)
            background({ try session.client.rename(from, to: to) }) { [weak self] result in
                if case .failure(let e) = result { self?.report(e, title: "Rename failed") }
                self?.refresh(source)
            }
            return true
        }
        guard typed == defaultText || typed == destination.displayPath else {
            showMessage(verb, "For FTP, copies go into the other panel's folder. To rename on the server, use 6 and type only the new name.")
            return true
        }

        let sources = items.map { TransferPlanner.Source(location: location(for: $0, in: source), isFolder: $0.kind == .directory, size: $0.size ?? 0) }
        commander.showHint("Preparing \(verb.lowercased())…", duration: 30)
        background({ try TransferPlanner.plan(sources, into: destination) }) { [weak self] result in
            guard let self = self else { return }
            commander.showHint("", duration: 0.01)
            switch result {
            case .failure(let e):
                self.report(e, title: "\(verb) failed")
            case .success(var plan):
                // Existing targets: ask (with "for all"), as for local copies.
                var skip = Set<Int>()
                var remembered: ConflictChoice?
                for i in plan.conflicts {
                    let item = plan.items[i]
                    let choice: ConflictChoice
                    if let r = remembered { choice = r } else {
                        let answer = prompts.resolveConflict(source: URL(fileURLWithPath: item.source.displayPath),
                                                              existing: URL(fileURLWithPath: item.destination.displayPath))
                        choice = answer.0
                        if answer.applyToAll { remembered = answer.0 }
                    }
                    if choice == .cancel { return }
                    if choice == .skip { skip.insert(i) }
                }
                plan.items = plan.items.enumerated().filter { !skip.contains($0.offset) }.map(\.element)
                let job = TransferJob(title: "\(verb) \(what): \(sources.first?.location.displayPath ?? "") → \(destination.displayPath)",
                                      items: plan.items, isMove: move, sourceFoldersToRemove: move ? plan.foldersToRemove : [])
                source.model.clearMarks()
                if !self.runSynchronously { self.transfersWindow.present() }
                self.transfers.enqueue(job)
            }
        }
        return true
    }

    /// 8 in a remote panel: permanent deletion on the server, after confirmation naming the path.
    func delete(prompts: FileCommandPrompts) -> Bool {
        guard let commander = commander, let session = session(for: commander.activeView) else { return false }
        let panel = commander.activeView
        let items = panel.model.operationTargets
        guard !items.isEmpty else { NSSound.beep(); return true }
        let place = session.addressLabel + RemoteSession.path(of: panel.model.directory)
        guard prompts.confirm(title: "Delete on server",
                              message: "Permanently delete \(FileCommands.describe(items)) from \(place)?\nThis cannot be undone (there is no Trash on the server).",
                              okTitle: "Delete") else { return true }
        background({ () -> [String] in
            var problems: [String] = []
            for entry in items {
                let path = RemoteSession.path(of: entry.url)
                do {
                    if entry.kind == .directory {
                        let tree = try session.walk(path)
                        for f in tree.files {
                            do { try session.client.deleteFile(f.path) } catch { problems.append("\(f.path): \((error as? FTPError)?.message ?? "\(error)")") }
                        }
                        for d in tree.folders.reversed() {
                            do { try session.client.removeDirectory(d) } catch { problems.append("\(d): \((error as? FTPError)?.message ?? "\(error)")") }
                        }
                        try session.client.removeDirectory(path)
                    } else {
                        try session.client.deleteFile(path)
                    }
                } catch {
                    problems.append("\(path): \((error as? FTPError)?.message ?? "\(error)")")
                }
            }
            return problems
        }) { [weak self] result in
            if case .success(let problems) = result, !problems.isEmpty {
                var report = OperationReport()
                report.errors = problems
                prompts.showProblems(title: "Some items were not deleted", report: report)
            }
            panel.model.clearMarks()
            self?.refresh(panel)
        }
        return true
    }

    /// 7 in a remote panel: create a folder on the server.
    func newFolder(prompts: FileCommandPrompts) -> Bool {
        guard let commander = commander, let session = session(for: commander.activeView) else { return false }
        let panel = commander.activeView
        guard let name = prompts.askText(title: "New Folder", message: "New folder (directory) on the server:",
                                         defaultValue: "", okTitle: "Create")?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return true }
        guard FTPListingParser.isSafeName(name.replacingOccurrences(of: "/", with: "_")) else {
            showMessage("New Folder", "That name is not allowed.")
            return true
        }
        let path = RemoteSession.normalize(RemoteSession.path(of: panel.model.directory) + "/" + name)
        background({ try session.client.makeDirectory(path) }) { [weak self] result in
            if case .failure(let e) = result { self?.report(e, title: "Cannot create the folder") }
            self?.refresh(panel)
            if case .success = result {
                DispatchQueue.main.asyncAfter(deadline: .now() + (self?.runSynchronously == true ? 0 : 0.6)) {
                    panel.model.focus(name: (name as NSString).pathComponents.first ?? name, visibleRows: panel.visibleRows)
                    panel.needsDisplay = true
                }
            }
        }
        return true
    }
}
