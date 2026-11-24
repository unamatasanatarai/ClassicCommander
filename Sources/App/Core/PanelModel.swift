import Foundation

/// State of one file panel: which directory it shows, the cursor row and the first visible row.
/// Purely logical; the view tells it how many rows fit on screen.
public final class PanelModel {
    public enum OpenResult: Equatable {
        case navigated
        case file(URL)
        case failed(String)
        case none
    }

    public private(set) var directory: URL
    /// The rows on screen: every entry, or only those passing the quick filter.
    public private(set) var entries: [FileEntry] = [] { didSet { revision &+= 1 } }
    /// Changes whenever entries, marks or folder sizes change (views cache derived text by it).
    public private(set) var revision = 0
    /// Every entry of the directory, sorted, before the quick filter and the Show filter.
    public private(set) var allEntries: [FileEntry] = []
    /// Set while the panel shows Find Files results ("Feed to listbox") instead of a folder.
    /// Entries then carry their real paths; ".." returns to the folder.
    public private(set) var virtualTitle: String?
    /// Quick Filter (⌃S) text; nil when the panel is not filtered. Cleared on changing directory.
    public private(set) var quickFilter: String?
    /// Only marked entries are shown (a selection set to "mark and hide all others"). Esc, another
    /// folder or a cleared quick filter shows everything again.
    public private(set) var showsMarkedOnly = false
    /// The marks before the last selection command or file operation (Select → Restore Selection).
    public private(set) var previousMarks: Set<String> = []
    /// View → Show: which files the panel lists (folders always). Unlike the Quick Filter it stays
    /// when changing folders.
    public private(set) var showFilter: PanelShowFilter = .all
    public private(set) var cursor: Int = 0
    public private(set) var scrollTop: Int = 0
    /// Last error from reading a directory, shown in the panel footer until the next navigation.
    public private(set) var errorMessage: String?
    public private(set) var sortOrder = SortOrder()
    /// Names of marked (selected) entries in the current directory. ".." is never marked.
    public private(set) var marked: Set<String> = [] { didSet { revision &+= 1 } }
    /// Total sizes of folders worked out with Space, by name, for the current directory.
    public private(set) var folderSizes: [String: Int64] = [:] { didSet { revision &+= 1 } }
    /// Called after the panel moves to another directory (used to stop folder-size work).
    public var onDirectoryChange: (() -> Void)?

    /// Where entries come from: the local file system, or a remote session's listings.
    public private(set) var lister: DirectoryListing

    public init(directory: URL, lister: DirectoryListing = FileSystemLister()) {
        self.directory = directory.normalizedLocation
        self.lister = lister
        if case .failed = load(self.directory, focusing: nil) {
            // Fall back to an empty view of the requested path; the footer reports the error.
            allEntries = isRoot(self.directory) ? [] : [FileEntry.parent(of: self.directory)]
            entries = allEntries
        }
    }

    public var currentEntry: FileEntry? {
        entries.indices.contains(cursor) ? entries[cursor] : nil
    }

    /// Entries excluding "..", for the footer totals.
    public var realEntries: ArraySlice<FileEntry> {
        entries.first?.kind == .parent ? entries.dropFirst() : entries[...]
    }

    // MARK: Cursor movement

    public func moveCursor(by delta: Int, visibleRows: Int) {
        setCursor(cursor + delta, visibleRows: visibleRows)
    }

    public func moveToStart(visibleRows: Int) {
        setCursor(0, visibleRows: visibleRows)
    }

    public func moveToEnd(visibleRows: Int) {
        setCursor(entries.count - 1, visibleRows: visibleRows)
    }

    public func pageDown(visibleRows: Int) {
        moveCursor(by: max(1, visibleRows - 1), visibleRows: visibleRows)
    }

    public func pageUp(visibleRows: Int) {
        moveCursor(by: -max(1, visibleRows - 1), visibleRows: visibleRows)
    }

    public func setCursor(_ index: Int, visibleRows: Int) {
        guard !entries.isEmpty else { cursor = 0; scrollTop = 0; return }
        cursor = min(max(0, index), entries.count - 1)
        ensureCursorVisible(visibleRows: visibleRows)
    }

