import Foundation

/// A key plus modifiers, independent of AppKit so it can be stored and tested.
/// `keyCode` is the hardware virtual key code (layout-independent, like NSEvent.keyCode).
public struct KeyCombo: Hashable, Codable {
    public struct Modifiers: OptionSet, Hashable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(_ keyCode: UInt16, _ modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// e.g. "⌥2", "⌘↑", "Space", "⇧⇥".
    public var displayName: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (KeyCode.names[keyCode] ?? "Key \(keyCode)")
    }

    /// Combos the app menu already uses; they cannot be reassigned to panel actions.
    public var isReservedByMenu: Bool {
        modifiers == .command && [KeyCode.q, KeyCode.h, KeyCode.m, KeyCode.comma,
                                  KeyCode.z, KeyCode.x, KeyCode.c, KeyCode.v, KeyCode.a].contains(keyCode)
    }
}

/// Virtual key codes (US ANSI positions) and their display names.
public enum KeyCode {
    public static let returnKey: UInt16 = 36, tab: UInt16 = 48, space: UInt16 = 49, delete: UInt16 = 51
    public static let escape: UInt16 = 53, keypadEnter: UInt16 = 76, keypadMultiply: UInt16 = 67
    public static let keypadPlus: UInt16 = 69, keypadMinus: UInt16 = 78, equal: UInt16 = 24, minus: UInt16 = 27
    public static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    public static let home: UInt16 = 115, end: UInt16 = 119, pageUp: UInt16 = 116, pageDown: UInt16 = 121
    public static let forwardDelete: UInt16 = 117
    public static let one: UInt16 = 18, two: UInt16 = 19
    public static let three: UInt16 = 20, f3: UInt16 = 99
    public static let five: UInt16 = 23, six: UInt16 = 22, seven: UInt16 = 26, eight: UInt16 = 28
    public static let f5: UInt16 = 96, f6: UInt16 = 97, f7: UInt16 = 98, f8: UInt16 = 100
    public static let q: UInt16 = 12, w: UInt16 = 13, h: UInt16 = 4, m: UInt16 = 46, comma: UInt16 = 43
    /// Edit menu: ⌘Z ⌘X ⌘C ⌘V ⌘A.
    public static let z: UInt16 = 6, x: UInt16 = 7, c: UInt16 = 8, v: UInt16 = 9, a: UInt16 = 0
    public static let j: UInt16 = 38, k: UInt16 = 40, l: UInt16 = 37, s: UInt16 = 1

