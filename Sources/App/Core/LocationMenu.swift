import Foundation

/// The ⌥1 / ⌥2 menu (Total Commander's Alt+F1 / Alt+F2): where the chosen panel can jump to.
///   1. the folder of the panel with the cursor
///   2. the home folder
///   3. the mounted drives
public struct LocationMenu: Equatable {
    public enum Item: Equatable {
        case cursorFolder(URL)
        case home(URL)
        case drive(name: String, url: URL, available: Int64?, total: Int64?)

        public var url: URL {
            switch self {
            case .cursorFolder(let u), .home(let u): return u
            case .drive(_, let u, _, _): return u
            }
        }
    }

    public let items: [Item]

    public init(cursorFolder: URL, home: URL, drives: [Item]) {
        items = [.cursorFolder(cursorFolder), .home(home)] + drives
    }

    public var drives: [Item] {
        items.filter { if case .drive = $0 { return true } else { return false } }
    }

    /// Menu title for an item, e.g. "Same as cursor panel: /Users/me", "[Macintosh HD]  80,8 G of 233,6 G free".
    public static func title(for item: Item, formatter: EntryFormatter = .shared) -> String {
        switch item {
        case .cursorFolder(let url):
            return "Same as cursor panel:  \(url.path)"
        case .home(let url):
            return "Home  ~  (\(url.path))"
        case let .drive(name, _, available, total):
            if let a = available, let t = total {
                return formatter.volume(VolumeInfo(name: name, available: a, total: t))
            }
            return "[\(name)]"
        }
    }

    /// The mounted, user-visible volumes, boot volume first.
    public static func mountedDrives() -> [Item] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let available = v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
            return .drive(name: v?.volumeLocalizedName ?? url.lastPathComponent, url: url,
                          available: available, total: v?.volumeTotalCapacity.map(Int64.init))
        }
        .sorted { a, b in a.url.path == "/" || (b.url.path != "/" && a.url.path < b.url.path) }
    }
}
