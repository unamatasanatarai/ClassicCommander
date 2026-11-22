import Foundation

/// Adds up the sizes of all files below a folder (what Space shows in the Size column).
/// Symbolic links are counted as links, not followed, so a link to "/" cannot run away.
/// Unreadable subfolders are skipped. `isCancelled` is polled so a long walk can be abandoned.
public enum FolderSizer {
    public static func totalSize(of folder: URL, isCancelled: () -> Bool = { false }) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        // A linked folder (e.g. ~/bin) is measured through its target; links inside are not followed.
        guard let walker = FileManager.default.enumerator(
            at: FileSystemLister.realPath(of: folder),
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        var count = 0
        for case let url as URL in walker {
            count += 1
            if count % 512 == 0 && isCancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }
}