    /// Scrolls the list without moving the cursor (mouse wheel), keeping the cursor on screen.
    public func scroll(by delta: Int, visibleRows: Int) {
        let rows = max(1, visibleRows)
        let maxTop = max(0, entries.count - rows)
        scrollTop = min(max(0, scrollTop + delta), maxTop)
        if cursor < scrollTop { cursor = scrollTop }
        if cursor >= scrollTop + rows { cursor = min(entries.count - 1, scrollTop + rows - 1) }
    }

    public func ensureCursorVisible(visibleRows: Int) {
        let rows = max(1, visibleRows)
        if cursor < scrollTop { scrollTop = cursor }
        if cursor >= scrollTop + rows { scrollTop = cursor - rows + 1 }
        let maxTop = max(0, entries.count - rows)
        scrollTop = min(max(0, scrollTop), maxTop)
    }

    // MARK: Selection

    public func isMarked(_ entry: FileEntry) -> Bool {
        marked.contains(entry.name)
    }

    /// Space: marks or unmarks the entry under the cursor. Returns that entry, or nil on "..".
    @discardableResult
    public func toggleMarkAtCursor() -> FileEntry? {
        guard let entry = currentEntry, entry.kind != .parent else { return nil }
        if marked.contains(entry.name) {
            marked.remove(entry.name)
        } else {
            marked.insert(entry.name)
        }
        return entry
    }

    /// What F5/F6/F8 act on: the marked entries, or the entry under the cursor when nothing is marked.
    public var operationTargets: [FileEntry] {
        let markedEntries = realEntries.filter { marked.contains($0.name) }
        if !markedEntries.isEmpty { return Array(markedEntries) }
        if let entry = currentEntry, entry.kind != .parent { return [entry] }
        return []
    }

    public func clearMarks() {
        rememberMarks()
        marked = []
    }

    /// Keeps the current marks for Restore Selection (an empty selection keeps the older one).
    private func rememberMarks() {
        if !marked.isEmpty { previousMarks = marked }
    }

    /// Select → Restore Selection: the marks from before the last selection command or file
    /// operation (those still in the folder).
    @discardableResult
    public func restoreMarks() -> Int {
        let present = Set(realEntries.map(\.name))
        let restored = previousMarks.intersection(present)
        rememberMarks()
        marked = restored
        return restored.count
    }

    /// ⌃+ / ⌃−: every file and folder marked, or none.
    public func markAll(_ mark: Bool) {
        rememberMarks()
        marked = mark ? Set(realEntries.map(\.name)) : []
    }

    /// Marks (or unmarks) every file with the extension of the entry under the cursor
    /// (files without one: every file without one). Returns how many, or nil on ".." or a folder.
    @discardableResult
    public func setMarksWithCurrentExtension(_ mark: Bool) -> Int? {
        guard let entry = currentEntry, entry.kind == .file else { return nil }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let hits = realEntries.filter { $0.kind == .file && ($0.name as NSString).pathExtension.lowercased() == ext }.map(\.name)
        rememberMarks()
        if mark { marked.formUnion(hits) } else { marked.subtract(hits) }
        return hits.count
    }

    /// Shows only the marked entries (and ".."), or everything again.
    public func showMarkedOnly(_ on: Bool, visibleRows: Int) {
        showsMarkedOnly = on
        let focused = currentEntry?.name
        entries = filtered(allEntries)
        cursor = focused.flatMap { n in entries.firstIndex { $0.name == n } }
            ?? entries.firstIndex { $0.kind != .parent } ?? 0
        ensureCursorVisible(visibleRows: visibleRows)
    }

    /// Replaces the marks with `names` (those in this folder), keeping the old ones for Restore.
    public func setMarks(_ names: Set<String>) {
        rememberMarks()
        marked = names.intersection(realEntries.map(\.name))
    }

    /// Puts the cursor on the entry with this name, if present.
    public func focus(name: String, visibleRows: Int) {
        if let index = entries.firstIndex(where: { $0.name == name }) {
            setCursor(index, visibleRows: visibleRows)
        }
    }

    /// Marks or unmarks the entry at `index` (used by right-click and right-drag selection).
    public func setMark(_ mark: Bool, at index: Int) {
        guard entries.indices.contains(index), entries[index].kind != .parent else { return }
        let name = entries[index].name
        if mark { marked.insert(name) } else { marked.remove(name) }
    }

