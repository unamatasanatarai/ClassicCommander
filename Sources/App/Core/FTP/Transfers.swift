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
    /// The files and folders of the job (fixed once the job is made).
    public let items: [TransferItem]
    /// Folders to remove after a successful move (deepest first).
    let sourceFoldersToRemove: [TransferLocation]
    /// Resume partially transferred files (used by Retry).
    let resume: Bool

    // MARK: Live state
    //
    // Transfer threads change these while the windows read them on the main thread (many times a
    // second during a large copy). Unsynchronized, a read of a dictionary or set in the middle of a
    // write crashes the app, so every one goes through `liveLock`: reads take a copy, and changes in
    // place (`job.partial[i] = n`, `job.running -= 1`, `job.active.insert(i)`) are atomic.

    private struct Live {
        var active: Set<Int> = []
        var isHeld = false
        var conflictRule: ConflictDecision?
        var results: [TransferItemResult]
        var isPaused = false
        var state: State = .queued
        var running = 0
        var completedBytes: Int64 = 0
        var skippedBytes: Int64 = 0
        var partial: [Int: Int64] = [:]
        var started: Date?
        var finished: Date?
    }
    private var live: Live
    /// Recursive: a getter used inside a change (`job.x = job.y + 1`) never waits on itself.
    private let liveLock = NSRecursiveLock()

    private func read<T>(_ body: (Live) -> T) -> T {
        liveLock.lock(); defer { liveLock.unlock() }
        return body(live)
    }

    /// Files being copied right now.
    public internal(set) var active: Set<Int> {
        get { read(\.active) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.active }
    }
    /// Held back in the queue until the queued job before it is done.
    var isHeld: Bool {
        get { read(\.isHeld) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.isHeld }
    }
    /// "Replace all", "Skip all" or "Replace all older", once answered for this job.
    var conflictRule: ConflictDecision? {
        get { read(\.conflictRule) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.conflictRule }
    }
    public internal(set) var results: [TransferItemResult] {
        get { read(\.results) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.results }
    }
    public var isPaused: Bool {
        get { read(\.isPaused) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.isPaused }
    }
    public internal(set) var state: State {
        get { read(\.state) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.state }
    }
    /// Files of this job transferring right now.
    public internal(set) var running: Int {
        get { read(\.running) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.running }
    }
    /// Bytes of finished files.
    var completedBytes: Int64 {
        get { read(\.completedBytes) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.completedBytes }
    }
    /// Bytes of files skipped during transfer.
    public internal(set) var skippedBytes: Int64 {
        get { read(\.skippedBytes) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.skippedBytes }
    }
    /// Bytes so far of each file in progress (by item index).
    var partial: [Int: Int64] {
        get { read(\.partial) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.partial }
    }
    public internal(set) var started: Date? {
        get { read(\.started) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.started }
    }
    public internal(set) var finished: Date? {
        get { read(\.finished) }
        _modify { liveLock.lock(); defer { liveLock.unlock() }; yield &live.finished }
    }

    /// Bytes of finished files and of the files in progress (one consistent reading).
    public var bytesDone: Int64 { read { $0.partial.values.reduce($0.completedBytes) { $0.addingSaturated($1) } } }
    /// Total bytes accounted for (transferred + in-progress + skipped).
    public var bytesProcessed: Int64 { read { l in l.partial.values.reduce(l.completedBytes) { $0.addingSaturated($1) }.addingSaturated(l.skippedBytes) } }
    let cancelFlag = CancelFlag()

    public init(title: String, items: [TransferItem], isMove: Bool, sourceFoldersToRemove: [TransferLocation] = [], resume: Bool = false) {
        self.title = title
        self.items = items
        self.isMove = isMove
        self.sourceFoldersToRemove = sourceFoldersToRemove
        self.resume = resume
        live = Live(results: Array(repeating: .pending, count: items.count))
    }

    public var bytesTotal: Int64 { items.reduce(0) { $0.addingSaturated($1.size) } }
    public var failedCount: Int { results.filter { if case .failed = $0 { return true } else { return false } }.count }
    public var doneCount: Int { results.filter { $0 == .done }.count }
    public var skippedCount: Int { results.filter { if case .skipped = $0 { return true } else { return false } }.count }
    public var processedCount: Int { results.filter { $0 != .pending }.count }
    public var fileCount: Int { items.filter { !$0.isFolder }.count }

    public var elapsed: TimeInterval { (finished ?? Date()).timeIntervalSince(started ?? Date()) }
    /// Bytes per second since the start.
    public var speed: Double { elapsed > 0.2 ? Double(bytesDone) / elapsed : 0 }

    /// "Done", "3 failed", "Cancelled", "Running 4 of 10", "Queued".
    public var statusText: String {
        if state == .queued { return waitsInQueue ? "Waiting in the queue" : "Queued" }
        return nonQueuedStatusText
    }

    private var nonQueuedStatusText: String {
        switch state {
        case .running, .finishing: return runningStatusText
        case .cancelled: return cancelledStatusText
        default: return finishedStatusText
        }
    }

    private var cancelledStatusText: String {
        let skipped = skippedCount > 0 ? ", \(skippedCount) skipped" : ""
        return "Cancelled (\(doneCount) done\(skipped))"
    }

    private var runningStatusText: String {
        if cancelFlag.isCancelled { return "Cancelling…" }
        let skipped = skippedCount > 0 ? " · \(skippedCount) skipped" : ""
        return "Copying \(running) at once · \(processedCount) of \(items.count) done\(skipped)"
    }

    private var finishedStatusText: String {
        let skipped = skippedCount > 0 ? " · \(skippedCount) skipped" : ""
        if failedCount == 0 {
            return "Done (\(processedCount) of \(items.count)\(skipped))"
        }
        return "\(failedCount) failed, \(doneCount) done\(skipped)"
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
/// locals: maximum concurrent local-to-local disk transfers (default: 1, strictly sequential).
public struct TransferLimits: Equatable {
    public var total: Int
    public var uploads: Int
    public var downloads: Int
    public var locals: Int

    public init(total: Int = 3, uploads: Int = 0, downloads: Int = 0, locals: Int = 1) {
        self.total = max(1, total)
        self.uploads = max(0, uploads)
        self.downloads = max(0, downloads)
        self.locals = max(1, locals)
    }

    public var effectiveUploads: Int { uploads == 0 ? total : min(uploads, total) }
    public var effectiveDownloads: Int { downloads == 0 ? total : min(downloads, total) }
    public var effectiveLocals: Int { min(locals, total) }

    /// Whether one more transfer of this kind may start next to the running ones.
    func allows(_ kind: TransferKind, running: (total: Int, up: Int, down: Int, local: Int)) -> Bool {
        running.total < total && allowsByKind(kind, running: running)
    }

    private func allowsByKind(_ kind: TransferKind, running: (total: Int, up: Int, down: Int, local: Int)) -> Bool {
        (!kind.isLocal || running.local < effectiveLocals)
            && (!kind.isUpload || running.up < effectiveUploads)
            && (!kind.isDownload || running.down < effectiveDownloads)
    }
}

/// What a file transfer does on the network or locally (server to server is both).
struct TransferKind {
    let isUpload: Bool
    let isDownload: Bool
    let isLocal: Bool

    init(_ item: TransferItem) {
        var up = false, down = false
        if case .remote = item.source { down = true }
        if case .remote = item.destination { up = true }
        isUpload = up
        isDownload = down
        isLocal = !up && !down
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
    /// Local copies on APFS share the original's blocks (instant). Off: the data is always copied.
    var cloneLocalCopies = true
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
    private var running: (total: Int, up: Int, down: Int, local: Int) = (0, 0, 0, 0)
    /// Highest number of files that ran at once (for tests and diagnostics).
    public private(set) var peakConcurrency = 0
    public private(set) var peakUploads = 0
    public private(set) var peakDownloads = 0
    public private(set) var peakLocals = 0

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
        guard let job = claimNextQueuedJob() else { return }
        if runSynchronously { runSerially(job); return }
        workers.async { [weak self] in self?.start(job) }
    }

    private func claimNextQueuedJob() -> TransferJob? {
        lock.lock()
        defer { lock.unlock() }
        let busy = jobs.contains { $0.waitsInQueue && !$0.isHeld && Self.isUnfinished($0) }
        guard !busy, let next = jobs.first(where: { $0.isHeld && $0.state == .queued }) else { return nil }
        next.isHeld = false
        return next
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
        guard beginJob(job) else { return }
        notify(job)
        createFolders(for: job)
        lock.lock()
        waiting += job.items.indices.filter { !job.items[$0].isFolder }.map { (job, $0) }
        lock.unlock()
        schedule()
        finishIfDone(job)
    }

    private func beginJob(_ job: TransferJob) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Cancelled before it got going: it stays cancelled.
        guard job.state != .cancelled else { return false }
        job.state = .running
        job.started = Date()
        return true
    }

    private func createFolders(for job: TransferJob) {
        for (i, item) in job.items.enumerated() where item.isFolder && !job.cancelFlag.isCancelled {
            performFolderItem(item, at: i, job: job)
        }
    }

    private func performFolderItem(_ item: TransferItem, at index: Int, job: TransferJob) {
        let result: TransferItemResult
        do { try perform(item, job: job) { _ in }; result = .done } catch { result = Self.result(for: error) }
        lock.lock(); job.results[index] = result; lock.unlock()
    }

    private func recordStart(kind: TransferKind, job: TransferJob) {
        running.total += 1
        if kind.isUpload { running.up += 1 }
        if kind.isDownload { running.down += 1 }
        if kind.isLocal { running.local += 1 }
        peakConcurrency = max(peakConcurrency, running.total)
        peakUploads = max(peakUploads, running.up)
        peakDownloads = max(peakDownloads, running.down)
        peakLocals = max(peakLocals, running.local)
        job.running += 1
    }

    /// Starts as many waiting files as the limits allow.
    private func schedule() {
        guard !runSynchronously else { return }
        lock.lock()
        let (starting, dropped) = drainWaitingQueue()
        lock.unlock()
        for (job, index) in starting {
            workers.async { [weak self] in self?.transfer(job, index) }
        }
        // Jobs whose remaining files were dropped by Cancel may be finished now.
        for job in dropped { finishIfDone(job) }
    }

    private func drainWaitingQueue() -> ([(TransferJob, Int)], [TransferJob]) {
        var starting: [(TransferJob, Int)] = []
        var dropped: [TransferJob] = []
        var i = 0
        while i < waiting.count {
            let (job, index) = waiting[i]
            if job.cancelFlag.isCancelled {
                waiting.remove(at: i)
                recordDropped(job, into: &dropped)
            } else if tryStartWaitingItem(at: i, job: job, index: index, starting: &starting) {
                continue
            } else {
                i += 1
            }
        }
        return (starting, dropped)
    }

    private func recordDropped(_ job: TransferJob, into dropped: inout [TransferJob]) {
        if !dropped.contains(where: { $0 === job }) { dropped.append(job) }
    }

    private func tryStartWaitingItem(
        at i: Int, job: TransferJob, index: Int, starting: inout [(TransferJob, Int)]
    ) -> Bool {
        let kind = TransferKind(job.items[index])
        guard limits.allows(kind, running: running) else { return false }
        waiting.remove(at: i)
        recordStart(kind: kind, job: job)
        starting.append((job, index))
        return true
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
        notify(job)
    }

    /// Transfers one file on a worker thread, then lets the next waiting files start.
    private func executeItem(_ item: TransferItem, job: TransferJob, index: Int) -> TransferItemResult {
        guard !job.cancelFlag.isCancelled else { return .pending }
        waitWhilePaused(job)
        lock.lock(); job.active.insert(index); lock.unlock()
        notify(job)
        return performItemWithRetries(item, job: job, index: index)
    }

    private func performItemWithRetries(_ item: TransferItem, job: TransferJob, index: Int) -> TransferItemResult {
        var lastNotify = Date.distantPast
        do {
            try perform(item, job: job) { [weak self] partial in
                self?.recordPartial(partial, job: job, index: index, lastNotify: &lastNotify)
            }
            return .done
        } catch FTPError.cancelled {
            return .pending
        } catch {
            return Self.result(for: error)
        }
    }

    private func recordPartial(_ partial: Int64, job: TransferJob, index: Int, lastNotify: inout Date) {
        lock.lock(); job.partial[index] = partial; lock.unlock()
        if Date().timeIntervalSince(lastNotify) > 0.25 {
            lastNotify = Date()
            notify(job)
        }
    }

    private func waitWhilePaused(_ job: TransferJob) {
        while job.isPaused && !job.cancelFlag.isCancelled {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func transfer(_ job: TransferJob, _ index: Int) {
        let item = job.items[index]
        let kind = TransferKind(item)
        let result = executeItem(item, job: job, index: index)
        finishItemTransfer(job: job, index: index, item: item, kind: kind, result: result)
        notify(job)
        schedule()
        finishIfDone(job)
    }

    private func finishItemTransfer(
        job: TransferJob, index: Int, item: TransferItem, kind: TransferKind, result: TransferItemResult
    ) {
        lock.lock()
        defer { lock.unlock() }
        job.active.remove(index)
        job.partial[index] = nil
        job.results[index] = result
        recordCompletedBytes(item: item, result: result, on: job)
        job.running -= 1
        decrementRunning(kind: kind)
    }

    private func recordCompletedBytes(item: TransferItem, result: TransferItemResult, on job: TransferJob) {
        if result == .done { job.completedBytes = job.completedBytes.addingSaturated(item.size) }
        else if case .skipped = result { job.skippedBytes = job.skippedBytes.addingSaturated(item.size) }
    }

    private func decrementRunning(kind: TransferKind) {
        running.total -= 1
        if kind.isUpload { running.up -= 1 }
        if kind.isDownload { running.down -= 1 }
        if kind.isLocal { running.local -= 1 }
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
        cleanupMovedSourceFolders(for: job)
        lock.lock()
        job.finished = Date()
        job.state = job.cancelFlag.isCancelled ? .cancelled : .finished
        lock.unlock()
        notify(job)
        if job.waitsInQueue { startNextInQueue() }
    }

    private func cleanupMovedSourceFolders(for job: TransferJob) {
        guard job.isMove && !job.cancelFlag.isCancelled && job.failedCount == 0 else { return }
        for folder in job.sourceFoldersToRemove { removeFolder(folder) }
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
            if !runSerialItem(item, index: i, job: job) { break }
        }
        job.state = .running
        job.running = 0
        complete(job)
    }

    private func runSerialItem(_ item: TransferItem, index i: Int, job: TransferJob) -> Bool {
        job.active.insert(i)
        defer { job.active.remove(i); job.partial[i] = nil }
        do {
            try perform(item, job: job) { partial in job.partial[i] = partial }
            job.results[i] = .done
            job.completedBytes = job.completedBytes.addingSaturated(item.size)
            return true
        } catch FTPError.cancelled {
            return false
        } catch {
            let res = Self.result(for: error)
            job.results[i] = res
            if case .skipped = res { job.skippedBytes = job.skippedBytes.addingSaturated(item.size) }
            return true
        }
    }

    /// Copies one item; for moves, deletes the source only after the copy was verified.
    private func perform(_ item: TransferItem, job: TransferJob, progress: @escaping (Int64) -> Void) throws {
        if item.isFolder {
            try createFolder(at: item.destination)
            progress(0)   // folders carry no bytes
            return
        }
        // An existing target: ask (or follow an earlier "… all"); Skip and Cancel end here.
        guard let destination = try settle(item, job: job) else { throw TransferSkipped() }
        try transferFile(item, to: destination, job: job, progress: progress)
        if job.verify { try verify(item, at: destination) }
        if job.isMove { try deleteSource(item.source) }
    }

    private func transferFile(
        _ item: TransferItem, to destination: TransferLocation, job: TransferJob, progress: @escaping (Int64) -> Void
    ) throws {
        let cancel = job.cancelFlag
        switch (item.source, destination) {
        case let (.local(url), .remote(session, path)):
            try session.client.upload(url, to: path, resume: job.resume, cancel: cancel, progress: progress)
            session.invalidate((path as NSString).deletingLastPathComponent)
        case let (.remote(session, path), .local(url)):
            try session.client.download(path, to: url, expectedSize: item.size, resume: job.resume, cancel: cancel, progress: progress)
        case let (.remote(from, path), .remote(to, target)):
            try performRemoteToRemote(from: from, path: path, to: to, target: target, item: item, job: job, progress: progress)
        case let (.local(src), .local(dst)):
            try performLocalToLocal(from: src, to: dst, item: item, job: job, progress: progress)
        }
    }

    private func createFolder(at destination: TransferLocation) throws {
        switch destination {
        case .local(let url):
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        case let .remote(session, path):
            try createRemoteFolder(path, session: session)
            session.invalidate((path as NSString).deletingLastPathComponent)
        }
    }

    private func createRemoteFolder(_ path: String, session: RemoteSession) throws {
        do { try session.client.makeDirectory(path) } catch {
            // An existing folder is fine. Missing parents are created (FTP's MKD makes one level).
            guard (try? session.client.list(path, cancel: nil)) == nil else { return }
            try createRemoteParentsAndTarget(path, session: session)
        }
    }

    private func createRemoteParentsAndTarget(_ path: String, session: RemoteSession) throws {
        var parent = ""
        for part in path.split(separator: "/").dropLast() {
            parent += "/" + part
            try? session.client.makeDirectory(parent)
        }
        do { try session.client.makeDirectory(path) } catch {
            if (try? session.client.list(path, cancel: nil)) == nil { throw error }
        }
    }

    private func performRemoteToRemote(
        from: RemoteSession, path: String, to: RemoteSession, target: String,
        item: TransferItem, job: TransferJob, progress: @escaping (Int64) -> Void
    ) throws {
        if from.id == to.id && job.isMove {
            try to.client.rename(path, to: target)
            to.invalidate((target as NSString).deletingLastPathComponent)
            from.invalidate((path as NSString).deletingLastPathComponent)
            progress(item.size)
            return
        }
        // Server to server goes through a temporary file on this Mac.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cc-ftp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try from.client.download(path, to: temp, expectedSize: item.size, resume: false, cancel: job.cancelFlag) { progress($0 / 2) }
        try to.client.upload(temp, to: target, resume: false, cancel: job.cancelFlag) { progress(item.size / 2 + $0 / 2) }
        to.invalidate((target as NSString).deletingLastPathComponent)
    }

    private func performLocalToLocal(
        from src: URL, to dst: URL, item: TransferItem, job: TransferJob, progress: @escaping (Int64) -> Void
    ) throws {
        if try tryDirectLocalMove(from: src, to: dst, item: item, job: job) {
            progress(item.size)
            return
        }
        try LocalCopy.copy(from: src, to: dst, clone: cloneLocalCopies, cancel: job.cancelFlag,
                           isPaused: { job.isPaused }, progress: progress)
        progress(item.size)
    }

    private func tryDirectLocalMove(from src: URL, to dst: URL, item: TransferItem, job: TransferJob) throws -> Bool {
        guard canDirectLocalMove(from: src, to: dst, item: item, job: job) else { return false }
        return try replaceAndMoveLocal(from: src, to: dst, isWholeFolder: item.isWholeFolder)
    }

    private func replaceAndMoveLocal(from src: URL, to dst: URL, isWholeFolder: Bool) throws -> Bool {
        do {
            try Self.removeExistingDestination(dst)
            try FileManager.default.moveItem(at: src, to: dst)
            return true
        } catch {
            return try Self.handleDirectMoveError(error, isWholeFolder: isWholeFolder)
        }
    }

    private static func handleDirectMoveError(_ error: Error, isWholeFolder: Bool) throws -> Bool {
        if isWholeFolder { throw error }
        return false
    }

    private static func removeExistingDestination(_ dst: URL) throws {
        if exists(dst) { try FileManager.default.removeItem(at: dst) }
    }

    private func canDirectLocalMove(from src: URL, to dst: URL, item: TransferItem, job: TransferJob) -> Bool {
        job.isMove && (item.isWholeFolder || (!job.verify && Self.isSameVolume(src, dst)))
    }

    private static func isSameVolume(_ src: URL, _ dst: URL) -> Bool {
        let r1 = try? src.resourceValues(forKeys: [.volumeIdentifierKey])
        let r2 = try? dst.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey])
        guard let v1 = r1?.volumeIdentifier, let v2 = r2?.volumeIdentifier else { return false }
        return (v1 as AnyObject).isEqual(v2)
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
            let decision = decide(TransferConflict(source: item.source, target: target, sourceSize: item.size,
                                                   sourceDate: item.modified, targetSize: found.size, targetDate: found.date), job: job)
            if case .rename(let name) = decision {
                target = target.sibling(named: name)
                check = true
                continue
            }
            return try applySettleDecision(decision, target: target, foundDate: found.date, itemModified: item.modified, job: job)
        }
        return target
    }

    private func applySettleDecision(
        _ decision: ConflictDecision, target: TransferLocation, foundDate: Date?, itemModified: Date?, job: TransferJob
    ) throws -> TransferLocation? {
        switch decision {
        case .skip, .skipAll:
            return nil
        case .cancel:
            job.cancel()
            throw FTPError.cancelled
        case .replaceAllOlder:
            return Self.isTargetOlder(foundDate, than: itemModified) ? target : nil
        default:
            return target
        }
    }

    private static func isTargetOlder(_ foundDate: Date?, than itemModified: Date?) -> Bool {
        (foundDate ?? .distantPast) < (itemModified ?? .distantFuture)
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
        case let (.local(src), .local(dst)): ok = verifyLocalCopy(src: src, dst: dst, size: item.size)
        case (_, .local(let dst)): ok = (try? FileComparison.fileSize(dst)) == item.size
        case (_, .remote): ok = Self.existing(destination)?.size == item.size
        }
        if !ok { throw FTPError.verificationFailed("the copy differs from \(item.source.displayPath)") }
    }

    private func verifyLocalCopy(src: URL, dst: URL, size: Int64) -> Bool {
        guard Self.exists(src) else { return Self.verifyMissingSourceCopy(dst: dst, size: size) }
        // A symbolic link is copied as a link: the copy must point where the original points.
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: src.path) {
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: dst.path)) == link
        }
        do {
            return try FileComparison.fileSize(src) == FileComparison.fileSize(dst) && FileComparison.firstDifference(src, dst) == nil
        } catch {
            return false
        }
    }

    private static func verifyMissingSourceCopy(dst: URL, size: Int64) -> Bool {
        exists(dst) && (try? FileComparison.fileSize(dst)) == size
    }

    private func deleteSource(_ location: TransferLocation) throws {
        switch location {
        case .local(let url):
            guard Self.exists(url) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw FTPError.invalid("File was copied, but original could not be deleted: \(url.lastPathComponent) (\(error.localizedDescription))")
            }
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
            try appendPlannedPair(source: source, target: target, move: move, mask: mask, keep: keep, cancel: cancel, into: &plan)
        }
        plan.conflicts = try findConflicts(plan.items)
        for i in plan.conflicts { plan.items[i].conflict = true }
        return plan
    }

    private static func appendPlannedPair(
        source: Source, target: TransferLocation, move: Bool, mask: FileMask?,
        keep: (String) -> Bool, cancel: CancelFlag?, into plan: inout Plan
    ) throws {
        if !source.isFolder {
            if keep(source.location.name) {
                plan.items.append(TransferItem(source: source.location, destination: target, size: source.size, isFolder: false,
                                               modified: source.modified))
            }
            return
        }
        if isWholeFolderMove(source: source, target: target, move: move, mask: mask) {
            plan.items.append(TransferItem(source: source.location, destination: target, size: 0, isFolder: false,
                                           modified: source.modified, isWholeFolder: true))
            return
        }
        var (tree, removeLater) = try walkFolderTree(sourceLocation: source.location, target: target, cancel: cancel)
        if mask != nil { tree = filterTree(tree, keep: keep) }
        plan.items += tree
        plan.foldersToRemove += removeLater.reversed()
    }

    private static func isWholeFolderMove(source: Source, target: TransferLocation, move: Bool, mask: FileMask?) -> Bool {
        guard move, mask == nil, case let .local(from) = source.location, case let .local(to) = target else { return false }
        return !TransferManager.exists(to) && sameVolume(from, to.deletingLastPathComponent())
    }

    private static func filterTree(_ tree: [TransferItem], keep: (String) -> Bool) -> [TransferItem] {
        // Only matching files, and only the folders they end up in.
        let matching = tree.filter { $0.isFolder || keep($0.source.name) }
        let filePaths = matching.filter { !$0.isFolder }.map { $0.destination.displayPath }
        return matching.filter { item in
            !item.isFolder || filePaths.contains { $0.hasPrefix(item.destination.displayPath + "/") }
        }
    }

    private static func walkFolderTree(
        sourceLocation: TransferLocation,
        target: TransferLocation,
        cancel: CancelFlag?
    ) throws -> (tree: [TransferItem], removeLater: [TransferLocation]) {
        var tree: [TransferItem] = [TransferItem(source: sourceLocation, destination: target, size: 0, isFolder: true)]
        var removeLater: [TransferLocation] = [sourceLocation]
        switch sourceLocation {
        case .local(let root):
            try walkLocalTree(root: root, target: target, cancel: cancel, tree: &tree, removeLater: &removeLater)
        case let .remote(session, root):
            try walkRemoteTree(session: session, root: root, target: target, cancel: cancel, tree: &tree, removeLater: &removeLater)
        }
        return (tree, removeLater)
    }

    private static func walkLocalTree(
        root: URL, target: TransferLocation, cancel: CancelFlag?,
        tree: inout [TransferItem], removeLater: inout [TransferLocation]
    ) throws {
        // Walk the real path (e.g. /private/var/… for /var/…) so relative paths are cut correctly.
        let real = FileSystemLister.realPath(of: root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let walker = FileManager.default.enumerator(at: real, includingPropertiesForKeys: keys)
        let prefix = real.path + "/"
        while let found = walker?.nextObject() as? URL {
            if cancel?.isCancelled == true { throw FTPError.cancelled }
            guard found.path.hasPrefix(prefix) else { continue }
            let item = localTransferItem(found: found, root: root, prefix: prefix, target: target, keys: keys)
            tree.append(item)
            if item.isFolder { removeLater.append(item.source) }
        }
    }

    private static func localTransferItem(
        found: URL, root: URL, prefix: String, target: TransferLocation, keys: [URLResourceKey]
    ) -> TransferItem {
        let rel = String(found.path.dropFirst(prefix.count))
        let v = try? found.resourceValues(forKeys: Set(keys))
        let isDir = v?.isDirectory ?? false
        let isLink = v?.isSymbolicLink ?? false   // a link is one item of its own (never entered), without data
        let url = root.appendingPathComponent(rel, isDirectory: isDir)
        return TransferItem(source: .local(url), destination: target.appending(rel, isDirectory: isDir),
                            size: isDir || isLink ? 0 : Int64(v?.fileSize ?? 0), isFolder: isDir,
                            modified: v?.contentModificationDate)
    }

    private static func walkRemoteTree(
        session: RemoteSession, root: String, target: TransferLocation, cancel: CancelFlag?,
        tree: inout [TransferItem], removeLater: inout [TransferLocation]
    ) throws {
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
                if hasLocalConflict(url, seen: &localTargets) { result.append(i) }
            case let .remote(session, path):
                if hasRemoteConflict(session: session, path: path, listings: &listings) { result.append(i) }
            }
        }
        return result
    }

    private static func hasLocalConflict(_ url: URL, seen localTargets: inout Set<String>) -> Bool {
        let key = url.path.lowercased()
        let conflict = FileManager.default.fileExists(atPath: url.path) || localTargets.contains(key)
        localTargets.insert(key)
        return conflict
    }

    private static func hasRemoteConflict(session: RemoteSession, path: String, listings: inout [String: Set<String>]) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        let key = session.id.uuidString + dir
        if listings[key] == nil {
            listings[key] = Set(((try? session.fetch(dir, useCache: false)) ?? []).map(\.name))
        }
        return listings[key]!.contains((path as NSString).lastPathComponent)
    }
}
