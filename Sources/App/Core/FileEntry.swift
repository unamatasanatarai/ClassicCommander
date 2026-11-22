import Foundation

/// One row in a file panel: a file, a directory, or the synthetic ".." parent link.
public struct FileEntry: Equatable {
    public enum Kind: Equatable {
        case parent
        case directory
        case file
    }

    public let name: String
    public let url: URL
    public let kind: Kind
    public let size: Int64?
    public let modified: Date?
    public let isSymlink: Bool
    public let permissions: Int?

    public init(name: String, url: URL, kind: Kind, size: Int64? = nil, modified: Date? = nil,
                isSymlink: Bool = false, permissions: Int? = nil) {
        self.name = name
        self.url = url
        self.kind = kind
        self.size = size
        self.modified = modified
        self.isSymlink = isSymlink
        self.permissions = permissions
    }

    public static func parent(of directory: URL) -> FileEntry {
        FileEntry(name: "..", url: directory.deletingLastPathComponent(), kind: .parent)
    }

    public var isNavigable: Bool { kind != .file }

    /// Name without extension, as shown in the "Name" column. Directories keep their full name.
    public var baseName: String {
        guard kind == .file, let dot = extensionDotIndex else { return name }
        return String(name[..<dot])
    }

    /// Extension without the dot, as shown in the "Ext" column. Empty for directories and dotfiles.
    public var displayExtension: String {
        guard kind == .file, let dot = extensionDotIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    private var extensionDotIndex: String.Index? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return nil }
        return dot
    }
}