    /// "+" / "-": marks (or unmarks) every entry the mask matches. Returns how many matched.
    @discardableResult
    public func setMarks(_ mark: Bool, matching mask: FileMask, folders: Bool = true) -> Int {
        let hits = realEntries.filter { (folders || $0.kind == .file) && mask.matches($0) }.map(\.name)
        rememberMarks()
        if mark { marked.formUnion(hits) } else { marked.subtract(hits) }
        return hits.count
    }

    /// Shift-click: marks every entry from the cursor to `index` (both included, ".." skipped)
    /// and moves the cursor there. Marks outside the range are kept.
    public func markRange(toRow index: Int, visibleRows: Int) {
        guard entries.indices.contains(index) else { return }
        let from = min(cursor, index), to = max(cursor, index)
        for i in from...to { setMark(true, at: i) }
        setCursor(index, visibleRows: visibleRows)
    }

    /// "*": every unmarked file and folder becomes marked and vice versa ("..” excluded).
    public func invertMarks() {
        let all = Set(realEntries.map(\.name))
        rememberMarks()
        marked = all.subtracting(marked)
    }

    /// Size shown for a folder once it has been calculated.
    public func folderSize(for entry: FileEntry) -> Int64? {
        entry.kind == .directory ? folderSizes[entry.name] : nil
    }

    /// Stores a finished folder size. Ignored if the panel has moved to another directory meanwhile.
    public func setFolderSize(_ size: Int64, for name: String, in directory: URL) {
        guard directory.normalizedLocation == self.directory else { return }
        folderSizes[name] = size
    }

    /// Marked entries plus the bytes they add up to (marked folders count once their size is known).
    public var selectionTotals: (files: Int, dirs: Int, bytes: Int64) {
        var files = 0, dirs = 0
        var bytes: Int64 = 0
        for e in realEntries where marked.contains(e.name) {
            if e.kind == .file {
                files += 1
                bytes = bytes.addingSaturated(e.size ?? 0)
            } else {
                dirs += 1
                bytes = bytes.addingSaturated(folderSizes[e.name] ?? 0)
            }
        }
        return (files, dirs, bytes)
    }

    // MARK: Quick search and quick filter

