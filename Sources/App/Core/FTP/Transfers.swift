import Foundation

/// A place a file lives: on this Mac or on a connected server.
public enum TransferLocation {
    case local(URL)
    case remote(RemoteSession, String)

    public var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    public var displayPath: String {
        switch self {
        case .local(let url): return url.path
        case let .remote(session, path): return session.addressLabel + path
        }
    }

    var name: String {
        switch self {
        case .local(let url): return url.lastPathComponent
        case .remote(_, let path): return (path as NSString).lastPathComponent
        }
    }

    /// The same folder, another name (Rename in the "target exists" dialog).
    func sibling(named name: String) -> TransferLocation {
        switch self {
        case .local(let url): return .local(url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false))
        case let .remote(session, path): return .remote(session, RemoteSession.normalize((path as NSString).deletingLastPathComponent + "/" + name))
        }
    }

    func appending(_ relative: String, isDirectory: Bool = false) -> TransferLocation {
        switch self {
        // isDirectory given: URL.appendingPathComponent(_:) would otherwise stat the disk to find out.
        case .local(let url): return .local(url.appendingPathComponent(relative, isDirectory: isDirectory))
        case let .remote(session, path): return .remote(session, RemoteSession.normalize(path + "/" + relative))
        }
    }
}

/// One step of a transfer: a file to copy, or a folder to create (so empty folders arrive too).
public struct TransferItem {
    public let source: TransferLocation
    public let destination: TransferLocation
    public let size: Int64
    public let isFolder: Bool
    /// The source's date (shown when the target exists, and for "Replace all older").
    public var modified: Date? = nil
    /// The target existed when the job was planned (server targets are only checked then).
    public var conflict = false
    /// A local folder moved in one step (same disk, nothing at the target yet).
    public var isWholeFolder = false
}

public enum TransferItemResult: Equatable {
    case pending, done, skipped(String), failed(String)
}

/// A file about to be copied onto one that exists: both sides, for the "target file exists" dialog.
public struct TransferConflict {
    public let source: TransferLocation
    public let target: TransferLocation
    public let sourceSize: Int64
    public let sourceDate: Date?
    public let targetSize: Int64?
    public let targetDate: Date?
}

/// The answer to a "target file exists" question.
public enum ConflictDecision: Equatable {
    case replace, replaceAll, skip, skipAll, replaceAllOlder, rename(String), cancel
}

/// Thrown for a file the user chose to skip.
struct TransferSkipped: Error {}

/// A queued copy or move between this Mac and a server (or two servers, through this Mac).
public final class TransferJob {
    public enum State: Equatable { case queued, running, finishing, finished, cancelled }

    public let id = UUID()
    public let title: String
    public let isMove: Bool
    /// Each copied file is read back and compared (the dialog's "Verify").
    public var verify = false
    /// Added with "Queue": runs after the queued jobs before it, one at a time.
    public var waitsInQueue = false
    /// Files being copied right now.
    public internal(set) var active: Set<Int> = []
    /// Held back in the queue until the queued job before it is done.
    var isHeld = false
    /// "Replace all", "Skip all" or "Replace all older", once answered for this job.
    var conflictRule: ConflictDecision?
    public internal(set) var items: [TransferItem]
    public internal(set) var results: [TransferItemResult]
    /// Folders to remove after a successful move (deepest first).
    let sourceFoldersToRemove: [TransferLocation]
    /// Resume partially transferred files (used by Retry).
    let resume: Bool
    public internal(set) var state: State = .queued
    /// Files of this job transferring right now.
    public internal(set) var running = 0
    /// Bytes of finished files, and of the files in progress.
    var completedBytes: Int64 = 0
    var partial: [Int: Int64] = [:]
    public var bytesDone: Int64 { partial.values.reduce(completedBytes) { $0.addingSaturated($1) } }
    public internal(set) var started: Date?
    public internal(set) var finished: Date?
    let cancelFlag = CancelFlag()

    public init(title: String, items: [TransferItem], isMove: Bool, sourceFoldersToRemove: [TransferLocation] = [], resume: Bool = false) {
        self.title = title
        self.items = items
        self.isMove = isMove
        self.sourceFoldersToRemove = sourceFoldersToRemove
        self.resume = resume
        results = Array(repeating: .pending, count: items.count)
    }

