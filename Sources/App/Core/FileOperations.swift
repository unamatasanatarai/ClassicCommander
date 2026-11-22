import Foundation

/// What to do when the destination already exists.
public enum ConflictChoice: Equatable {
    case overwrite, skip, cancel
}

/// Outcome of a copy, move or delete.
public struct OperationReport: Equatable {
    public var done = 0
    public var skipped = 0
    public var errors: [String] = []
    public var cancelled = false

    public var succeeded: Bool { errors.isEmpty && !cancelled }
}

/// Copy (F5) and move/rename (F6), Total Commander style:
/// - the target is a folder (items go inside it) or, for a single item, a new path (rename/copy-as);
/// - several items into a folder that does not exist yet create it;
/// - a folder landing on an existing folder is merged entry by entry;
/// - any other clash asks `resolve(source, existing)`, which may answer for all later clashes too.
/// Runs synchronously; callers put it on a background queue.
public final class TransferOperation {
    public enum Kind { case copy, move }

    public let kind: Kind
    private let fm = FileManager.default
    private let resolve: (URL, URL) -> (ConflictChoice, applyToAll: Bool)
    private let isCancelled: () -> Bool
    private let progress: (URL) -> Void
    private var rememberedChoice: ConflictChoice?
    private var report = OperationReport()

    public init(kind: Kind,
                resolve: @escaping (URL, URL) -> (ConflictChoice, applyToAll: Bool),
                isCancelled: @escaping () -> Bool = { false },
                progress: @escaping (URL) -> Void = { _ in }) {
        self.kind = kind
        self.resolve = resolve
        self.isCancelled = isCancelled
        self.progress = progress
    }

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

    public func run(sources: [URL], target: String, base: URL) -> OperationReport {
        report = OperationReport()
        rememberedChoice = nil
        let (pairs, create) = Self.plan(sources: sources, target: target, base: base)
        if let folder = create {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                report.errors.append("Cannot create \(folder.path): \(error.localizedDescription)")
                return report
            }
        }
        for (source, destination) in pairs {
            if isCancelled() || report.cancelled { report.cancelled = true; break }
            progress(source)
            transfer(source.standardizedFileURL, to: destination.standardizedFileURL)
        }
        return report
    }

    private func transfer(_ source: URL, to destination: URL) {
        if report.cancelled || isCancelled() { report.cancelled = true; return }
        if source.path == destination.path {
            report.errors.append("\(source.lastPathComponent): source and target are the same")
            return
        }
        if destination.path.hasPrefix(source.path + "/") {
            report.errors.append("\(source.lastPathComponent): cannot \(kind == .copy ? "copy" : "move") a folder into itself")
            return
        }

        if exists(destination) {
            if isDirectory(source) && isDirectory(destination) {
                merge(source, into: destination)
                return
            }
            switch choice(for: source, existing: destination) {
            case .cancel:
                report.cancelled = true
                return
            case .skip:
                report.skipped += 1
                return
            case .overwrite:
                do {
                    try fm.removeItem(at: destination)
                } catch {
                    report.errors.append("Cannot replace \(destination.lastPathComponent): \(error.localizedDescription)")
                    return
                }
            }
        }

        do {
            switch kind {
            case .copy: try fm.copyItem(at: source, to: destination)
            case .move: try fm.moveItem(at: source, to: destination)
            }
            report.done += 1
        } catch {
            report.errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func merge(_ source: URL, into destination: URL) {
        let children = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            transfer(child, to: destination.appendingPathComponent(child.lastPathComponent))
            if report.cancelled { return }
        }
        // A merged move leaves the emptied source folder behind; remove it when nothing was kept.
        if kind == .move, (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
            try? fm.removeItem(at: source)
        }
    }

    private func choice(for source: URL, existing: URL) -> ConflictChoice {
        if let remembered = rememberedChoice { return remembered }
        let (choice, all) = resolve(source, existing)
        if all && choice != .cancel { rememberedChoice = choice }
        return choice
    }

    private func exists(_ url: URL) -> Bool {
        // lstat, so a dangling symlink at the destination still counts as "there".
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
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