    static let names: [UInt16: String] = {
        var n: [UInt16: String] = [
            returnKey: "↩", tab: "⇥", space: "Space", delete: "⌫", escape: "Esc", keypadEnter: "⌤",
            keypadMultiply: "Num *", keypadPlus: "Num +", keypadMinus: "Num -",
            left: "←", right: "→", down: "↓", up: "↑", home: "Home", end: "End",
            pageUp: "PgUp", pageDown: "PgDn", forwardDelete: "⌦",
            27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
        ]
        let letters: [(UInt16, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
            (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"),
            (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
        ]
        let digits: [(UInt16, String)] = [
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
        ]
        let fkeys: [(UInt16, String)] = [
            (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"),
            (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
        ]
        for (code, name) in letters + digits + fkeys { n[code] = name }
        return n
    }()
}

/// Everything the panels can do from the keyboard. Each one is listed on the Shortcuts page.
public enum CommandAction: String, CaseIterable, Codable {
    case cursorUp, cursorDown, pageUp, pageDown, firstItem, lastItem
    case open, enterFolder, parentFolder, switchPanel
    case toggleSelection, invertSelection, selectByMask, deselectByMask
    case leftLocationMenu, rightLocationMenu
    case goHome, goDownloads, goRoot
    case view, copy, move, newFolder, delete
    case findFiles
    case quickFilter, reopenQuickSearch
    case synchronizeDirs
    case ftpConnect, ftpNewConnection, ftpDisconnect, ftpTransfers, refresh
    case swapPanels
    case openTerminal
    case openInFinder
    case selectAll, deselectAll, selectSameExtension, deselectSameExtension, restoreSelection, showMarkedOnly
    case copyNames, copyPaths, copyNamesWithDetails, copyPathsWithDetails
    case compareByDate, compareBySize
    case directoryHotlist
    case multiRename
    case packFiles
    case unpackFiles
    case changeAttributes
    case renameInPlace, deletePermanently
    case newTab, closeTab, nextTab, previousTab
    case sortByName, sortByExtension, sortByDate, sortBySize, sortUnsorted, reverseOrder
    case showAllFiles, showPrograms, showCustomFilter
    case toggleHiddenFiles, toggleFunctionKeyBar, toggleFolderBrackets

    private static let labels: [CommandAction: String] = [
        .cursorUp: "Cursor up",
        .cursorDown: "Cursor down",
        .pageUp: "Page up",
        .pageDown: "Page down",
        .firstItem: "First item",
        .lastItem: "Last item",
        .open: "Open file / enter folder",
        .enterFolder: "Enter folder (ignores files)",
        .parentFolder: "Parent folder",
        .switchPanel: "Switch panel",
        .toggleSelection: "Select / deselect (and folder size)",
        .invertSelection: "Invert selection (*)",
        .selectByMask: "Select by mask (+)",
        .deselectByMask: "Deselect by mask (-)",
        .leftLocationMenu: "Location menu, left panel",
        .rightLocationMenu: "Location menu, right panel",
        .goHome: "Go to home folder (~)",
        .goDownloads: "Go to Downloads folder",
        .goRoot: "Go to root folder (\\)",
        .view: "View (F3, Lister)",
        .copy: "Copy (F5)",
        .move: "Move / rename (F6)",
        .newFolder: "New folder (F7)",
        .delete: "Delete to Trash (F8)",
        .findFiles: "Find files (Alt+F7)",
        .quickFilter: "Quick filter (Ctrl+S)",
        .reopenQuickSearch: "Reopen last quick search",
        .synchronizeDirs: "Synchronize directories",
        .ftpConnect: "FTP connect (connection manager)",
        .ftpNewConnection: "FTP new connection",
        .ftpDisconnect: "FTP disconnect",
        .ftpTransfers: "Copy / move queue window",
        .sortByName: "Sort by name",
        .sortByExtension: "Sort by extension",
        .sortByDate: "Sort by date/time",
        .sortBySize: "Sort by size",
        .sortUnsorted: "Unsorted (file system order)",
        .reverseOrder: "Reverse sort order",
        .showAllFiles: "Show all files (remove the Show filter)",
        .showPrograms: "Show programs only",
        .showCustomFilter: "Show files matching a mask…",
        .toggleHiddenFiles: "Show hidden (dot) files",
        .toggleFunctionKeyBar: "Show the function key button bar",
        .toggleFolderBrackets: "Show [brackets] around folder names",
        .openTerminal: "Open terminal here (in the active panel's folder)",
        .openInFinder: "Open this folder in Finder (like “open .” in Terminal)",
        .selectAll: "Select all (Ctrl+Num+)",
        .deselectAll: "Unselect all (Ctrl+Num-)",
        .selectSameExtension: "Select all files with the same extension",
        .deselectSameExtension: "Unselect all files with the same extension",
        .restoreSelection: "Restore the previous selection",
        .showMarkedOnly: "Show only the selected files (toggle)",
        .copyNames: "Copy selected names to the clipboard",
        .copyPaths: "Copy selected names with full paths to the clipboard",
        .copyNamesWithDetails: "Copy selected names with all details to the clipboard (table)",
        .copyPathsWithDetails: "Copy selected full paths with all details to the clipboard (table)",
        .compareByDate: "Compare directories: select newer and missing files",
        .compareBySize: "Compare directories: select files that differ in size, and missing ones",
        .directoryHotlist: "Directory hotlist: quick locations (Ctrl+D)",
        .multiRename: "Multi-Rename Tool (Ctrl+M)",
        .packFiles: "Pack files…",
        .unpackFiles: "Unpack files…",
        .changeAttributes: "Change attributes / permissions (chmod)…",
        .renameInPlace: "Rename in place (Shift+F6)",
        .deletePermanently: "Delete permanently, without the Trash (Shift+F8)",
        .newTab: "New tab (same folder)",
        .closeTab: "Close tab",
        .nextTab: "Next tab",
        .previousTab: "Previous tab",
        .swapPanels: "Swap panels (left ↔ right, as Ctrl+U in Total Commander)",
        .refresh: "Refresh (re-read folder)",
    ]

    public var label: String { Self.labels[self] ?? rawValue }

    private static let buttonTitles: [CommandAction: String] = [
        .view: "View", .copy: "Copy", .move: "Move", .newFolder: "NewFolder",
        .delete: "Delete", .ftpDisconnect: "FTP Disconnect",
    ]

    /// Short name for the function key bar at the bottom of the window.
    public var buttonTitle: String { Self.buttonTitles[self] ?? label }
}

/// Which keys trigger which action. An action may have several keys; a key belongs to one action.
public struct KeyBindings: Equatable, Codable {
    public private(set) var map: [CommandAction: [KeyCombo]]

    public init(_ map: [CommandAction: [KeyCombo]]) {
        self.map = map
    }

    public static let standard = KeyBindings([
        // Vim keys work alongside the arrows: h ← parent, j ↓, k ↑, l → enter.
        .cursorUp: [KeyCombo(KeyCode.up), KeyCombo(KeyCode.k)],
        .cursorDown: [KeyCombo(KeyCode.down), KeyCombo(KeyCode.j)],
        .pageUp: [KeyCombo(KeyCode.pageUp)],
        .pageDown: [KeyCombo(KeyCode.pageDown)],
        .firstItem: [KeyCombo(KeyCode.home)],
        .lastItem: [KeyCombo(KeyCode.end)],
        .open: [KeyCombo(KeyCode.returnKey), KeyCombo(KeyCode.keypadEnter), KeyCombo(KeyCode.down, .command)],
        .enterFolder: [KeyCombo(KeyCode.right), KeyCombo(KeyCode.l)],
        .parentFolder: [KeyCombo(KeyCode.delete), KeyCombo(KeyCode.left), KeyCombo(KeyCode.h), KeyCombo(KeyCode.up, .command)],
        .switchPanel: [KeyCombo(KeyCode.tab), KeyCombo(KeyCode.tab, .shift)],
        .toggleSelection: [KeyCombo(KeyCode.space)],
        // ⇧8 is Delete permanently (Total Commander's Shift+F8); invert stays on Num * and ⌃⇧8.
        .invertSelection: [KeyCombo(KeyCode.keypadMultiply), KeyCombo(KeyCode.eight, [.control, .shift])],
        // No number pad on Mac keyboards: "+" is ⇧= (plain "=" too, same key), "-" is the "-" key.
        .selectByMask: [KeyCombo(KeyCode.equal, .shift), KeyCombo(KeyCode.equal), KeyCombo(KeyCode.keypadPlus)],
        .deselectByMask: [KeyCombo(KeyCode.minus), KeyCombo(KeyCode.keypadMinus)],
        .leftLocationMenu: [KeyCombo(KeyCode.one, .option)],
        .rightLocationMenu: [KeyCombo(KeyCode.two, .option)],
        .goHome: [],
        .goDownloads: [],
        .goRoot: [],
        .view: [KeyCombo(KeyCode.three), KeyCombo(KeyCode.f3)],
        .copy: [KeyCombo(KeyCode.five), KeyCombo(KeyCode.f5)],
        .move: [KeyCombo(KeyCode.six), KeyCombo(KeyCode.f6)],
        .newFolder: [KeyCombo(KeyCode.seven), KeyCombo(KeyCode.f7)],
        .delete: [KeyCombo(KeyCode.eight), KeyCombo(KeyCode.f8)],
        .findFiles: [KeyCombo(KeyCode.seven, .option), KeyCombo(KeyCode.f7, .option)],
        .quickFilter: [KeyCombo(KeyCode.s, .control)],
        .reopenQuickSearch: [KeyCombo(KeyCode.s, [.control, .shift])],
        .synchronizeDirs: [],   // Commands menu; assign a key in Options → Shortcuts if wanted
        // Total Commander: Ctrl+F FTP connect, Ctrl+N new connection, Ctrl+Shift+F disconnect, Ctrl+R reread.
        .ftpConnect: [KeyCombo(3, .control)],
        .ftpNewConnection: [KeyCombo(45, .control)],
        .ftpDisconnect: [KeyCombo(3, [.control, .shift])],
        .ftpTransfers: [],
        .swapPanels: [KeyCombo(32, .control)],
        .openTerminal: [KeyCombo(17, [.control, .shift])],
        .openInFinder: [KeyCombo(31, [.control, .shift])],   // ⌃⇧O
        // Total Commander's Ctrl+Num+ / Ctrl+Num- (no number pad: ⌃= is ⌃+, and ⌃-).
        .selectAll: [KeyCombo(KeyCode.equal, .control), KeyCombo(KeyCode.equal, [.control, .shift]), KeyCombo(KeyCode.keypadPlus, .control)],
        .deselectAll: [KeyCombo(KeyCode.minus, .control), KeyCombo(KeyCode.keypadMinus, .control)],
        .selectSameExtension: [],
        .deselectSameExtension: [],
        .restoreSelection: [],
        .showMarkedOnly: [],
        .copyNames: [],
        .copyPaths: [],
        .copyNamesWithDetails: [],
        .copyPathsWithDetails: [],
        .compareByDate: [],
        .compareBySize: [],
        .directoryHotlist: [KeyCombo(2, .control)],   // ⌃D, as in Total Commander
        .multiRename: [KeyCombo(46, .control)],       // ⌃M
        .packFiles: [KeyCombo(35, [.option, .command])],   // ⌥⌘P
        .unpackFiles: [KeyCombo(32, [.option, .command])], // ⌥⌘U
        .renameInPlace: [KeyCombo(KeyCode.six, .shift), KeyCombo(KeyCode.f6, .shift)],
        .deletePermanently: [KeyCombo(KeyCode.eight, .shift), KeyCombo(KeyCode.f8, .shift)],
        // Total Commander: Ctrl+T new tab, Ctrl+W / ⌘W close, Ctrl+Tab / Ctrl+Shift+Tab switch.
        .newTab: [KeyCombo(17, .control)],
        .closeTab: [KeyCombo(13, .control), KeyCombo(KeyCode.w, .command)],
        .nextTab: [KeyCombo(KeyCode.tab, .control)],
        .previousTab: [KeyCombo(KeyCode.tab, [.control, .shift])],
        // Total Commander's Ctrl+F3…F7 (sort) and Ctrl+F10…F12 (show) without F keys:
        // ⌃3…⌃7 sort, ⌃8 / ⌃9 / ⌃0 show all / programs / custom.
        .sortByName: [KeyCombo(20, .control)],
        .sortByExtension: [KeyCombo(21, .control)],
        .sortByDate: [KeyCombo(23, .control)],
        .sortBySize: [KeyCombo(22, .control)],
        .sortUnsorted: [KeyCombo(26, .control)],
        .reverseOrder: [],
        .showAllFiles: [KeyCombo(28, .control)],
        .showPrograms: [KeyCombo(25, .control)],
        .showCustomFilter: [KeyCombo(29, .control)],
        .toggleHiddenFiles: [KeyCombo(47, [.command, .shift])],    // Finder's ⌘⇧.
        .toggleFunctionKeyBar: [],
        .toggleFolderBrackets: [],
        .refresh: [KeyCombo(KeyCode.two), KeyCombo(15, .control)],
    ])

    public func keys(for action: CommandAction) -> [KeyCombo] {
        map[action] ?? []
    }

    public func action(for combo: KeyCombo) -> CommandAction? {
        CommandAction.allCases.first { keys(for: $0).contains(combo) }
    }

    /// Adds `combo` to `action`, taking it away from whichever action had it.
    /// Returns that previous owner, if any.
    @discardableResult
    public mutating func add(_ combo: KeyCombo, to action: CommandAction) -> CommandAction? {
        let previous = self.action(for: combo)
        if let previous = previous, previous != action { remove(combo, from: previous) }
        appendComboIfMissing(combo, to: action)
        return previous == action ? nil : previous
    }

    private mutating func appendComboIfMissing(_ combo: KeyCombo, to action: CommandAction) {
        if !keys(for: action).contains(combo) {
            map[action] = keys(for: action) + [combo]
        }
    }

    public mutating func remove(_ combo: KeyCombo, from action: CommandAction) {
        map[action] = keys(for: action).filter { $0 != combo }
    }

    // Stored as {"cursorUp": [{"keyCode":126,"modifiers":0}], ...}. Unknown actions are ignored and
    // actions missing from saved data keep their default keys (new actions get theirs on upgrade).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: [KeyCombo]].self)
        var map = KeyBindings.standard.map
        for (name, combos) in raw {
            if let action = CommandAction(rawValue: name) { map[action] = combos }
        }
        self.map = map
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) }))
    }
}
