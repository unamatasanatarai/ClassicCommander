import Foundation

/// Reads and extracts entries from `.zip` archives using `/usr/bin/unzip`.
public enum ZipArchive {
    public struct Entry {
        public let path: String
        public let isDirectory: Bool
        public let size: Int64
        public let modified: Date
        public let permissions: Int
    }

    public enum ZipError: LocalizedError {
        case notAZipArchive(URL)
        case unzipFailed(Int32, String)

        public var errorDescription: String? {
            switch self {
            case .notAZipArchive(let url):
                return "Not a zip archive: \(url.lastPathComponent)"
            case .unzipFailed(let code, let message):
                return message.isEmpty ? "unzip exited with status \(code)" : message
            }
        }
    }

    /// If `url` points to a `.zip` file on disk or a path inside one, returns `(archiveURL, innerPath)`.
    /// `innerPath` is `""` at the archive root, or `"sub/dir"` without leading/trailing slashes.
    public static func split(_ url: URL) -> (archive: URL, innerPath: String)? {
        guard url.isFileURL else { return nil }
        let components = url.standardizedFileURL.pathComponents
        var current = ""
        for (index, comp) in components.enumerated() {
            if comp == "/" {
                current = "/"
            } else {
                current = current == "/" ? "/\(comp)" : "\(current)/\(comp)"
            }
            if comp.lowercased().hasSuffix(".zip") {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: current, isDirectory: &isDir), !isDir.boolValue {
                    let archiveURL = URL(fileURLWithPath: current, isDirectory: false)
                    let rest = components[(index + 1)...].filter { !$0.isEmpty }
                    return (archiveURL, rest.joined(separator: "/"))
                }
            }
        }
        return nil
    }

    /// Lists direct children of `directory` (which must be a `.zip` archive or a path inside one).
    public static func entries(in directory: URL) throws -> [FileEntry] {
        guard let (archive, innerPath) = split(directory) else {
            throw ZipError.notAZipArchive(directory)
        }
        let all = try listAll(archive: archive)
        let prefix = innerPath.isEmpty ? "" : (innerPath + "/")
        let baseURL = archive.appendingPathComponent(innerPath, isDirectory: true)

        var seenDirs = Set<String>()
        var result: [FileEntry] = []

        for item in all {
            guard item.path.hasPrefix(prefix) else { continue }
            let remainder = String(item.path.dropFirst(prefix.count))
            guard !remainder.isEmpty else { continue }

            if let slashIdx = remainder.firstIndex(of: "/") {
                let dirName = String(remainder[..<slashIdx])
                guard !dirName.isEmpty, seenDirs.insert(dirName).inserted else { continue }
                let dirURL = baseURL.appendingPathComponent(dirName, isDirectory: true)
                result.append(FileEntry(
                    name: dirName,
                    url: dirURL,
                    kind: .directory,
                    size: nil,
                    modified: item.modified,
                    isSymlink: false,
                    permissions: 0o755
                ))
            } else if item.isDirectory {
                guard seenDirs.insert(remainder).inserted else { continue }
                let dirURL = baseURL.appendingPathComponent(remainder, isDirectory: true)
                result.append(FileEntry(
                    name: remainder,
                    url: dirURL,
                    kind: .directory,
                    size: nil,
                    modified: item.modified,
                    isSymlink: false,
                    permissions: item.permissions
                ))
            } else {
                let fileURL = baseURL.appendingPathComponent(remainder, isDirectory: false)
                result.append(FileEntry(
                    name: remainder,
                    url: fileURL,
                    kind: .file,
                    size: item.size,
                    modified: item.modified,
                    isSymlink: false,
                    permissions: item.permissions
                ))
            }
        }

        return result
    }

    /// Extracts a single file from a zip archive to a temporary file and returns its URL.
    public static func extractToTemp(url: URL) throws -> URL {
        guard let (archive, innerPath) = split(url), !innerPath.isEmpty else {
            throw ZipError.notAZipArchive(url)
        }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassicCommanderZip", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let dest = tempRoot.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        try extractFile(archive: archive, innerPath: innerPath, to: dest)
        return dest
    }

    /// Extracts `items` (files and/or directories) from `archive` into `targetDirectory`,
    /// asking `resolveConflict` before overwriting any existing destination file.
    public static func extractItems(
        _ items: [FileEntry],
        to targetDirectory: URL,
        resolveConflict: ((TransferConflict) -> ConflictDecision)? = nil
    ) throws {
        guard !items.isEmpty else { return }
        var replaceAll = false
        var skipAll = false
        var replaceAllOlder = false

        func shouldWrite(sourceURL: URL, sourceSize: Int64, sourceDate: Date?, dest: inout URL) -> (write: Bool, cancelled: Bool) {
            guard FileManager.default.fileExists(atPath: dest.path) else { return (true, false) }
            if replaceAll { return (true, false) }
            if skipAll { return (false, false) }
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let targetSize = (attrs?[.size] as? NSNumber)?.int64Value
            let targetDate = attrs?[.modificationDate] as? Date
            if replaceAllOlder {
                let isOlder = targetDate.map { ($0) < (sourceDate ?? .distantPast) } ?? true
                return (isOlder, false)
            }
            guard let resolve = resolveConflict else { return (true, false) }
            let conflict = TransferConflict(
                source: .local(sourceURL),
                target: .local(dest),
                sourceSize: sourceSize,
                sourceDate: sourceDate,
                targetSize: targetSize,
                targetDate: targetDate
            )
            switch resolve(conflict) {
            case .replace:
                return (true, false)
            case .replaceAll:
                replaceAll = true
                return (true, false)
            case .skip:
                return (false, false)
            case .skipAll:
                skipAll = true
                return (false, false)
            case .replaceAllOlder:
                replaceAllOlder = true
                let isOlder = targetDate.map { ($0) < (sourceDate ?? .distantPast) } ?? true
                return (isOlder, false)
            case .rename(let newName):
                dest = dest.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: false)
                return (true, false)
            case .cancel:
                return (false, true)
            }
        }

        let allByArchive = Dictionary(grouping: items, by: { split($0.url)?.archive })
        for (archiveOpt, group) in allByArchive {
            guard let archive = archiveOpt else { continue }
            let allEntries = try listAll(archive: archive)
            for item in group {
                guard let (_, innerPath) = split(item.url), !innerPath.isEmpty else { continue }
                if item.kind == .file {
                    var dest = targetDirectory.appendingPathComponent(item.name, isDirectory: false)
                    let decision = shouldWrite(sourceURL: item.url, sourceSize: item.size ?? 0, sourceDate: item.modified, dest: &dest)
                    if decision.cancelled { return }
                    if decision.write {
                        try extractFile(archive: archive, innerPath: innerPath, to: dest)
                    }
                } else if item.kind == .directory {
                    let dirPrefix = innerPath + "/"
                    let destRoot = targetDirectory.appendingPathComponent(item.name, isDirectory: true)
                    try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
                    for sub in allEntries where sub.path.hasPrefix(dirPrefix) {
                        let rel = String(sub.path.dropFirst(dirPrefix.count))
                        guard !rel.isEmpty else { continue }
                        var dest = destRoot.appendingPathComponent(rel, isDirectory: sub.isDirectory)
                        if sub.isDirectory {
                            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                        } else {
                            let srcURL = archive.appendingPathComponent(sub.path, isDirectory: false)
                            let decision = shouldWrite(sourceURL: srcURL, sourceSize: sub.size, sourceDate: sub.modified, dest: &dest)
                            if decision.cancelled { return }
                            if decision.write {
                                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                                try extractFile(archive: archive, innerPath: sub.path, to: dest)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Returns the path to `7zz`, `7z`, or `7za` if installed, or nil to fall back to `/usr/bin/zip` & `unzip`.
    public static func find7zip() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z", "/opt/homebrew/bin/7za",
            "/usr/local/bin/7zz", "/usr/local/bin/7z", "/usr/local/bin/7za",
            "/usr/bin/7zz", "/usr/bin/7z", "/usr/bin/7za"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Packs `items` (relative to `sourceDirectory`) into `archiveURL`, using 7zip if available or `/usr/bin/zip`.
    public static func pack(items: [FileEntry], from sourceDirectory: URL, to archiveURL: URL, onProcess: ((Process) -> Void)? = nil) throws {
        guard !items.isEmpty else { return }
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let names = items.map(\.name)
        let proc = Process()
        proc.currentDirectoryURL = sourceDirectory
        if let sevenZip = find7zip() {
            proc.executableURL = sevenZip
            proc.arguments = ["a", "-y", archiveURL.path] + names
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            proc.arguments = ["-r", "-q", archiveURL.path] + names
        }
        let errPipe = Pipe()
        proc.standardError = errPipe
        onProcess?(proc)
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ZipError.unzipFailed(proc.terminationStatus, msg)
        }
    }

    /// Unpacks `archiveURL` into `targetDirectory`, using 7zip if available or `/usr/bin/unzip`.
    /// When `overwrite` is false, existing files on disk are skipped.
    public static func unpack(archive archiveURL: URL, to targetDirectory: URL, overwrite: Bool = false) throws {
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let proc = Process()
        if let sevenZip = find7zip() {
            proc.executableURL = sevenZip
            proc.arguments = ["x", overwrite ? "-aoa" : "-aos", "-y", "-o\(targetDirectory.path)", archiveURL.path]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            proc.arguments = [overwrite ? "-o" : "-n", "-q", archiveURL.path, "-d", targetDirectory.path]
        }
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 || proc.terminationStatus == 1 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ZipError.unzipFailed(proc.terminationStatus, msg)
        }
    }

    /// Extracts a single file entry from `archive` to `destination` using `unzip -p`.
    public static func extractFile(archive: URL, innerPath: String, to destination: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-p", archive.path, innerPath]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ZipError.unzipFailed(proc.terminationStatus, msg)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - Parsing `unzip -Z -T`

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd.HHmmss"
        return df
    }()

    public static func listAll(archive: URL) throws -> [Entry] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-Z", "-T", archive.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        // unzip -Z returns 0 on success, 1 on minor warnings.
        guard proc.terminationStatus == 0 || proc.terminationStatus == 1 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ZipError.unzipFailed(proc.terminationStatus, msg)
        }
        let output = String(data: data, encoding: .utf8) ?? ""
        return parseZipInfo(output)
    }

    static func parseZipInfo(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            // Entry lines start with permissions (e.g., "-rw-r--r--", "drwxrwxr-x", "?rw-------")
            guard let first = line.first, first == "-" || first == "d" || first == "?" || first == "l" else {
                continue
            }
            // Split into at most 8 whitespace-separated fields; the 8th is the rest of the line (the path).
            var fields: [Substring] = []
            var idx = line.startIndex
            while fields.count < 7 && idx < line.endIndex {
                while idx < line.endIndex && line[idx].isWhitespace { idx = line.index(after: idx) }
                guard idx < line.endIndex else { break }
                let start = idx
                while idx < line.endIndex && !line[idx].isWhitespace { idx = line.index(after: idx) }
                fields.append(line[start..<idx])
            }
            guard fields.count == 7, idx < line.endIndex else { continue }
            // Skip the single space before the filename.
            if line[idx].isWhitespace { idx = line.index(after: idx) }
            guard idx < line.endIndex else { continue }
            var path = String(line[idx...])
            let isDir = first == "d" || path.hasSuffix("/")
            if path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty else { continue }

            let size = Int64(fields[3]) ?? 0
            let modified = dateFormatter.date(from: String(fields[6])) ?? Date(timeIntervalSince1970: 0)
            let perms = isDir ? 0o755 : 0o644
            entries.append(Entry(path: path, isDirectory: isDir, size: size, modified: modified, permissions: perms))
        }
        return entries
    }
}
