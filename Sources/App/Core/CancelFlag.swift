import Foundation

/// A cancel switch shared between the main thread and background work (searches, sizes, transfers).
public final class CancelFlag {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}
