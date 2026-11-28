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
            current = appendPathComponent(current, comp)
            if isExistingZipFile(current, component: comp) {
                let archiveURL = URL(fileURLWithPath: current, isDirectory: false)
                let rest = components[(index + 1)...].filter { !$0.isEmpty }
                return (archiveURL, rest.joined(separator: "/"))
            }
        }
        return nil
    }

    private static func appendPathComponent(_ current: String, _ comp: String) -> String {
        if comp == "/" { return "/" }
        return current == "/" ? "/\(comp)" : "\(current)/\(comp)"
    }

    private static func isExistingZipFile(_ path: String, component: String) -> Bool {
        guard component.lowercased().hasSuffix(".zip") else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Lists direct children of `directory` (which must be a `.zip` archive or a path inside one).
    public static func entries(in directory: URL) throws -> [FileEntry] {
        guard let (archive, innerPath) = split(directory) else {
            throw ZipError.notAZipArchive(directory)
        }
        let all = try listAll(archive: archive)
        let prefix = innerPath.isEmpty ? "" : (innerPath + "/")
        let baseURL = archive.appendingPathComponent(innerPath, isDirectory: true)
        return collectEntries(from: all, prefix: prefix, baseURL: baseURL)
    }

    private static func collectEntries(from all: [Entry], prefix: String, baseURL: URL) -> [FileEntry] {
        var seenDirs = Set<String>()
        var result: [FileEntry] = []
        for item in all where item.path.hasPrefix(prefix) {
            let remainder = String(item.path.dropFirst(prefix.count))
            if !remainder.isEmpty, let entry = entryForItem(item, remainder: remainder, baseURL: baseURL, seenDirs: &seenDirs) {
                result.append(entry)
            }
        }
        return result
    }

    private static func entryForItem(
        _ item: Entry, remainder: String, baseURL: URL, seenDirs: inout Set<String>
    ) -> FileEntry? {
        if let slashIdx = remainder.firstIndex(of: "/") {
            let dirName = String(remainder[..<slashIdx])
            guard !dirName.isEmpty, seenDirs.insert(dirName).inserted else { return nil }
            return FileEntry(
                name: dirName, url: baseURL.appendingPathComponent(dirName, isDirectory: true),
                kind: .directory, size: nil, modified: item.modified, isSymlink: false, permissions: 0o755
            )
        }
        if item.isDirectory {
            guard seenDirs.insert(remainder).inserted else { return nil }
            return FileEntry(
                name: remainder, url: baseURL.appendingPathComponent(remainder, isDirectory: true),
                kind: .directory, size: nil, modified: item.modified, isSymlink: false, permissions: item.permissions
            )
        }
        return FileEntry(
            name: remainder, url: baseURL.appendingPathComponent(remainder, isDirectory: false),
            kind: .file, size: item.size, modified: item.modified, isSymlink: false, permissions: item.permissions
        )
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
    private struct ExtractConflictResolver {
        var replaceAll = false
        var skipAll = false
        var replaceAllOlder = false
        let resolveConflict: ((TransferConflict) -> ConflictDecision)?

        mutating func shouldWrite(
            sourceURL: URL,
            sourceSize: Int64,
            sourceDate: Date?,
            dest: inout URL
        ) -> (write: Bool, cancelled: Bool) {
            guard FileManager.default.fileExists(atPath: dest.path) else { return (true, false) }
            if let shortcut = presetDecision() { return shortcut }
            let (targetSize, targetDate) = Self.existingFileMetadata(at: dest)
            if replaceAllOlder { return (isTargetOlder(targetDate, sourceDate: sourceDate), false) }
            guard let resolve = resolveConflict else { return (true, false) }
            let conflict = TransferConflict(
                source: .local(sourceURL), target: .local(dest),
                sourceSize: sourceSize, sourceDate: sourceDate,
                targetSize: targetSize, targetDate: targetDate
            )
            return applyDecision(resolve(conflict), targetDate: targetDate, sourceDate: sourceDate, dest: &dest)
        }

        private func presetDecision() -> (write: Bool, cancelled: Bool)? {
            if replaceAll { return (true, false) }
            return skipAll ? (false, false) : nil
        }

        private static func existingFileMetadata(at dest: URL) -> (Int64?, Date?) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            return ((attrs?[.size] as? NSNumber)?.int64Value, attrs?[.modificationDate] as? Date)
        }

        private mutating func applyDecision(
            _ decision: ConflictDecision,
            targetDate: Date?,
            sourceDate: Date?,
            dest: inout URL
        ) -> (write: Bool, cancelled: Bool) {
            if case .rename(let newName) = decision {
                dest = dest.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: false)
                return (true, false)
            }
            if case .replaceAllOlder = decision {
                replaceAllOlder = true
                return (isTargetOlder(targetDate, sourceDate: sourceDate), false)
            }
            return applySimpleDecision(decision)
        }

        private mutating func applySimpleDecision(_ decision: ConflictDecision) -> (write: Bool, cancelled: Bool) {
            switch decision {
            case .replaceAll: replaceAll = true; return (true, false)
            case .skipAll: skipAll = true; return (false, false)
            case .replace: return (true, false)
            case .cancel: return (false, true)
            default: return (false, false)
            }
        }

        private func isTargetOlder(_ targetDate: Date?, sourceDate: Date?) -> Bool {
            targetDate.map { $0 < (sourceDate ?? .distantPast) } ?? true
        }
    }

    private static func extractDirectory(
        archive: URL,
        innerPath: String,
        name: String,
        allEntries: [Entry],
        to targetDirectory: URL,
        resolver: inout ExtractConflictResolver
    ) throws -> Bool {
        let dirPrefix = innerPath + "/"
        let destRoot = targetDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        for sub in allEntries where sub.path.hasPrefix(dirPrefix) {
            if try extractDirectoryEntry(sub, archive: archive, dirPrefix: dirPrefix,
                                         destRoot: destRoot, resolver: &resolver) {
                return true
            }
        }
        return false
    }

    private static func extractDirectoryEntry(
        _ sub: Entry,
        archive: URL,
        dirPrefix: String,
        destRoot: URL,
        resolver: inout ExtractConflictResolver
    ) throws -> Bool {
        let rel = String(sub.path.dropFirst(dirPrefix.count))
        guard !rel.isEmpty else { return false }
        var dest = destRoot.appendingPathComponent(rel, isDirectory: sub.isDirectory)
        if sub.isDirectory {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            return false
        }
        let srcURL = archive.appendingPathComponent(sub.path, isDirectory: false)
        let decision = resolver.shouldWrite(sourceURL: srcURL, sourceSize: sub.size, sourceDate: sub.modified, dest: &dest)
        if decision.cancelled { return true }
        if decision.write {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try extractFile(archive: archive, innerPath: sub.path, to: dest)
        }
        return false
    }

    /// asking `resolveConflict` before overwriting any existing destination file.
    public static func extractItems(
        _ items: [FileEntry],
        to targetDirectory: URL,
        resolveConflict: ((TransferConflict) -> ConflictDecision)? = nil
    ) throws {
        guard !items.isEmpty else { return }
        var resolver = ExtractConflictResolver(resolveConflict: resolveConflict)

        for (archiveOpt, group) in Dictionary(grouping: items, by: { split($0.url)?.archive }) {
            guard let archive = archiveOpt else { continue }
            if try extractArchiveGroup(group, from: archive, to: targetDirectory, resolver: &resolver) { return }
        }
    }

    private static func extractArchiveGroup(
        _ group: [FileEntry],
        from archive: URL,
        to targetDirectory: URL,
        resolver: inout ExtractConflictResolver
    ) throws -> Bool {
        let allEntries = try listAll(archive: archive)
        for item in group {
            guard let (_, innerPath) = split(item.url), !innerPath.isEmpty else { continue }
            if try extractSingleItem(item, from: archive, innerPath: innerPath,
                                     allEntries: allEntries, to: targetDirectory, resolver: &resolver) {
                return true
            }
        }
        return false
    }

    private static func extractSingleItem(
        _ item: FileEntry,
        from archive: URL,
        innerPath: String,
        allEntries: [Entry],
        to targetDirectory: URL,
        resolver: inout ExtractConflictResolver
    ) throws -> Bool {
        if item.kind == .file {
            var dest = targetDirectory.appendingPathComponent(item.name, isDirectory: false)
            let decision = resolver.shouldWrite(sourceURL: item.url, sourceSize: item.size ?? 0, sourceDate: item.modified, dest: &dest)
            if decision.cancelled { return true }
            if decision.write { try extractFile(archive: archive, innerPath: innerPath, to: dest) }
        } else if item.kind == .directory {
            return try extractDirectory(archive: archive, innerPath: innerPath, name: item.name,
                                        allEntries: allEntries, to: targetDirectory, resolver: &resolver)
        }
        return false
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
        let (executable, arguments) = unpackCommand(archive: archiveURL, to: targetDirectory, overwrite: overwrite)
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
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

    private static func unpackCommand(archive archiveURL: URL, to targetDirectory: URL, overwrite: Bool) -> (URL, [String]) {
        if let sevenZip = find7zip() {
            return (sevenZip, ["x", overwrite ? "-aoa" : "-aos", "-y", "-o\(targetDirectory.path)", archiveURL.path])
        }
        return (URL(fileURLWithPath: "/usr/bin/unzip"), [overwrite ? "-o" : "-n", "-q", archiveURL.path, "-d", targetDirectory.path])
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
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseZipInfoLine(String($0)) }
    }

    private static func parseZipInfoLine(_ line: String) -> Entry? {
        // Entry lines start with permissions (e.g., "-rw-r--r--", "drwxrwxr-x", "?rw-------")
        guard let first = line.first, ["-", "d", "?", "l"].contains(first),
              let (fields, pathStart) = splitZipInfoFields(line) else {
            return nil
        }
        return makeZipEntry(first: first, fields: fields, rawPath: String(line[pathStart...]))
    }

    private static func makeZipEntry(first: Character, fields: [Substring], rawPath: String) -> Entry? {
        let isDir = first == "d" || rawPath.hasSuffix("/")
        guard let path = normalizedZipPath(rawPath) else { return nil }
        return Entry(
            path: path, isDirectory: isDir, size: Int64(fields[3]) ?? 0,
            modified: parsedZipDate(fields[6]),
            permissions: isDir ? 0o755 : 0o644
        )
    }

    private static func normalizedZipPath(_ rawPath: String) -> String? {
        let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        return path.isEmpty ? nil : path
    }

    private static func parsedZipDate(_ field: Substring) -> Date {
        dateFormatter.date(from: String(field)) ?? Date(timeIntervalSince1970: 0)
    }

    private static func splitZipInfoFields(_ line: String) -> ([Substring], String.Index)? {
        var fields: [Substring] = []
        var idx = line.startIndex
        while fields.count < 7, let (token, next) = nextZipInfoToken(in: line, from: idx) {
            fields.append(token)
            idx = next
        }
        guard fields.count == 7, idx < line.endIndex else { return nil }
        let pathStart = line[idx].isWhitespace ? line.index(after: idx) : idx
        return pathStart < line.endIndex ? (fields, pathStart) : nil
    }

    private static func nextZipInfoToken(in line: String, from start: String.Index) -> (Substring, String.Index)? {
        guard let tokenStart = line[start...].firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let tokenEnd = line[tokenStart...].firstIndex(where: { $0.isWhitespace }) ?? line.endIndex
        return (line[tokenStart..<tokenEnd], tokenEnd)
    }
}
