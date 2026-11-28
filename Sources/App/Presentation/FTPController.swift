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
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = text
        Modal.run(alert)
    }
    /// Asks whether to trust an unverified certificate (summary). Replaceable in tests.
    public var askTrust: (String) -> Bool = { summary in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The server's certificate could not be verified"
        alert.informativeText = summary + "\n\nOnly trust it if you know this is the right server. ClassicCommander will remember exactly this key and refuse a different one later."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Trust")
        return Modal.run(alert) == .alertSecondButtonReturn
    }
    /// Asks whether to trust an SSH server's host key (fingerprints). Replaceable in tests.
    public var askHostKeyTrust: (String) -> Bool = { text in
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Unknown SSH host key"
        alert.informativeText = text + "\n\nOnly trust it if the fingerprint is right. ClassicCommander will remember these keys and refuse different ones later."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Trust")
        return Modal.run(alert) == .alertSecondButtonReturn
    }
    public private(set) lazy var managerWindow = FTPConnectionManagerController(ftp: self)
    public private(set) lazy var transfersWindow = TransfersWindowController(manager: transfers)
    public private(set) var progressWindows: [UUID: TransferProgressWindowController] = [:]

    init(commander: CommanderView, repository: FTPProfileRepository = FTPProfileRepository()) {
        self.commander = commander
        self.repository = repository
        Self.removeOldTemporaryCopies()
        transfers.onChange = { [weak self] job in
            self?.transfersWindow.refresh()
            self?.progressWindows[job.id]?.update()
            if job.state == .finished || job.state == .cancelled {
                self?.progressWindows.removeValue(forKey: job.id)?.close()
                self?.commander?.reloadPanels()
                // Problems are never silent: the queue opens on a job with failures.
                if job.failedCount > 0 && self?.runSynchronously == false { self?.transfersWindow.present() }
            }
        }
        // "Target file exists": asked through the commander's prompts (the real dialog in the app).
        transfers.resolveConflict = { [weak self] conflict in
            self?.commander?.fileCommands.prompts.resolveConflict(conflict) ?? .skip
        }
    }

    /// Runs a copy or move job. The queue window opens for queued jobs, and for any job still
    /// running after a moment (quick renames and small copies don't flash it up).
    func startJob(_ job: TransferJob, synchronously: Bool = false, existingProgressWindow: TransferProgressWindowController? = nil) {
        let sync = synchronously || runSynchronously
        transfers.enqueue(job, synchronously: sync)
        guard !sync else { return }
        if job.waitsInQueue {
            existingProgressWindow?.close()
            transfersWindow.present()
        } else if let pw = existingProgressWindow {
            progressWindows[job.id] = pw
            pw.startActive(job: job)
        } else {
            let controller = TransferProgressWindowController(job: job) { [weak self] in
                self?.transfersWindow.present()
            }
            progressWindows[job.id] = controller
            controller.present()
        }
    }

    /// How long a job may run before the queue window opens by itself.
    static var queueWindowDelay: TimeInterval = 0.7

    func showQueueIfRunning(_ job: TransferJob) {
        if TransferManager.isUnfinished(job) { transfersWindow.present() }
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
            panel.busyText = nil
            self?.finishConnect(result, client: client, profile: profile, side: side, panel: panel,
                                commander: commander, password: password, completion: completion)
        }
    }

    private func finishConnect(
        _ result: Result<[RemoteEntry], Error>, client: RemoteClient, profile: FTPProfile,
        side: CommanderModel.Side, panel: PanelView, commander: CommanderView,
        password: String?, completion: ((Result<Void, FTPError>) -> Void)?
    ) {
        switch result {
        case .success(let listing):
            handleConnectSuccess(listing: listing, client: client, profile: profile, side: side, panel: panel, commander: commander, completion: completion)
        case .failure(let error):
            handleConnectFailure(error: error, profile: profile, password: password, side: side, completion: completion)
        }
    }

    private func handleConnectSuccess(
        listing: [RemoteEntry],
        client: RemoteClient,
        profile: FTPProfile,
        side: CommanderModel.Side,
        panel: PanelView,
        commander: CommanderView,
        completion: ((Result<Void, FTPError>) -> Void)?
    ) {
        let session = RemoteSession(client: client)
        session.store(listing, for: client.startPath)
        replaceSession(in: panel, with: session, side: side)
        panel.model.switchSource(RemoteLister(session: session), to: session.url(for: client.startPath), visibleRows: panel.visibleRows)
        panel.remote = (session.statusLabel, session.addressLabel, !profile.isEncrypted)
        openLocalStartDirectory(profile.localDirectory, side: side, commander: commander)
        commander.activate(side)
        commander.updateFunctionBar()
        panel.needsDisplay = true
        completion?(.success(()))
    }

    private func replaceSession(in panel: PanelView, with session: RemoteSession, side: CommanderModel.Side) {
        if !panel.model.isRemote { localBefore[side] = panel.model.directory }
        else if let old = self.session(for: panel) { sessions[old.id] = nil; old.client.close() }
        sessions[session.id] = session
    }

    private func openLocalStartDirectory(_ path: String, side: CommanderModel.Side, commander: CommanderView) {
        let other = commander.view(for: side.other)
        guard !path.isEmpty, !other.model.isRemote else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        other.model.go(to: url, visibleRows: other.visibleRows)
        other.needsDisplay = true
    }

    private func handleConnectFailure(
        error: Error,
        profile: FTPProfile,
        password: String?,
        side: CommanderModel.Side,
        completion: ((Result<Void, FTPError>) -> Void)?
    ) {
        let ftpError = error as? FTPError ?? .server(error.localizedDescription)
        if ftpError == .certificateUntrusted, profile.pinnedPublicKey == nil {
            offerTrust(profile, password: password, side: side, completion: completion)
            return
        }
        if ftpError == .hostKeyUnknown {
            offerHostKeyTrust(profile, password: password, side: side, completion: completion)
            return
        }
        completion?(.failure(ftpError))
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
            self.saveIfStored(pinned, password: password)
            self.connect(pinned, password: password, side: side, completion: completion)
        }
    }

    private func saveIfStored(_ profile: FTPProfile, password: String?) {
        if repository.profile(profile.id) != nil {
            repository.save(profile, password: password ?? repository.credentials.password(for: profile.id))
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
            self.saveIfStored(trusted, password: password)
            self.connect(trusted, password: password, side: side, completion: completion)
        }
    }

    /// Ends the session in a panel and shows the local folder it came from.
    public func disconnect(_ side: CommanderModel.Side) {
        guard let commander = commander, let (panel, session) = activeRemotePanel(for: side, commander: commander) else { return }
        closeSession(session, in: panel, side: side, commander: commander)
    }

    private func activeRemotePanel(for side: CommanderModel.Side, commander: CommanderView) -> (PanelView, RemoteSession)? {
        let panel = commander.view(for: side)
        guard let session = session(for: panel) else { NSSound.beep(); return nil }
        return (panel, session)
    }

    private func closeSession(_ session: RemoteSession, in panel: PanelView, side: CommanderModel.Side, commander: CommanderView) {
        sessions[session.id] = nil
        session.client.close()
        panel.model.switchSource(commander.localLister, to: localFolderBefore(side), visibleRows: panel.visibleRows)
        panel.remote = nil
        panel.needsDisplay = true
        commander.updateFunctionBar()
    }

    private func localFolderBefore(_ side: CommanderModel.Side) -> URL {
        localBefore[side] ?? FileManager.default.homeDirectoryForCurrentUser
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

    func navigate(_ panel: PanelView, _ action: CommandAction) -> Bool {
        guard let session = session(for: panel) else { return false }
        if action == .open || action == .enterFolder {
            return navigateOpenOrEnter(in: panel, session: session, action: action)
        }
        return navigateFolderAction(in: panel, session: session, action: action)
    }

    private func navigateFolderAction(in panel: PanelView, session: RemoteSession, action: CommandAction) -> Bool {
        let rows = panel.visibleRows
        switch action {
        case .parentFolder: navigateToParent(in: panel, session: session)
        case .goRoot: load(session, "/", in: panel) { panel.model.go(to: session.rootURL, visibleRows: rows) }
        case .goHome, .goDownloads: disconnectAndGoLocal(panel, home: action == .goHome)
        default: return false
        }
        return true
    }

    private func navigateOpenOrEnter(in panel: PanelView, session: RemoteSession, action: CommandAction) -> Bool {
        guard let entry = panel.model.currentEntry else { return true }
        return navigateEntry(entry, in: panel, session: session, action: action)
    }

    private func navigateToParent(in panel: PanelView, session: RemoteSession) {
        let current = RemoteSession.path(of: panel.model.directory)
        guard current != "/" else { return }
        let rows = panel.visibleRows
        load(session, (current as NSString).deletingLastPathComponent, in: panel) { panel.model.goUp(visibleRows: rows) }
    }

    private func disconnectAndGoLocal(_ panel: PanelView, home: Bool) {
        disconnect(side(of: panel))
        if home { panel.model.goHome(visibleRows: panel.visibleRows) } else { panel.model.goDownloads(visibleRows: panel.visibleRows) }
    }

    private func navigateEntry(_ entry: FileEntry, in panel: PanelView, session: RemoteSession, action: CommandAction) -> Bool {
        let rows = panel.visibleRows
        switch entry.kind {
        case .parent: return navigate(panel, .parentFolder)
        case .directory: load(session, RemoteSession.path(of: entry.url), in: panel) { panel.model.openCurrent(visibleRows: rows) }
        case .file: navigateFileEntry(entry, in: panel, session: session, open: action == .open)
        }
        return true
    }

    private func navigateFileEntry(_ entry: FileEntry, in panel: PanelView, session: RemoteSession, open: Bool) {
        if entry.isSymlink {
            navigateSymlink(entry, in: panel, session: session, openOnFailure: open)
        } else if open {
            openRemoteFile(entry, session: session)
        }
    }

    private func navigateSymlink(_ entry: FileEntry, in panel: PanelView, session: RemoteSession, openOnFailure: Bool) {
        // A link: a link to a folder is entered, a link to a file is opened like a file.
        let path = RemoteSession.path(of: entry.url)
        panel.busyText = "Reading \(path)…"
        background({ try session.fetch(path) }) { [weak self] result in
            panel.busyText = nil
            switch result {
            case .success:
                panel.model.go(to: session.url(for: path), visibleRows: panel.visibleRows)
                panel.needsDisplay = true
            case .failure:
                if openOnFailure { self?.openRemoteFile(entry, session: session) } else { NSSound.beep() }
            }
        }
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
        let folder = Self.parentFolderPath(of: path)
        load(session, folder, in: panel) {
            panel.model.go(to: session.url(for: folder), visibleRows: panel.visibleRows)
            panel.model.focus(name: (path as NSString).lastPathComponent, visibleRows: panel.visibleRows)
        }
        return true
    }

    private static func parentFolderPath(of path: String) -> String {
        let raw = (path as NSString).deletingLastPathComponent
        return raw.isEmpty ? "/" : raw
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
            if let url = Self.remoteURL(in: s, suffix: String(text.dropFirst(s.addressLabel.count))) { return url }
        }
        return nil
    }

    private static func remoteURL(in session: RemoteSession, suffix: String) -> URL? {
        if suffix.isEmpty { return session.url(for: "/") }
        return suffix.hasPrefix("/") ? session.url(for: suffix) : nil
    }

    /// Re-reads the remote folder (Refresh, and after transfers).
    /// ⇧6 on a server: renames there, then shows the folder again with the cursor on the new name.
    func rename(_ entry: FileEntry, to name: String, in panel: PanelView) {
        guard let session = session(for: panel) else { return }
        let from = RemoteSession.path(of: entry.url)
        let to = RemoteSession.normalize((from as NSString).deletingLastPathComponent + "/" + name)
        background({ try session.client.rename(from, to: to) }) { [weak self] result in
            if case .failure(let e) = result { self?.report(e, title: "Rename failed") }
            self?.refresh(panel)
            panel.model.focus(name: name, visibleRows: panel.visibleRows)
        }
    }

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
        downloadTemporary(entry, session: session) { url in Modal.open(url) }
    }

    // MARK: File commands

    private func location(for entry: FileEntry, in panel: PanelView?) -> TransferLocation {
        if let panel = panel, let s = session(for: panel) { return .remote(s, RemoteSession.path(of: entry.url)) }
        return .local(entry.url)
    }

    private func folderLocation(_ panel: PanelView) -> TransferLocation {
        if let s = session(for: panel) { return .remote(s, RemoteSession.path(of: panel.model.directory)) }
        return .local(panel.model.directory)
    }

    /// A folder given by its URL (local, or ccftp:// on a connected server).
    private func folderLocation(of url: URL) -> TransferLocation {
        if let id = RemoteSession.sessionID(of: url), let s = sessions[id] { return .remote(s, RemoteSession.path(of: url)) }
        return .local(url)
    }

    /// 5 / 6 (or a drop) when a server is involved. Returns false when everything is local.
    func transfer(move: Bool, prompts: FileCommandPrompts, drop: PanelDrop? = nil) -> Bool {
        guard let commander = commander else { return false }
        let (source, items, destination) = resolveRemoteTransferTarget(drop: drop, commander: commander)
        guard source?.model.isRemote == true || destination.isRemote else { return false }
        guard !items.isEmpty else { NSSound.beep(); return true }
        startRemoteTransfer(items: items, source: source, destination: destination,
                            move: move, prompts: prompts, commander: commander)
        return true
    }

    private func startRemoteTransfer(
        items: [FileEntry], source: PanelView?, destination: TransferLocation,
        move: Bool, prompts: FileCommandPrompts, commander: CommanderView
    ) {
        let verb = move ? "Move" : "Copy"
        guard let answer = askAndValidateRemoteTransfer(items: items, source: source, destination: destination,
                                                        verb: verb, move: move, prompts: prompts) else { return }
        runRemoteTransferPlan(sources: buildRemoteSources(items: items, in: source), what: FileCommands.describe(items),
                              destination: destination, verb: verb, move: move, answer: answer, source: source, commander: commander)
    }

    private func askAndValidateRemoteTransfer(
        items: [FileEntry], source: PanelView?, destination: TransferLocation,
        verb: String, move: Bool, prompts: FileCommandPrompts
    ) -> TransferAnswer? {
        let defaultText = Self.defaultRemoteTargetPath(for: destination)
        guard let answer = prompts.askTransfer(FileCommands.question(verb: verb, items: items, target: defaultText)) else { return nil }
        if move, tryRemoteRename(items: items, typed: answer.target, source: source) { return nil }
        guard isValidRemoteTarget(answer.target, defaultText: defaultText, destination: destination, verb: verb) else { return nil }
        return answer
    }

    private static func defaultRemoteTargetPath(for destination: TransferLocation) -> String {
        destination.displayPath.hasSuffix("/") ? destination.displayPath : destination.displayPath + "/"
    }

    private func isValidRemoteTarget(_ target: String, defaultText: String, destination: TransferLocation, verb: String) -> Bool {
        guard target == defaultText || target == destination.displayPath else {
            showMessage(verb, "For FTP, copies go into the other panel's folder. To rename on the server, use 6 and type only the new name.")
            return false
        }
        return true
    }

    private func buildRemoteSources(items: [FileEntry], in source: PanelView?) -> [TransferPlanner.Source] {
        items.map {
            TransferPlanner.Source(location: location(for: $0, in: source), isFolder: $0.kind == .directory,
                                   size: $0.size ?? 0, modified: $0.modified)
        }
    }

    private func runRemoteTransferPlan(
        sources: [TransferPlanner.Source],
        what: String,
        destination: TransferLocation,
        verb: String,
        move: Bool,
        answer: TransferAnswer,
        source: PanelView?,
        commander: CommanderView
    ) {
        let cancelFlag = CancelFlag()
        let progressWindow = makeTransferProgressWindow(
            verb: verb,
            from: sources.first?.location.displayPath ?? "",
            to: destination.displayPath,
            answer: answer,
            cancelFlag: cancelFlag,
            commander: commander
        )
        background({ try TransferPlanner.plan(sources, into: destination, move: move, mask: answer.fileMask, cancel: cancelFlag) }) { [weak self] result in
            self?.finishPlannedTransfer(
                result: result,
                verb: verb,
                what: what,
                fromDisplay: sources.first?.location.displayPath ?? "",
                toDisplay: destination.displayPath,
                move: move,
                answer: answer,
                source: source,
                commander: commander,
                cancelFlag: cancelFlag,
                progressWindow: progressWindow
            )
        }
    }

    private func resolveRemoteTransferTarget(drop: PanelDrop?, commander: CommanderView) -> (PanelView?, [FileEntry], TransferLocation) {
        if let drop = drop {
            return (drop.source, drop.entries, folderLocation(of: drop.folder))
        }
        return (commander.activeView,
                commander.activeView.model.operationTargets,
                folderLocation(commander.view(for: commander.model.activeSide.other)))
    }

    private func tryRemoteRename(items: [FileEntry], typed: String, source: PanelView?) -> Bool {
        guard let source = source, let session = session(for: source),
              items.count == 1, !typed.contains("/"), !typed.isEmpty else {
            return false
        }
        let from = RemoteSession.path(of: items[0].url)
        let to = RemoteSession.normalize((from as NSString).deletingLastPathComponent + "/" + typed)
        background({ try session.client.rename(from, to: to) }) { [weak self] result in
            if case .failure(let e) = result { self?.report(e, title: "Rename failed") }
            self?.refresh(source)
        }
        return true
    }

    private func makeTransferProgressWindow(
        verb: String,
        from: String,
        to: String,
        answer: TransferAnswer,
        cancelFlag: CancelFlag,
        commander: CommanderView
    ) -> TransferProgressWindowController? {
        guard !runSynchronously && !answer.queue else {
            commander.showHint("Preparing \(verb.lowercased())…", duration: 30)
            return nil
        }
        let pw = TransferProgressWindowController(
            title: verb,
            from: from,
            to: to,
            cancelFlag: cancelFlag,
            onCancel: nil
        ) { [weak self] in
            self?.transfersWindow.present()
        }
        pw.present()
        return pw
    }

    private func finishPlannedTransfer(
        result: Result<TransferPlanner.Plan, Error>,
        verb: String,
        what: String,
        fromDisplay: String,
        toDisplay: String,
        move: Bool,
        answer: TransferAnswer,
        source: PanelView?,
        commander: CommanderView,
        cancelFlag: CancelFlag,
        progressWindow: TransferProgressWindowController?
    ) {
        commander.showHint("", duration: 0.01)
        switch result {
        case .failure(let e):
            handlePlannedFailure(e, verb: verb, progressWindow: progressWindow)
        case .success(let plan):
            guard !cancelFlag.isCancelled else { progressWindow?.close(); return }
            startPlannedJob(plan, title: "\(verb) \(what): \(fromDisplay) → \(toDisplay)",
                            move: move, answer: answer, source: source, progressWindow: progressWindow)
        }
    }

    private func handlePlannedFailure(_ error: Error, verb: String, progressWindow: TransferProgressWindowController?) {
        progressWindow?.close()
        if (error as? FTPError) != .cancelled { report(error, title: "\(verb) failed") }
    }

    private func startPlannedJob(
        _ plan: TransferPlanner.Plan, title: String, move: Bool, answer: TransferAnswer,
        source: PanelView?, progressWindow: TransferProgressWindowController?
    ) {
        let job = TransferJob(title: title, items: plan.items, isMove: move,
                              sourceFoldersToRemove: move ? plan.foldersToRemove : [])
        job.verify = answer.verify
        job.waitsInQueue = answer.queue
        source?.model.clearMarks()
        startJob(job, existingProgressWindow: progressWindow)
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
        background({ Self.deleteRemoteItems(items, session: session) }) { [weak self] result in
            self?.finishRemoteDelete(result, panel: panel, prompts: prompts)
        }
        return true
    }

    private func finishRemoteDelete(_ result: Result<[String], Error>, panel: PanelView, prompts: FileCommandPrompts) {
        if case .success(let problems) = result, !problems.isEmpty {
            var report = OperationReport()
            report.errors = problems
            prompts.showProblems(title: "Some items were not deleted", report: report)
        }
        panel.model.clearMarks()
        refresh(panel)
    }

    private static func deleteRemoteItems(_ items: [FileEntry], session: RemoteSession) -> [String] {
        var problems: [String] = []
        for entry in items {
            let path = RemoteSession.path(of: entry.url)
            do {
                if entry.kind == .directory {
                    try deleteRemoteDirectory(path, session: session, problems: &problems)
                } else {
                    try session.client.deleteFile(path)
                }
            } catch {
                problems.append("\(path): \((error as? FTPError)?.message ?? "\(error)")")
            }
        }
        return problems
    }

    private static func deleteRemoteDirectory(_ path: String, session: RemoteSession, problems: inout [String]) throws {
        let tree = try session.walk(path)
        for f in tree.files { deleteRemoteEntry(f.path, isDir: false, session: session, problems: &problems) }
        for d in tree.folders.reversed() { deleteRemoteEntry(d, isDir: true, session: session, problems: &problems) }
        try session.client.removeDirectory(path)
    }

    private static func deleteRemoteEntry(_ path: String, isDir: Bool, session: RemoteSession, problems: inout [String]) {
        do {
            if isDir { try session.client.removeDirectory(path) } else { try session.client.deleteFile(path) }
        } catch {
            problems.append("\(path): \((error as? FTPError)?.message ?? "\(error)")")
        }
    }

    /// 7 in a remote panel: create a folder on the server.
    func newFolder(prompts: FileCommandPrompts) -> Bool {
        guard let commander = commander, let session = session(for: commander.activeView) else { return false }
        let panel = commander.activeView
        guard let name = askValidatedFolderName(prompts: prompts) else { return true }
        let path = RemoteSession.normalize(RemoteSession.path(of: panel.model.directory) + "/" + name)
        background({ try session.client.makeDirectory(path) }) { [weak self] result in
            self?.handleMakeDirectoryResult(result, name: name, in: panel)
        }
        return true
    }

    private func handleMakeDirectoryResult(_ result: Result<Void, Error>, name: String, in panel: PanelView) {
        if case .failure(let e) = result { report(e, title: "Cannot create the folder") }
        refresh(panel)
        if case .success = result { focusCreatedFolder(name, in: panel) }
    }

    private func askValidatedFolderName(prompts: FileCommandPrompts) -> String? {
        guard let raw = prompts.askText(title: "New Folder", message: "New folder (directory) on the server:",
                                        defaultValue: "", okTitle: "Create")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        guard FTPListingParser.isSafeName(raw.replacingOccurrences(of: "/", with: "_")) else {
            showMessage("New Folder", "That name is not allowed.")
            return nil
        }
        return raw
    }

    private func focusCreatedFolder(_ name: String, in panel: PanelView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (runSynchronously ? 0 : 0.6)) {
            panel.model.focus(name: (name as NSString).pathComponents.first ?? name, visibleRows: panel.visibleRows)
            panel.needsDisplay = true
        }
    }
}