    public var bytesTotal: Int64 { items.reduce(0) { $0.addingSaturated($1.size) } }
    public var failedCount: Int { results.filter { if case .failed = $0 { return true } else { return false } }.count }
    public var doneCount: Int { results.filter { $0 == .done }.count }
    public var fileCount: Int { items.filter { !$0.isFolder }.count }

    public var elapsed: TimeInterval { (finished ?? Date()).timeIntervalSince(started ?? Date()) }
    /// Bytes per second since the start.
    public var speed: Double { elapsed > 0.2 ? Double(bytesDone) / elapsed : 0 }

    /// "Done", "3 failed", "Cancelled", "Running 4 of 10", "Queued".
    public var statusText: String {
        switch state {
        case .queued: return waitsInQueue ? "Waiting in the queue" : "Queued"
        case .running, .finishing:
            return "Copying \(running) at once · \(doneCount) of \(items.count) done"
        case .cancelled: return "Cancelled (\(doneCount) done)"
        case .finished: return failedCount == 0 ? "Done (\(doneCount) of \(items.count))" : "\(failedCount) failed, \(doneCount) done"
        }
    }

    public func cancel() { cancelFlag.cancel() }

    /// A new job with only the failed items, resuming partial transfers where the server allows.
    public func retryJob() -> TransferJob? {
        let failed = items.indices.filter { if case .failed = results[$0] { return true } else { return false } }
        guard !failed.isEmpty else { return nil }
        return TransferJob(title: "Retry: " + title, items: failed.map { items[$0] }, isMove: isMove, resume: true)
    }
}

/// How many files may transfer at the same time (Options → Operation).
/// 0 for uploads or downloads means "no separate limit": the total applies.
public struct TransferLimits: Equatable {
    public var total: Int
    public var uploads: Int
    public var downloads: Int

    public init(total: Int = 3, uploads: Int = 0, downloads: Int = 0) {
        self.total = max(1, total)
        self.uploads = max(0, uploads)
        self.downloads = max(0, downloads)
    }

    public var effectiveUploads: Int { uploads == 0 ? total : min(uploads, total) }
    public var effectiveDownloads: Int { downloads == 0 ? total : min(downloads, total) }

    /// Whether one more transfer of this kind may start next to the running ones.
    func allows(_ kind: TransferKind, running: (total: Int, up: Int, down: Int)) -> Bool {
        guard running.total < total else { return false }
        if kind.isUpload && running.up >= effectiveUploads { return false }
        if kind.isDownload && running.down >= effectiveDownloads { return false }
        return true
    }
}

/// What a file transfer does on the network (server to server is both).
struct TransferKind {
    let isUpload: Bool
    let isDownload: Bool

    init(_ item: TransferItem) {
        var up = false, down = false
        if case .remote = item.source { down = true }
        if case .remote = item.destination { up = true }
        isUpload = up
        isDownload = down
    }
}

/// Runs transfer jobs: folders of a job are created first, then its files are transferred, several
/// at a time within the limits (total, uploads, downloads), oldest jobs first. Progress is
/// reported on the main thread.
public final class TransferManager {
    public private(set) var jobs: [TransferJob] = []
    /// Called on the main thread whenever a job changes (for the Transfers window and panels).
    public var onChange: ((TransferJob) -> Void)?
    /// Tests run jobs synchronously (one file after another).
    public var runSynchronously = false
    /// Changing the limits takes effect for the next files to start.
    public var limits = TransferLimits() {
        didSet { schedule() }
    }
    /// Asks what to do with a file whose target exists; called on the main thread.
    /// nil: targets are replaced.
    public var resolveConflict: ((TransferConflict) -> ConflictDecision)?

    private let lock = NSLock()
    private let workers = DispatchQueue(label: "ClassicCommander.transfers", attributes: .concurrent)
    /// Files waiting to start: (job, item index), in queue order.
    private var waiting: [(TransferJob, Int)] = []
    private var running: (total: Int, up: Int, down: Int) = (0, 0, 0)
    /// Highest number of files that ran at once (for tests and diagnostics).
    public private(set) var peakConcurrency = 0
    public private(set) var peakUploads = 0
    public private(set) var peakDownloads = 0

