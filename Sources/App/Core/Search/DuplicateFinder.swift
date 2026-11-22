import CryptoKit
import Foundation

/// Groups files that are duplicates of each other, across any folders and starting points.
///   - same name: case-insensitive and Unicode-normalised (APFS/HFS+ are case-insensitive by default);
///   - same size: equal byte counts;
///   - same contents: size first (a cheap pre-filter, never proof), then a SHA-256 of the contents,
///     then a byte-by-byte comparison to confirm. Files are streamed, never loaded whole.
/// Groups have two or more members and are numbered 1, 2, 3… in a stable order (by first path).
public enum DuplicateFinder {
    public struct Group: Equatable {
        public let id: Int
        public let items: [SearchItem]
    }

    public static func groups(of items: [SearchItem], config: DuplicateSearchConfiguration,
                              errors: inout [String], isCancelled: () -> Bool = { false }) -> [Group] {
        let files = items.filter { !$0.isDirectory }
        // Name and size form the first key; contents need equal sizes anyway.
        struct Key: Hashable { let name: String?; let size: Int64? }
        var buckets: [Key: [SearchItem]] = [:]
        for f in files {
            let key = Key(name: config.sameName ? NameMatcher.normalize(f.name).lowercased() : nil,
                          size: (config.sameSize || config.sameContents) ? f.size : nil)
            buckets[key, default: []].append(f)
        }
        var found: [[SearchItem]] = []
        for (_, bucket) in buckets where bucket.count > 1 {
            if isCancelled() { break }
            if config.sameContents {
                found += contentGroups(bucket, errors: &errors, isCancelled: isCancelled)
            } else {
                found.append(bucket)
            }
        }
        let sorted = found
            .map { $0.sorted { $0.url.path < $1.url.path } }
            .sorted { $0[0].url.path < $1[0].url.path }
        return sorted.enumerated().map { Group(id: $0.offset + 1, items: $0.element) }
    }

    /// Splits same-size files into groups of identical contents.
    private static func contentGroups(_ files: [SearchItem], errors: inout [String],
                                      isCancelled: () -> Bool) -> [[SearchItem]] {
        var byHash: [Data: [SearchItem]] = [:]
        for f in files {
            if isCancelled() { return [] }
            guard let digest = hash(f.url) else {
                errors.append("\(f.url.path): could not be read (skipped for duplicates)")
                continue
            }
            byHash[digest, default: []].append(f)
        }
        var result: [[SearchItem]] = []
        for (_, candidates) in byHash where candidates.count > 1 {
            // Confirm byte by byte against each group's first member; a hash collision splits off.
            var remaining = candidates
            while remaining.count > 1 {
                let first = remaining.removeFirst()
                var same = [first], other: [SearchItem] = []
                for c in remaining {
                    if identical(first.url, c.url) { same.append(c) } else { other.append(c) }
                }
                if same.count > 1 { result.append(same) }
                remaining = other
            }
        }
        return result
    }

    static func hash(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // read(upToCount:) returns nil (not empty data) at the end of the file.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return Data(hasher.finalize())
    }

    static func identical(_ a: URL, _ b: URL) -> Bool {
        guard let ha = try? FileHandle(forReadingFrom: a), let hb = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? ha.close(); try? hb.close() }
        do {
            while true {
                // nil at the end of a file counts as "no more data".
                let ca = try ha.read(upToCount: 1 << 20) ?? Data()
                let cb = try hb.read(upToCount: 1 << 20) ?? Data()
                if ca != cb { return false }
                if ca.isEmpty { return true }
            }
        } catch {
            return false
        }
    }
}
