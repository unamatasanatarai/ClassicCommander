import Foundation

/// Outcome of a delete or another operation done in one go.
public struct OperationReport: Equatable {
    public var done = 0
    public var skipped = 0
    public var errors: [String] = []
    public var cancelled = false
}

/// Where Copy (5) and Move/Rename (6) put things, Total Commander style:
/// - the target is a folder (items go inside it) or, for a single item, a new path (rename/copy-as);
/// - several items into a folder that does not exist yet create it.
/// The copying itself runs in the queue (TransferManager).
public enum TransferTarget {
    /// Pairs each source with its destination for the text typed in the dialog.
    /// A relative `target` is taken relative to `base` (the source panel's folder); "~" is home.
    public static func plan(sources: [URL], target: String, base: URL) -> (pairs: [(URL, URL)], createFolder: URL?) {
        var text = target.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("*.*") { text.removeLast(3) }
        let expanded = (text as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
        let dest = url.standardizedFileURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir)
        if (exists && isDir.boolValue) || text.hasSuffix("/") || sources.count > 1 {
            let create = exists ? nil : dest
            return (sources.map { ($0, dest.appendingPathComponent($0.lastPathComponent)) }, create)
        }
        return (sources.map { ($0, dest) }, nil)
    }

    /// Why a pair can't be done (copying onto itself or into itself), or nil.
    public static func problem(_ source: URL, _ destination: URL, move: Bool) -> String? {
        let s = source.standardizedFileURL.path, d = destination.standardizedFileURL.path
        if s == d { return "\(source.lastPathComponent): source and target are the same" }
        if d.hasPrefix(s + "/") { return "\(source.lastPathComponent): cannot \(move ? "move" : "copy") a folder into itself" }
        return nil
    }
}

/// What the Copy / Move dialog asks.
public struct TransferQuestion {
    public let verb: String
    public let message: String
    public let defaultTarget: String
    /// Counts what would be copied with a "files of type" mask (nil: all), in the background.
    public let count: (FileMask?, CancelFlag) -> TransferStats
}

/// What the Copy / Move dialog answered.
public struct TransferAnswer: Equatable {
    public var target: String
    /// "Only files of type" (empty: all files).
    public var mask: String = ""
    public var verify = false
    /// ⌃2 Queue: wait for the queued jobs before it instead of starting now.
    public var queue = false

    public init(target: String, mask: String = "", verify: Bool = false, queue: Bool = false) {
        self.target = target
        self.mask = mask
        self.verify = verify
        self.queue = queue
    }

    public var fileMask: FileMask? { mask.trimmingCharacters(in: .whitespaces).isEmpty ? nil : FileMask(mask) }
}

/// Files, folders and bytes a copy would take (shown in the Copy / Move dialog).
public struct TransferStats: Equatable {
    public var files = 0
    public var folders = 0
    public var bytes: Int64 = 0
    /// false when folders on a server weren't looked into (their contents aren't counted).
    public var complete = true

    /// Counts entries of a panel: local folders are walked; server folders only counted.
    public static func count(_ entries: [FileEntry], mask: FileMask?, cancel: CancelFlag) -> TransferStats {
        var stats = TransferStats()
        func file(_ name: String, _ size: Int64) {
            guard mask.map({ $0.matches(FileEntry(name: name, url: URL(fileURLWithPath: "/" + name), kind: .file)) }) ?? true else { return }
            stats.files += 1
            stats.bytes = stats.bytes.addingSaturated(size)
        }
        for entry in entries where !cancel.isCancelled {
            if entry.kind == .file { file(entry.name, entry.size ?? 0); continue }
            stats.folders += 1
            guard entry.url.isFileURL else { stats.complete = false; continue }
            let walker = FileManager.default.enumerator(at: entry.url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
            while let url = walker?.nextObject() as? URL, !cancel.isCancelled {
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if v?.isDirectory == true { stats.folders += 1 } else { file(url.lastPathComponent, Int64(v?.fileSize ?? 0)) }
            }
        }
        return stats
    }
}

public enum FileCommandsCore {
    /// F8: moves items to the Trash (recoverable), never deletes outright.
    public static func trash(_ urls: [URL]) -> OperationReport {
        var report = OperationReport()
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                report.done += 1
            } catch {
                report.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// ⇧8: deletes items for good (no Trash).
    public static func remove(_ urls: [URL]) -> OperationReport {
        var report = OperationReport()
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
                report.done += 1
            } catch {
                report.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// F7: creates a folder (a path like "a/b/c" creates all of them). Returns the first new component's name.
    public static func makeFolder(named name: String, in directory: URL) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let url = directory.appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return trimmed.split(separator: "/").first.map(String.init) ?? trimmed
    }
}