    /// Quick Search rule (as in Total Commander): the name starts with the typed text, ignoring case;
    /// "*" and "?" in the text work as wildcards ("*.jpg" finds any jpg).
    public static func quickMatches(_ name: String, _ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let n = NameMatcher.normalize(name), t = NameMatcher.normalize(text)
        if !t.contains("*") && !t.contains("?") {
            return n.range(of: t, options: [.caseInsensitive, .anchored]) != nil
        }
        var expr = "^"
        for ch in t {
            switch ch {
            case "*": expr += ".*"
            case "?": expr += "."
            default: expr += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return n.range(of: expr, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The next row (after `start` going `forward`, or before it going back) whose name matches;
    /// `start` itself counts when `includingStart`. Wraps around; ".." never matches.
    public func quickSearchIndex(_ text: String, from start: Int, forward: Bool = true, includingStart: Bool = true) -> Int? {
        guard !entries.isEmpty else { return nil }
        let n = entries.count
        let first = includingStart ? 0 : 1
        for step in first..<(n + first) {
            let i = ((forward ? start + step : start - step) % n + n) % n
            let e = entries[i]
            if e.kind != .parent && Self.quickMatches(e.name, text) { return i }
        }
        return nil
    }

    /// Quick Filter: shows only matching entries (".." stays). nil or "" shows everything again.
    /// While filtering, every change puts the cursor on the first match; clearing the filter keeps
    /// the cursor on its entry.
    public func setQuickFilter(_ text: String?, visibleRows: Int) {
        let focused = currentEntry?.name
        quickFilter = (text?.isEmpty ?? true) ? nil : text
        entries = filtered(allEntries)
        let firstMatch = entries.firstIndex { $0.kind != .parent }
        if quickFilter != nil {
            cursor = firstMatch ?? 0
        } else {
            cursor = focused.flatMap { n in entries.firstIndex { $0.name == n } } ?? firstMatch ?? 0
        }
        ensureCursorVisible(visibleRows: visibleRows)
    }

    /// How many entries (besides "..") a filter text would leave.
    public func quickFilterCount(_ text: String) -> Int {
        allEntries.filter { $0.kind != .parent && Self.quickMatches($0.name, text) }.count
    }

    private func filtered(_ list: [FileEntry]) -> [FileEntry] {
        var shown = showFilter == .all ? list : list.filter { $0.kind != .file || showFilter.shows($0) }
        if showsMarkedOnly { shown = shown.filter { $0.kind == .parent || marked.contains($0.name) } }
        guard let f = quickFilter else { return shown }
        return shown.filter { $0.kind == .parent || Self.quickMatches($0.name, f) }
    }

    /// View → Show: All files / Programs / Custom mask. Marks on files it hides are removed,
    /// so nothing invisible is copied or deleted.
    public func setShowFilter(_ filter: PanelShowFilter, visibleRows: Int) {
        let focused = currentEntry?.name
        showFilter = filter
        entries = filtered(allEntries)
        marked = marked.intersection(entries.map(\.name))
        cursor = focused.flatMap { n in entries.firstIndex { $0.name == n } } ?? 0
        ensureCursorVisible(visibleRows: visibleRows)
    }

    /// View → Sort by: sets the column (ascending), keeping the direction if it already sorts by it.
    public func setSort(_ column: SortColumn, visibleRows: Int) {
        guard sortOrder.column != column else { return }
        sort(by: column, visibleRows: visibleRows)
    }

    /// View → Reverse order.
    public func reverseSort(visibleRows: Int) {
        sort(by: sortOrder.column, visibleRows: visibleRows)
    }

    /// Re-reads the folder with another lister (e.g. hidden files shown or not), keeping the cursor.
    public func setLister(_ newLister: DirectoryListing, visibleRows: Int) {
        lister = newLister
        let focused = currentEntry?.name
        _ = load(directory, focusing: focused)
        ensureCursorVisible(visibleRows: visibleRows)
    }

    // MARK: Sorting

    /// Header click: a new column sorts ascending; the current column flips direction.
    /// The cursor stays on the same entry.
    public func sort(by column: SortColumn, visibleRows: Int) {
        if sortOrder.column == column {
            sortOrder.ascending.toggle()
        } else {
            sortOrder = SortOrder(column: column, ascending: true)
        }
        let focused = currentEntry?.name
        let parent = allEntries.first?.kind == .parent ? [allEntries[0]] : []
        allEntries = parent + EntrySorting.sorted(allEntries.filter { $0.kind != .parent }, by: sortOrder)
        entries = filtered(allEntries)
        cursor = focused.flatMap { n in entries.firstIndex { $0.name == n } } ?? 0
        ensureCursorVisible(visibleRows: visibleRows)
    }

    /// The "\" button: jump to the root of the file system.
    @discardableResult
    public func goToRoot(visibleRows: Int) -> OpenResult {
        go(to: URL(fileURLWithPath: "/"), visibleRows: visibleRows)
    }

    /// The "~" button: jump to the user's home folder.
    @discardableResult
    public func goHome(visibleRows: Int) -> OpenResult {
        go(to: FileManager.default.homeDirectoryForCurrentUser, visibleRows: visibleRows)
    }

    /// The downloads button: jump to the user's Downloads folder.
    @discardableResult
    public func goDownloads(visibleRows: Int) -> OpenResult {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return go(to: downloads, visibleRows: visibleRows)
    }

    /// Jumps to any directory; does nothing if the panel is already there.
    @discardableResult
    public func go(to url: URL, visibleRows: Int) -> OpenResult {
        let target = url.normalizedLocation
        guard target != directory || virtualTitle != nil else { return .none }
        let result = load(target, focusing: nil)
        ensureCursorVisible(visibleRows: visibleRows)
        return result
    }

    // MARK: Navigation

    /// Enter: descend into a directory, go up on "..", or report a file to open.
    @discardableResult
    public func openCurrent(visibleRows: Int) -> OpenResult {
        guard let entry = currentEntry else { return .none }
        switch entry.kind {
        case .parent:
            return goUp(visibleRows: visibleRows)
        case .directory:
            let result = load(entry.url.normalizedLocation, focusing: nil)
            ensureCursorVisible(visibleRows: visibleRows)
            return result
        case .file:
            if entry.url.isFileURL, entry.url.pathExtension.lowercased() == "zip", !isInsideZip {
                let result = load(entry.url.normalizedLocation, focusing: nil)
                ensureCursorVisible(visibleRows: visibleRows)
                return result
            }
            return .file(entry.url)
        }
    }

    /// Right arrow: like Enter, but only for folders and ".."; on a file nothing happens.
    @discardableResult
    public func enterCurrentFolder(visibleRows: Int) -> OpenResult {
        guard let entry = currentEntry, entry.kind != .file else { return .none }
        return openCurrent(visibleRows: visibleRows)
    }

    /// Backspace / "..": go to the parent and put the cursor on the directory we came from.
    @discardableResult
    public func goUp(visibleRows: Int) -> OpenResult {
        if virtualTitle != nil {
            // Leaving the search results: back to the folder they were shown over.
            virtualTitle = nil
            let result = load(directory, focusing: nil)
            ensureCursorVisible(visibleRows: visibleRows)
            return result
        }
        guard !isRoot(directory) else { return .none }
        let child = directory.lastPathComponent
        let result = load(directory.deletingLastPathComponent().normalizedLocation, focusing: child)
        ensureCursorVisible(visibleRows: visibleRows)
        return result
    }

    /// Re-reads the current directory, keeping the cursor on the same name when it still exists.
    public func reload(visibleRows: Int) {
        if virtualTitle != nil {
            // Search results: drop entries whose files are gone, refresh the rest.
            let focus = currentEntry?.name
            let kept = allEntries.filter { $0.kind == .parent || FileManager.default.fileExists(atPath: $0.url.path) }
            allEntries = kept
            entries = filtered(kept)
            marked = marked.intersection(Set(kept.map(\.name)))
            cursor = focus.flatMap { n in entries.firstIndex { $0.name == n } } ?? min(cursor, max(0, entries.count - 1))
            ensureCursorVisible(visibleRows: visibleRows)
            return
        }
        let focus = currentEntry?.name
        let oldCursor = cursor
        if case .failed = load(directory, focusing: focus) { return }
        if focus == nil || currentEntry?.name != focus {
            cursor = min(oldCursor, max(0, entries.count - 1))
        }
        ensureCursorVisible(visibleRows: visibleRows)
    }

    /// "Feed to listbox": shows `files` (real paths) as the panel's listing. Names are shown relative
    /// to the current folder when inside it, else as full paths, so equal names stay apart.
    public func showSearchResults(_ files: [URL], title: String, visibleRows: Int) {
        let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        var list: [FileEntry] = []
        var seen = Set<String>()
        for url in files {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            let name = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
            guard seen.insert(name).inserted else { continue }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            list.append(FileEntry(name: name, url: url, kind: isDir ? .directory : .file,
                                  size: isDir ? nil : Int64(st.st_size),
                                  modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                                  isSymlink: (st.st_mode & S_IFMT) == S_IFLNK, permissions: Int(st.st_mode & 0o777)))
        }
        virtualTitle = title
        quickFilter = nil
        showsMarkedOnly = false
        allEntries = [FileEntry(name: "..", url: directory, kind: .parent)] + EntrySorting.sorted(list, by: sortOrder)
        entries = allEntries
        marked = []
        folderSizes = [:]
        errorMessage = nil
        cursor = min(1, entries.count - 1)
        scrollTop = 0
        ensureCursorVisible(visibleRows: visibleRows)
        onDirectoryChange?()
    }

    @discardableResult
    private func load(_ url: URL, focusing name: String?) -> OpenResult {
        virtualTitle = nil
        let listed: [FileEntry]
        do {
            listed = try lister.entries(in: url)
        } catch {
            errorMessage = Self.describe(error, url: url)
            return .failed(errorMessage!)
        }
        var all = EntrySorting.sorted(listed, by: sortOrder)
        if !isRoot(url) { all.insert(FileEntry.parent(of: url), at: 0) }
        let changedDirectory = url != directory
        directory = url
        if changedDirectory {
            quickFilter = nil
            showsMarkedOnly = false
        }
        allEntries = all
        entries = filtered(all)
        errorMessage = nil
        cursor = name.flatMap { n in entries.firstIndex { $0.name == n } } ?? 0
        if changedDirectory {
            scrollTop = 0
            marked = []
            folderSizes = [:]
            onDirectoryChange?()
        } else {
            // Reload: keep marks and sizes for entries that still exist.
            let names = Set(all.map(\.name))
            marked = marked.intersection(names)
            folderSizes = folderSizes.filter { names.contains($0.key) }
        }
        return .navigated
    }

    /// True while the panel shows a remote (FTP) folder.
    public var isRemote: Bool { directory.isRemoteLocation }
    public var isInsideZip: Bool { ZipArchive.split(directory) != nil }

    /// Swap panels (Total Commander's Ctrl+U): the two panels trade everything they show —
    /// folder, source, cursor, marks, sort order, filter, folder sizes and Find Files results.
    public func exchangeContents(with other: PanelModel) {
        swap(&directory, &other.directory)
        swap(&entries, &other.entries)
        swap(&allEntries, &other.allEntries)
        swap(&virtualTitle, &other.virtualTitle)
        swap(&quickFilter, &other.quickFilter)
        swap(&showsMarkedOnly, &other.showsMarkedOnly)
        swap(&previousMarks, &other.previousMarks)
        swap(&showFilter, &other.showFilter)
        swap(&cursor, &other.cursor)
        swap(&scrollTop, &other.scrollTop)
        swap(&errorMessage, &other.errorMessage)
        swap(&sortOrder, &other.sortOrder)
        swap(&marked, &other.marked)
        swap(&folderSizes, &other.folderSizes)
        swap(&lister, &other.lister)
        // Work tied to the old side (folder sizing) stops, as on any change of folder.
        onDirectoryChange?()
        other.onDirectoryChange?()
    }

    /// Shows another source (an FTP session, or the local disk again) starting at `url`.
    /// The listing for `url` must be available from the new lister.
    @discardableResult
    public func switchSource(_ newLister: DirectoryListing, to url: URL, visibleRows: Int) -> OpenResult {
        let old = lister
        lister = newLister
        let result = load(url.normalizedLocation, focusing: nil)
        if case .failed = result { lister = old }
        ensureCursorVisible(visibleRows: visibleRows)
        return result
    }

    private func isRoot(_ url: URL) -> Bool {
        url.path == "/"
    }

    private static func describe(_ error: Error, url: URL) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError {
            return "Access denied: \(url.lastPathComponent)"
        }
        return "Cannot read \(url.lastPathComponent): \(ns.localizedDescription)"
    }
}

/// View → Show (Total Commander's Ctrl+F10 / F11 / F12).
public enum PanelShowFilter: Equatable {
    case all
    /// Programs: executable files and the usual macOS program/script types.
    case programs
    /// A user-defined mask such as "*.txt *.md" or "*.* | *.tmp".
    case mask(String)

    static let programExtensions: Set<String> = ["app", "command", "tool", "sh", "bash", "zsh", "py", "pl", "rb", "pkg", "jar"]
    private static var cachedMask: (String, FileMask)?

    public func shows(_ entry: FileEntry) -> Bool {
        switch self {
        case .all: return true
        case .programs:
            if let p = entry.permissions, p & 0o111 != 0 { return true }
            return Self.programExtensions.contains((entry.name as NSString).pathExtension.lowercased())
        case .mask(let text):
            if let (cachedText, mask) = Self.cachedMask, cachedText == text {
                return mask.matches(entry)
            }
            let m = FileMask(text)
            Self.cachedMask = (text, m)
            return m.matches(entry)
        }
    }

    /// Shown in the panel footer while active.
    public var label: String? {
        switch self {
        case .all: return nil
        case .programs: return "Programs"
        case .mask(let text): return text
        }
    }

    /// The mask string shown in the path bar, e.g. "*.*" or "*.txt".
    public var maskString: String {
        switch self {
        case .all: return "*.*"
        case .programs: return "Programs"
        case .mask(let text): return text
        }
    }
}
