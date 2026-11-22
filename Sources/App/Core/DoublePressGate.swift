import Foundation

/// Lets an action through only on the second press within `interval` (e.g. double ⌘Q to quit).
public struct DoublePressGate {
    public let interval: TimeInterval
    private var firstPress: Date?

    public init(interval: TimeInterval = 1.5) {
        self.interval = interval
    }

    /// Records a press; returns true when it completes a double press.
    public mutating func press(at now: Date = Date()) -> Bool {
        if let first = firstPress, now.timeIntervalSince(first) <= interval, now >= first {
            firstPress = nil
            return true
        }
        firstPress = now
        return false
    }
}
