import Foundation

/// Adds up the sizes of all files below a folder (what Space shows in the Size column).
/// Symbolic links are counted as links, not followed, so a link to "/" cannot run away.
/// Unreadable subfolders are skipped. `isCancelled` is polled so a long walk can be abandoned.
public enum FolderSizer {
    public static func totalSize(of folder: URL, isCancelled: () -> Bool = { false }) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = makeWalker(for: folder, keys: keys) else { return 0 }
        return accumulateSizes(from: walker, keys: Set(keys), isCancelled: isCancelled)
    }

    private static func accumulateSizes(
        from walker: FileManager.DirectoryEnumerator, keys: Set<URLResourceKey>, isCancelled: () -> Bool
    ) -> Int64 {
        var total: Int64 = 0
        var count = 0
        for case let url as URL in walker {
            count += 1
            if count % 512 == 0 && isCancelled() { break }
            total = total.addingSaturated(regularFileSize(at: url, keys: keys))
        }
        return total
    }

    private static func makeWalker(for folder: URL, keys: [URLResourceKey]) -> FileManager.DirectoryEnumerator? {
        // A linked folder (e.g. ~/bin) is measured through its target; links inside are not followed.
        FileManager.default.enumerator(
            at: FileSystemLister.realPath(of: folder),
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        )
    }

    private static func regularFileSize(at url: URL, keys: Set<URLResourceKey>) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { return 0 }
        return Int64(v.fileSize ?? 0)
    }
}
