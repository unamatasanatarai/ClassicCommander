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

    private struct BucketKey: Hashable { let name: String?; let size: Int64? }

    public static func groups(of items: [SearchItem], config: DuplicateSearchConfiguration,
                              errors: inout [String], isCancelled: () -> Bool = { false }) -> [Group] {
        var buckets: [BucketKey: [SearchItem]] = [:]
        for f in items where !f.isDirectory {
            buckets[bucketKey(for: f, config: config), default: []].append(f)
        }
        var found: [[SearchItem]] = []
        for (_, bucket) in buckets where bucket.count > 1 && !isCancelled() {
            found += config.sameContents ? contentGroups(bucket, errors: &errors, isCancelled: isCancelled) : [bucket]
        }
        let sorted = found
            .map { $0.sorted { $0.url.path < $1.url.path } }
            .sorted { $0[0].url.path < $1[0].url.path }
        return sorted.enumerated().map { Group(id: $0.offset + 1, items: $0.element) }
    }

    private static func bucketKey(for item: SearchItem, config: DuplicateSearchConfiguration) -> BucketKey {
        BucketKey(name: config.sameName ? NameMatcher.normalize(item.name).lowercased() : nil,
                  size: (config.sameSize || config.sameContents) ? item.size : nil)
    }

    /// Splits same-size files into groups of identical contents.
    private static func contentGroups(_ files: [SearchItem], errors: inout [String],
                                      isCancelled: () -> Bool) -> [[SearchItem]] {
        let byHash = groupByHash(files, errors: &errors, isCancelled: isCancelled)
        var result: [[SearchItem]] = []
        for (_, candidates) in byHash where candidates.count > 1 {
            result += splitIdentical(candidates)
        }
        return result
    }

    private static func groupByHash(_ files: [SearchItem], errors: inout [String],
                                    isCancelled: () -> Bool) -> [Data: [SearchItem]] {
        var byHash: [Data: [SearchItem]] = [:]
        for f in files {
            if isCancelled() { return [:] }
            guard let digest = hash(f.url) else {
                errors.append("\(f.url.path): could not be read (skipped for duplicates)")
                continue
            }
            byHash[digest, default: []].append(f)
        }
        return byHash
    }

    private static func splitIdentical(_ candidates: [SearchItem]) -> [[SearchItem]] {
        // Confirm byte by byte against each group's first member; a hash collision splits off.
        var result: [[SearchItem]] = []
        var remaining = candidates
        while remaining.count > 1 {
            let first = remaining.removeFirst()
            let same = [first] + remaining.filter { identical(first.url, $0.url) }
            if same.count > 1 { result.append(same) }
            remaining = remaining.filter { c in !same.contains { $0.url == c.url } }
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
        return handlesIdentical(ha, hb)
    }

    private static func handlesIdentical(_ ha: FileHandle, _ hb: FileHandle) -> Bool {
        do {
            while let same = try compareNextChunk(ha, hb) {
                if !same { return false }
            }
            return true
        } catch {
            return false
        }
    }

    private static func compareNextChunk(_ ha: FileHandle, _ hb: FileHandle) throws -> Bool? {
        // nil at the end of a file counts as "no more data".
        let ca = try ha.read(upToCount: 1 << 20) ?? Data()
        let cb = try hb.read(upToCount: 1 << 20) ?? Data()
        if ca != cb { return false }
        return ca.isEmpty ? nil : true
    }
}
