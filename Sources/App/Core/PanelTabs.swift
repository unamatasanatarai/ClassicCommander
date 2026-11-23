import Foundation

/// When the tab bar above a panel is shown (Options → Display).
public enum TabBarMode: String, Codable, CaseIterable {
    case whenSeveral, always

    public var label: String { self == .whenSeveral ? "Only with two or more tabs" : "Always" }
}

/// The tabs of one panel: the folder each shows and which one is active. There is always at
/// least one; the active tab's folder is the one the panel shows.
public struct PanelTabs: Equatable {
    public struct Tab: Equatable {
        public var folder: URL
        /// The entry the cursor was on when the tab was left.
        public var focus: String?

        public init(folder: URL, focus: String? = nil) {
            self.folder = folder
            self.focus = focus
        }

        /// "Documents", "/" for the root, or the server's folder name.
        public var title: String {
            folder.path == "/" || folder.lastPathComponent.isEmpty ? "/" : folder.lastPathComponent
        }
    }

    public private(set) var tabs: [Tab]
    public private(set) var active: Int

    public init(folder: URL) {
        tabs = [Tab(folder: folder)]
        active = 0
    }

    /// Restores saved tabs (folders that are gone are left out; at least one tab remains).
    public init(saved paths: [String], active: Int, fallback: URL) {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        tabs = existing.isEmpty ? [Tab(folder: fallback)] : existing.map { Tab(folder: URL(fileURLWithPath: $0, isDirectory: true)) }
        self.active = min(max(0, active), tabs.count - 1)
    }

    public var current: Tab { tabs[active] }
    public var count: Int { tabs.count }

    /// The panel moved to another folder: the active tab follows.
    public mutating func update(folder: URL, focus: String?) {
        tabs[active].folder = folder
        tabs[active].focus = focus
    }

    /// A new tab after the active one, on the same folder, made active.
    public mutating func add(folder: URL, focus: String?) {
        tabs.insert(Tab(folder: folder, focus: focus), at: active + 1)
        active += 1
    }

    /// Closes a tab (never the last one). Returns whether the active tab changed.
    @discardableResult
    public mutating func close(_ index: Int) -> Bool {
        guard tabs.count > 1, tabs.indices.contains(index) else { return false }
        tabs.remove(at: index)
        let changed = index == active
        if index < active || active >= tabs.count { active -= 1 }
        return changed
    }

    public mutating func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        active = index
    }

    /// The tab after (or before) the active one, wrapping around.
    public func neighbour(_ step: Int) -> Int {
        ((active + step) % tabs.count + tabs.count) % tabs.count
    }

    /// Folders on this Mac and the active one among them, for saving (server folders can't be
    /// reopened at the next launch).
    public var saved: (paths: [String], active: Int) {
        let local = tabs.indices.filter { tabs[$0].folder.isFileURL }
        let active = local.firstIndex(of: self.active) ?? local.lastIndex { $0 < self.active } ?? 0
        return (local.map { tabs[$0].folder.path }, active)
    }
}