    public init() {}

    /// Starts a job, or (`waitsInQueue`) lines it up behind the queued jobs still to finish.
    /// `synchronously`: runs it on the calling thread, file after file (tests, quick renames).
    public func enqueue(_ job: TransferJob, synchronously: Bool = false) {
        lock.lock()
        let mustWait = job.waitsInQueue && jobs.contains { $0.waitsInQueue && Self.isUnfinished($0) }
        job.isHeld = mustWait
        jobs.append(job)
        lock.unlock()
        notify(job)
        if runSynchronously || synchronously { runSerially(job); return }
        if mustWait { return }
        workers.async { [weak self] in self?.start(job) }
    }

    static func isUnfinished(_ job: TransferJob) -> Bool {
        job.state == .queued || job.state == .running || job.state == .finishing
    }

    /// The next queued job, once the one before it is done.
    private func startNextInQueue() {
        lock.lock()
        let busy = jobs.contains { $0.waitsInQueue && !$0.isHeld && Self.isUnfinished($0) }
        let next = busy ? nil : jobs.first { $0.isHeld && $0.state == .queued }
        next?.isHeld = false
        lock.unlock()
        guard let job = next else { return }
        if runSynchronously { runSerially(job); return }
        workers.async { [weak self] in self?.start(job) }
    }

    public func clearFinished() {
        lock.lock()
        jobs.removeAll { $0.state == .finished || $0.state == .cancelled }
        lock.unlock()
    }

    /// "Remove completed": jobs that finished without problems leave the list.
    public func removeCompleted() {
        lock.lock()
        jobs.removeAll { $0.state == .finished && $0.failedCount == 0 }
        lock.unlock()
    }

    private func notify(_ job: TransferJob) {
        if runSynchronously || Thread.isMainThread { onChange?(job); return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(job) }
    }

    /// Creates the job's folders (in order, so parents come first), then queues its files.
    private func start(_ job: TransferJob) {
        lock.lock()
        // Cancelled before it got going: it stays cancelled.
        if job.state == .cancelled { lock.unlock(); return }
        job.state = .running
        job.started = Date()
        lock.unlock()
        notify(job)
        for (i, item) in job.items.enumerated() where item.isFolder {
            if job.cancelFlag.isCancelled { break }
            let result: TransferItemResult
            do { try perform(item, job: job) { _ in }; result = .done } catch { result = Self.result(for: error) }
            lock.lock(); job.results[i] = result; lock.unlock()
        }
        lock.lock()
        waiting += job.items.indices.filter { !job.items[$0].isFolder }.map { (job, $0) }
        lock.unlock()
        schedule()
        finishIfDone(job)
    }

    /// Starts as many waiting files as the limits allow.
    private func schedule() {
        guard !runSynchronously else { return }
        lock.lock()
        var starting: [(TransferJob, Int)] = []
        var dropped: [TransferJob] = []
        var i = 0
        while i < waiting.count {
            let (job, index) = waiting[i]
            if job.cancelFlag.isCancelled {
                waiting.remove(at: i)
                if !dropped.contains(where: { $0 === job }) { dropped.append(job) }
                continue
            }
            let kind = TransferKind(job.items[index])
            if limits.allows(kind, running: running) {
                waiting.remove(at: i)
                running.total += 1
                if kind.isUpload { running.up += 1 }
                if kind.isDownload { running.down += 1 }
                peakConcurrency = max(peakConcurrency, running.total)
                peakUploads = max(peakUploads, running.up)
                peakDownloads = max(peakDownloads, running.down)
                job.running += 1
                starting.append((job, index))
            } else {
                i += 1
            }
        }
        lock.unlock()
        for (job, index) in starting {
            workers.async { [weak self] in self?.transfer(job, index) }
        }
        // Jobs whose remaining files were dropped by Cancel may be finished now.
        for job in dropped { finishIfDone(job) }
    }

