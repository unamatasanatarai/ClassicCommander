import Darwin
import Foundation

/// Copies one local file the way macOS does (copyfile(3)) and puts it in place atomically.
enum LocalCopy {
    /// Copies `src` to `dst`. The copy goes into a hidden temporary file next to `dst`, which is then
    /// renamed over it: `dst` is always either what was there before or the complete copy, never a part.
    /// Keeps extended attributes (Finder tags and info, quarantine, resource fork), ACLs, flags,
    /// permissions and dates; a symbolic link is copied as a link, holes in sparse files stay holes.
    /// `clone`: on APFS the copy shares the original's blocks (instant, no extra space) — no progress
    /// reports then, as there is nothing to wait for. Otherwise `progress` gets the bytes copied so far,
    /// and `cancel` and `isPaused` are checked as the data is copied. Returns the size of the copy.
    @discardableResult
    static func copy(from src: URL, to dst: URL, clone: Bool = true, cancel: CancelFlag?,
                     isPaused: @escaping () -> Bool = { false }, progress: ((Int64) -> Void)?) throws -> Int64 {
        if cancel?.isCancelled == true { throw FTPError.cancelled }
        let parent = dst.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".cc-copy-\(UUID().uuidString)")
        let monitor = CopyMonitor(cancel: cancel, isPaused: isPaused, progress: progress)
        do {
            try copyfile(src, to: temp, flags: flags(clone: clone), monitor: monitor)
            flushToDisk(temp)
            try replace(dst, with: temp)
        } catch {
            discard(temp)
            throw error
        }
        let size = lstatSize(dst)
        progress?(size)
        return size
    }

    /// Puts `temp` at `dst` in one step: rename(2) replaces an existing file atomically, so there is no
    /// moment without a `dst`. Only a folder in the way (which a rename can't replace) is removed first.
    /// A locked (uchg) file can't be renamed, so it is unlocked for the rename and locked again after.
    static func replace(_ dst: URL, with temp: URL) throws {
        var st = stat()
        let flags = lstat(temp.path, &st) == 0 ? st.st_flags : 0
        let locks = flags & UInt32(UF_IMMUTABLE | UF_APPEND)
        if locks != 0 { _ = lchflags(temp.path, flags & ~locks) }
        try renameOver(dst, with: temp)
        if locks != 0 { _ = lchflags(dst.path, flags) }
    }

    private static func renameOver(_ dst: URL, with temp: URL) throws {
        if rename(temp.path, dst.path) == 0 { return }
        let code = errno
        guard code == EISDIR || code == ENOTEMPTY || code == EEXIST else { throw posixError(code, dst) }
        try FileManager.default.removeItem(at: dst)
        guard rename(temp.path, dst.path) == 0 else { throw posixError(errno, dst) }
    }

    static func flags(clone: Bool) -> copyfile_flags_t {
        let base = COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL | COPYFILE_DATA_SPARSE
        return copyfile_flags_t(clone ? base | COPYFILE_CLONE : base)
    }

    private static func copyfile(_ src: URL, to temp: URL, flags: copyfile_flags_t, monitor: CopyMonitor) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyStatus, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(monitor).toOpaque())
        let result = withExtendedLifetime(monitor) { Darwin.copyfile(src.path, temp.path, state, flags) }
        guard result != 0 else { return }
        let code = errno
        if code == ECANCELED || monitor.cancel?.isCancelled == true { throw FTPError.cancelled }
        if code == ENOSPC || code == EDQUOT { throw FTPError.localDiskFull }
        throw posixError(code, src)
    }

    /// Writes the copy's data to the disk before it gets its name, so a crash can't leave an empty file
    /// under the real name. (A symbolic link has no data and can't be opened; it is skipped.)
    private static func flushToDisk(_ url: URL) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }

    /// Removes a temporary copy left by a failed or cancelled copy (unlocking it first if need be).
    private static func discard(_ url: URL) {
        _ = lchflags(url.path, 0)
        _ = unlink(url.path)
    }

    private static func lstatSize(_ url: URL) -> Int64 {
        var st = stat()
        return lstat(url.path, &st) == 0 ? Int64(st.st_size) : 0
    }

    static func posixError(_ code: Int32, _ url: URL) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}

/// What a copy in progress reports to and asks of: progress, pause and cancel.
private final class CopyMonitor {
    let cancel: CancelFlag?
    let isPaused: () -> Bool
    let progress: ((Int64) -> Void)?

    init(cancel: CancelFlag?, isPaused: @escaping () -> Bool, progress: ((Int64) -> Void)?) {
        self.cancel = cancel
        self.isPaused = isPaused
        self.progress = progress
    }

    /// Called by copyfile at each step; answers whether to go on.
    func status(what: Int32, stage: Int32, state: copyfile_state_t?) -> Int32 {
        if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 { progress?(Int64(copied)) }
        }
        while isPaused() && cancel?.isCancelled != true { Thread.sleep(forTimeInterval: 0.1) }
        return cancel?.isCancelled == true ? COPYFILE_QUIT : COPYFILE_CONTINUE
    }
}

/// copyfile's status callback (a C function: it finds the copy's monitor through the context pointer).
private let copyStatus: copyfile_callback_t = { what, stage, state, _, _, context in
    guard let context = context else { return COPYFILE_CONTINUE }
    return Unmanaged<CopyMonitor>.fromOpaque(context).takeUnretainedValue().status(what: what, stage: stage, state: state)
}
