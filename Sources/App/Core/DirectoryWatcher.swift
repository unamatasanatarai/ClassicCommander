import CoreServices
import Foundation

/// Options → Operation → "Refresh automatically".
public enum AutoRefresh: String, Codable, CaseIterable {
    case off
    /// Files are created, deleted or renamed.
    case structure
    /// …and also when sizes, dates or attributes change.
    case everything

    public var label: String {
        switch self {
        case .off: return "Off (2 or ⌃R refreshes)"
        case .structure: return "When files are created, deleted or renamed"
        case .everything: return "Also when size, date or attributes change"
        }
    }
}

/// Watches one folder (not its subfolders) with FSEvents and reports changes on the main thread,
/// a moment after they settle.
public final class DirectoryWatcher {
    public let folder: URL
    private let mode: AutoRefresh
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    public init?(folder: URL, mode: AutoRefresh, latency: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        guard mode != .off, folder.isFileURL else { return nil }
        // The real path (/private/var/… for /var/…): FSEvents reports real paths.
        self.folder = FileSystemLister.realPath(of: folder)
        self.mode = mode
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, Self.callback, &context, [self.folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    public func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info = info else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        watcher.handle(Array(zip(list, (0..<count).map { flags[$0] })))
    }

    /// Does any of these events concern an entry of the folder itself?
    func handle(_ events: [(String, FSEventStreamEventFlags)]) {
        if events.contains(where: { relevant($0.0, $0.1) }) { onChange() }
    }

    func relevant(_ path: String, _ flags: FSEventStreamEventFlags) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard parent == folder.path || path == folder.path else { return false }
        let structure = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMustScanSubDirs)
        if flags & structure != 0 { return true }
        let details = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod
                                              | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemXattrMod
                                              | kFSEventStreamEventFlagItemFinderInfoMod)
        return mode == .everything && flags & details != 0
    }
}