    /// Cancel a job: running files stop, waiting ones are dropped. A job still waiting in the
    /// queue is just taken off it.
    public func cancel(_ job: TransferJob) {
        job.cancel()
        lock.lock()
        let neverStarted = job.isHeld
        if neverStarted {
            job.isHeld = false
            job.state = .cancelled
        }
        lock.unlock()
        if neverStarted {
            notify(job)
            startNextInQueue()
            return
        }
        schedule()
        finishIfDone(job)
    }

    /// Transfers one file on a worker thread, then lets the next waiting files start.
    private func transfer(_ job: TransferJob, _ index: Int) {
        let item = job.items[index]
        let kind = TransferKind(item)
        var lastNotify = Date.distantPast
        var result: TransferItemResult
        if job.cancelFlag.isCancelled {
            result = .pending
        } else {
            lock.lock(); job.active.insert(index); lock.unlock()
            notify(job)
            do {
                try perform(item, job: job) { [weak self] partial in
                    guard let self = self else { return }
                    self.lock.lock(); job.partial[index] = partial; self.lock.unlock()
                    if Date().timeIntervalSince(lastNotify) > 0.25 {
                        lastNotify = Date()
                        self.notify(job)
                    }
                }
                result = .done
            } catch FTPError.cancelled {
                result = .pending
            } catch {
                result = Self.result(for: error)
            }
        }
        lock.lock()
        job.active.remove(index)
        job.partial[index] = nil
        job.results[index] = result
        if result == .done { job.completedBytes = job.completedBytes.addingSaturated(item.size) }
        job.running -= 1
        running.total -= 1
        if kind.isUpload { running.up -= 1 }
        if kind.isDownload { running.down -= 1 }
        lock.unlock()
        notify(job)
        schedule()
        finishIfDone(job)
    }

    /// Finishes a job once none of its files is waiting or running.
    private func finishIfDone(_ job: TransferJob) {
        lock.lock()
        let stillWaiting = waiting.contains { $0.0 === job }
        guard job.state == .running, job.running == 0, !stillWaiting else { lock.unlock(); return }
        job.state = .finishing
        lock.unlock()
        complete(job)
    }

    private func complete(_ job: TransferJob) {
        if job.isMove && !job.cancelFlag.isCancelled && job.failedCount == 0 {
            for folder in job.sourceFoldersToRemove { removeFolder(folder) }
        }
        lock.lock()
        job.finished = Date()
        job.state = job.cancelFlag.isCancelled ? .cancelled : .finished
        lock.unlock()
        notify(job)
        if job.waitsInQueue { startNextInQueue() }
    }

    static func result(for error: Error) -> TransferItemResult {
        if error is TransferSkipped { return .skipped("the target exists") }
        if let e = error as? FTPError { return .failed(e.message) }
        return .failed(error.localizedDescription)
    }

    /// Tests: every item in order on the calling thread.
    private func runSerially(_ job: TransferJob) {
        job.state = .running
        job.started = Date()
        notify(job)
        for (i, item) in job.items.enumerated() {
            if job.cancelFlag.isCancelled { break }
            job.active.insert(i)
            defer { job.active.remove(i) }
            do {
                try perform(item, job: job) { partial in job.partial[i] = partial }
                job.results[i] = .done
                job.completedBytes = job.completedBytes.addingSaturated(item.size)
            } catch FTPError.cancelled {
                break
            } catch {
                job.results[i] = Self.result(for: error)
            }
            job.partial[i] = nil
        }
        job.state = .running
        job.running = 0
        complete(job)
    }

    /// Copies one item; for moves, deletes the source only after the copy was verified.
    private func perform(_ item: TransferItem, job: TransferJob, progress: @escaping (Int64) -> Void) throws {
        let cancel = job.cancelFlag
        if item.isFolder {
            switch item.destination {
            case .local(let url): try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            case let .remote(session, path):
                do { try session.client.makeDirectory(path) } catch {
                    // An existing folder is fine. Missing parents are created (FTP's MKD makes one level).
                    if (try? session.client.list(path, cancel: nil)) == nil {
                        var parent = ""
                        for part in path.split(separator: "/").dropLast() {
                            parent += "/" + part
                            try? session.client.makeDirectory(parent)
                        }
                        do { try session.client.makeDirectory(path) } catch {
                            if (try? session.client.list(path, cancel: nil)) == nil { throw error }
                        }
                    }
                }
                session.invalidate((path as NSString).deletingLastPathComponent)
            }
            progress(0)   // folders carry no bytes
            return
        }
        // An existing target: ask (or follow an earlier "… all"); Skip and Cancel end here.
        guard let destination = try settle(item, job: job) else { throw TransferSkipped() }
        let fm = FileManager.default
        switch (item.source, destination) {
        case let (.local(url), .remote(session, path)):
            try session.client.upload(url, to: path, resume: job.resume, cancel: cancel, progress: progress)
            session.invalidate((path as NSString).deletingLastPathComponent)
        case let (.remote(session, path), .local(url)):
            try session.client.download(path, to: url, expectedSize: item.size, resume: job.resume, cancel: cancel, progress: progress)
        case let (.remote(from, path), .remote(to, target)):
            // Server to server goes through a temporary file on this Mac.
            let temp = fm.temporaryDirectory.appendingPathComponent("cc-ftp-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temp) }
            try from.client.download(path, to: temp, expectedSize: item.size, resume: false, cancel: cancel) { progress($0 / 2) }
            try to.client.upload(temp, to: target, resume: false, cancel: cancel) { progress(item.size / 2 + $0 / 2) }
            to.invalidate((target as NSString).deletingLastPathComponent)
        case let (.local(src), .local(dst)):
            if job.isMove && (item.isWholeFolder || !job.verify) {
                // A rename on the same disk; macOS copies and deletes across disks.
                if Self.exists(dst) { try fm.removeItem(at: dst) }
                try fm.moveItem(at: src, to: dst)
                progress(item.size)
                return
            }
            try Self.copyLocal(src, to: dst)
            progress(item.size)
        }
        if job.verify { try verify(item, at: destination) }
        if job.isMove { try deleteSource(item.source) }
    }

    /// Copies a file, replacing what is there only once the copy is complete.
    static func copyLocal(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard exists(dst) else { return try fm.copyItem(at: src, to: dst) }
        let temp = dst.deletingLastPathComponent().appendingPathComponent(".cc-copy-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: src, to: temp)
            _ = try fm.replaceItemAt(dst, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0   // lstat: a dangling link is there too
    }

    /// Size and date of whatever is at `location`, or nil when nothing is.
    static func existing(_ location: TransferLocation) -> (size: Int64?, date: Date?)? {
        switch location {
        case .local(let url):
            guard exists(url) else { return nil }
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (v?.fileSize.map(Int64.init), v?.contentModificationDate)
        case let .remote(session, path):
            let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
            guard let entry = (try? session.fetch(dir, useCache: false))?.first(where: { $0.name == name }) else { return nil }
            return (entry.size, entry.modified)
        }
    }

    /// Where the file really goes: its target, a new name chosen in the dialog, or nil to skip it.
    func settle(_ item: TransferItem, job: TransferJob) throws -> TransferLocation? {
        var target = item.destination
        // Local targets are checked now; server targets were checked when the job was planned.
        var check = !target.isRemote || item.conflict
        while check, let found = Self.existing(target) {
            let conflict = TransferConflict(source: item.source, target: target, sourceSize: item.size, sourceDate: item.modified,
                                            targetSize: found.size, targetDate: found.date)
            switch decide(conflict, job: job) {
            case .replace, .replaceAll: return target
            case .skip, .skipAll: return nil
            case .replaceAllOlder:
                // Replace only what is older than the file being copied.
                let older = (found.date ?? .distantPast) < (item.modified ?? .distantFuture)
                return older ? target : nil
            case .rename(let name):
                target = target.sibling(named: name)
                check = true
            case .cancel:
                job.cancel()
                throw FTPError.cancelled
            }
        }
        return target
    }

    /// The job's "… all" answer, or the user's (asked on the main thread, one dialog at a time).
    private func decide(_ conflict: TransferConflict, job: TransferJob) -> ConflictDecision {
        let ask: () -> ConflictDecision = { [weak self] in
            self?.lock.lock()
            let rule = job.conflictRule
            self?.lock.unlock()
            if let rule = rule { return rule }
            let answer = self?.resolveConflict?(conflict) ?? .replace
            if [.replaceAll, .skipAll, .replaceAllOlder].contains(answer) {
                self?.lock.lock(); job.conflictRule = answer; self?.lock.unlock()
            }
            return answer
        }
        return Thread.isMainThread ? ask() : DispatchQueue.main.sync(execute: ask)
    }

    /// Verify: reads the copy back (or, on a server, lists it) and compares it with the source.
    func verify(_ item: TransferItem, at destination: TransferLocation) throws {
        let ok: Bool
        switch (item.source, destination) {
        case let (.local(src), .local(dst)):
            do {
                ok = try FileComparison.fileSize(src) == FileComparison.fileSize(dst) && FileComparison.firstDifference(src, dst) == nil
            } catch {
                ok = false
            }
        case (_, .local(let dst)):
            ok = (try? FileComparison.fileSize(dst)) == item.size
        case (_, .remote):
            ok = Self.existing(destination)?.size == item.size
        }
        if !ok { throw FTPError.verificationFailed("the copy differs from \(item.source.displayPath)") }
    }

    private func deleteSource(_ location: TransferLocation) throws {
        switch location {
        case .local(let url): try FileManager.default.removeItem(at: url)
        case let .remote(session, path):
            try session.client.deleteFile(path)
            session.invalidate((path as NSString).deletingLastPathComponent)
        }
    }

    private func removeFolder(_ location: TransferLocation) {
        switch location {
        case .local(let url):
            if (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: url)
            }
        case let .remote(session, path):
            try? session.client.removeDirectory(path)
            session.invalidate((path as NSString).deletingLastPathComponent)
        }
    }
}

/// Builds transfer jobs from what is selected in a panel: folders are walked (locally or on the
/// server), the structure is kept, and existing targets are marked so the user can decide.
public enum TransferPlanner {
    public struct Source {
        public let location: TransferLocation
        public let isFolder: Bool
        public let size: Int64
        public let modified: Date?
        public init(location: TransferLocation, isFolder: Bool, size: Int64, modified: Date? = nil) {
            self.location = location
            self.isFolder = isFolder
            self.size = size
            self.modified = modified
        }
    }

    public struct Plan {
        public var items: [TransferItem] = []
        /// Indexes of items whose destination file already exists.
        public var conflicts: [Int] = []
        public var foldersToRemove: [TransferLocation] = []
        public var fileCount: Int { items.filter { !$0.isFolder }.count }
        public var bytes: Int64 { items.reduce(0) { $0.addingSaturated($1.size) } }
    }

    /// Each source goes into `destination` under its own name.
    public static func plan(_ sources: [Source], into destination: TransferLocation, move: Bool = false,
                            mask: FileMask? = nil, cancel: CancelFlag? = nil) throws -> Plan {
        try plan(sources.map { ($0, destination.appending($0.location.name, isDirectory: $0.isFolder)) },
                 move: move, mask: mask, cancel: cancel)
    }

    /// Each source goes to its own target (a new name: "copy as" / rename). `mask` keeps only the
    /// files it matches (and the folders holding them). A local folder moved on the same disk to a
    /// place where nothing is yet moves in one step.
    public static func plan(_ pairs: [(Source, TransferLocation)], move: Bool, mask: FileMask?,
                            cancel: CancelFlag? = nil) throws -> Plan {
        var plan = Plan()
        let keep: (String) -> Bool = { name in
            mask.map { $0.matches(FileEntry(name: name, url: URL(fileURLWithPath: "/" + name), kind: .file)) } ?? true
        }
        for (source, target) in pairs {
            if !source.isFolder {
                if keep(source.location.name) {
                    plan.items.append(TransferItem(source: source.location, destination: target, size: source.size, isFolder: false,
                                                   modified: source.modified))
                }
                continue
            }
            if move, mask == nil, case let .local(from) = source.location, case let .local(to) = target,
               !TransferManager.exists(to), sameVolume(from, to.deletingLastPathComponent()) {
                plan.items.append(TransferItem(source: source.location, destination: target, size: 0, isFolder: false,
                                               modified: source.modified, isWholeFolder: true))
                continue
            }
            var tree: [TransferItem] = [TransferItem(source: source.location, destination: target, size: 0, isFolder: true)]
            var removeLater: [TransferLocation] = [source.location]
            switch source.location {
            case .local(let root):
                // Walk the real path (e.g. /private/var/… for /var/…) so relative paths are cut correctly.
                let real = FileSystemLister.realPath(of: root)
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                let walker = FileManager.default.enumerator(at: real, includingPropertiesForKeys: keys)
                let prefix = real.path + "/"
                while let found = walker?.nextObject() as? URL {
                    if cancel?.isCancelled == true { throw FTPError.cancelled }
                    guard found.path.hasPrefix(prefix) else { continue }
                    let rel = String(found.path.dropFirst(prefix.count))
                    let v = try? found.resourceValues(forKeys: Set(keys))
                    let isDir = v?.isDirectory ?? false
                    let url = root.appendingPathComponent(rel, isDirectory: isDir)
                    tree.append(TransferItem(source: .local(url), destination: target.appending(rel, isDirectory: isDir),
                                             size: isDir ? 0 : Int64(v?.fileSize ?? 0), isFolder: isDir,
                                             modified: v?.contentModificationDate))
                    if isDir { removeLater.append(.local(url)) }
                }
            case let .remote(session, root):
                let walked = try session.walk(root, cancel: cancel)
                for folder in walked.folders {
                    let rel = String(folder.dropFirst(root.count + 1))
                    tree.append(TransferItem(source: .remote(session, folder), destination: target.appending(rel, isDirectory: true),
                                             size: 0, isFolder: true))
                    removeLater.append(.remote(session, folder))
                }
                for file in walked.files {
                    let rel = String(file.path.dropFirst(root.count + 1))
                    tree.append(TransferItem(source: .remote(session, file.path), destination: target.appending(rel),
                                             size: file.size, isFolder: false, modified: file.modified))
                }
            }
            if mask != nil {
                // Only matching files, and only the folders they end up in.
                tree = tree.filter { $0.isFolder || keep($0.source.name) }
                let filePaths = tree.filter { !$0.isFolder }.map { $0.destination.displayPath }
                tree = tree.filter { item in
                    !item.isFolder || filePaths.contains { $0.hasPrefix(item.destination.displayPath + "/") }
                }
            }
            plan.items += tree
            plan.foldersToRemove += removeLater.reversed()
        }
        plan.conflicts = try findConflicts(plan.items)
        for i in plan.conflicts { plan.items[i].conflict = true }
        return plan
    }

    /// Whether two local places are on the same volume (so a move is a rename).
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let va = (try? a.resourceValues(forKeys: [key]))?.volumeIdentifier as? NSObject,
              let vb = (try? b.resourceValues(forKeys: [key]))?.volumeIdentifier as? NSObject else { return false }
        return va.isEqual(vb)
    }

    /// Items whose destination file exists already (remote folders are listed once each).
    static func findConflicts(_ items: [TransferItem]) throws -> [Int] {
        var listings: [String: Set<String>] = [:]
        var result: [Int] = []
        // Servers are usually case-sensitive, Macs usually not: "A.txt" and "a.txt" would land on the
        // same local file, so the second one counts as a conflict too.
        var localTargets: Set<String> = []
        for (i, item) in items.enumerated() where !item.isFolder {
            switch item.destination {
            case .local(let url):
                let key = url.path.lowercased()
                if FileManager.default.fileExists(atPath: url.path) || localTargets.contains(key) { result.append(i) }
                localTargets.insert(key)
            case let .remote(session, path):
                let dir = (path as NSString).deletingLastPathComponent
                let key = session.id.uuidString + dir
                if listings[key] == nil {
                    listings[key] = Set(((try? session.fetch(dir, useCache: false)) ?? []).map(\.name))
                }
                if listings[key]!.contains((path as NSString).lastPathComponent) { result.append(i) }
            }
        }
        return result
    }
}
