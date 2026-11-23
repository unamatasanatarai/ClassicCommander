import Foundation

/// How sizes are written in the Copy / Move dialogs and the queue.
public enum SizeFormat: String, Codable, CaseIterable {
    /// "2.042.908 bytes"
    case bytes
    /// "1,9 MB" (1 KB = 1024 bytes)
    case readable

    public var label: String { self == .bytes ? "Bytes (2.042.908 bytes)" : "Readable (1,9 MB)" }
}

/// Options from the Display page.
public struct DisplayOptions: Equatable, Codable {
    /// Show folders as "[name]", Total Commander's "Show square brackets around directory names".
    public var showFolderBrackets: Bool
    /// The "5 Copy  6 Move  7 NewFolder  8 Delete" button bar under the panels.
    public var showFunctionKeyBar: Bool
    /// The floppy icon in the menu bar.
    public var showStatusBarIcon: Bool
    /// View → Hidden files: list dotfiles (".git", ".zshrc").
    public var showHiddenFiles: Bool = false
    /// Sizes in the Copy / Move dialogs, "target file exists" and the queue.
    public var sizeFormat: SizeFormat = .readable
    /// The tab bar above each panel: with two or more tabs, or always.
    public var tabBar: TabBarMode = .whenSeveral

    public init(showFolderBrackets: Bool = true, showFunctionKeyBar: Bool = true, showStatusBarIcon: Bool = true,
                showHiddenFiles: Bool = false, sizeFormat: SizeFormat = .readable) {
        self.sizeFormat = sizeFormat
        self.showHiddenFiles = showHiddenFiles
        self.showFolderBrackets = showFolderBrackets
        self.showFunctionKeyBar = showFunctionKeyBar
        self.showStatusBarIcon = showStatusBarIcon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showFolderBrackets = try c.decodeIfPresent(Bool.self, forKey: .showFolderBrackets) ?? true
        showFunctionKeyBar = try c.decodeIfPresent(Bool.self, forKey: .showFunctionKeyBar) ?? true
        showStatusBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showStatusBarIcon) ?? true
        showHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
        sizeFormat = (try? c.decodeIfPresent(SizeFormat.self, forKey: .sizeFormat)) ?? .readable
        tabBar = (try? c.decodeIfPresent(TabBarMode.self, forKey: .tabBar)) ?? .whenSeveral
    }

    public static let standard = DisplayOptions()
}

/// The panel that Finder's "Open With → ClassicCommander" shows things in.
public enum FinderPanel: String, Codable, CaseIterable {
    case left, right

    public var label: String { self == .left ? "Left panel" : "Right panel" }
}

/// Options from the Operation page: what Space does besides toggling the selection.
public struct OperationOptions: Equatable, Codable {
    /// Space on a folder works out the total size of its contents and shows it in the Size column
    /// (until then a folder shows "<DIR>").
    public var spaceCalculatesFolderSize: Bool
    /// After Space toggles the selection, the cursor moves to the next row.
    public var spaceMovesCursorDown: Bool
    /// FTP/SFTP: files transferring at the same time, in total…
    public var maxTransfers: Int
    /// …of which uploads and downloads (0 = no separate limit: the total applies).
    public var maxUploads: Int
    public var maxDownloads: Int
    /// "Open terminal here": the terminal app, and its arguments with {dir} (empty: open the folder with it).
    public var terminalApp: String
    public var terminalArguments: String
    /// Select group, same extension and Compare directories: also hide every entry they didn't mark.
    public var selectionHidesOthers: Bool
    /// Holding the right mouse button this long (seconds) opens the context menu.
    public var contextMenuHold: Double

    /// Finder's "Open With → ClassicCommander" opens here.
    public var finderOpensIn: FinderPanel = .left
    /// + / − (select / unselect by mask) also mark folders, not only files.
    public var maskSelectsFolders = true
    /// ⇧6 Rename preselects the extension too (otherwise only the name before it).
    public var renameSelectsExtension = false
    /// Panels re-read their folder when files in it change (folders on this Mac).
    public var autoRefresh: AutoRefresh = .structure

    public static let contextMenuHoldRange: ClosedRange<Double> = 0.2...10

    public init(spaceCalculatesFolderSize: Bool = true, spaceMovesCursorDown: Bool = true,
                maxTransfers: Int = 3, maxUploads: Int = 0, maxDownloads: Int = 0,
                terminalApp: String = TerminalLauncher.defaultApp, terminalArguments: String = "",
                selectionHidesOthers: Bool = false, contextMenuHold: Double = 1) {
        self.selectionHidesOthers = selectionHidesOthers
        self.contextMenuHold = contextMenuHold
        self.terminalApp = terminalApp
        self.terminalArguments = terminalArguments
        self.spaceCalculatesFolderSize = spaceCalculatesFolderSize
        self.spaceMovesCursorDown = spaceMovesCursorDown
        self.maxTransfers = maxTransfers
        self.maxUploads = maxUploads
        self.maxDownloads = maxDownloads
    }

    public var transferLimits: TransferLimits {
        TransferLimits(total: maxTransfers, uploads: maxUploads, downloads: maxDownloads)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaceCalculatesFolderSize = try c.decodeIfPresent(Bool.self, forKey: .spaceCalculatesFolderSize) ?? true
        spaceMovesCursorDown = try c.decodeIfPresent(Bool.self, forKey: .spaceMovesCursorDown) ?? true
        maxTransfers = min(32, max(1, (try? c.decodeIfPresent(Int.self, forKey: .maxTransfers)) ?? 3))
        maxUploads = min(32, max(0, (try? c.decodeIfPresent(Int.self, forKey: .maxUploads)) ?? 0))
        maxDownloads = min(32, max(0, (try? c.decodeIfPresent(Int.self, forKey: .maxDownloads)) ?? 0))
        terminalApp = (try? c.decodeIfPresent(String.self, forKey: .terminalApp)) ?? TerminalLauncher.defaultApp
        terminalArguments = (try? c.decodeIfPresent(String.self, forKey: .terminalArguments)) ?? ""
        selectionHidesOthers = (try? c.decodeIfPresent(Bool.self, forKey: .selectionHidesOthers)) ?? false
        let hold = (try? c.decodeIfPresent(Double.self, forKey: .contextMenuHold)) ?? 1
        contextMenuHold = min(Self.contextMenuHoldRange.upperBound, max(Self.contextMenuHoldRange.lowerBound, hold))
        finderOpensIn = (try? c.decodeIfPresent(FinderPanel.self, forKey: .finderOpensIn)) ?? .left
        maskSelectsFolders = (try? c.decodeIfPresent(Bool.self, forKey: .maskSelectsFolders)) ?? true
        renameSelectsExtension = (try? c.decodeIfPresent(Bool.self, forKey: .renameSelectsExtension)) ?? false
        autoRefresh = (try? c.decodeIfPresent(AutoRefresh.self, forKey: .autoRefresh)) ?? .structure
    }

    public static let standard = OperationOptions()
}

/// Options → Quick Search: which keys start Quick Search when typed with a letter.
public struct QuickSearchOptions: Equatable, Codable {
    public enum Activation: String, Codable, CaseIterable {
        case controlOption, option, lettersOnly, off

        public var label: String {
            switch self {
            case .controlOption: return "⌃⌥ + letters"
            case .option: return "⌥ + letters"
            case .lettersOnly: return "Letters alone (plain-letter shortcuts such as h j k l are off)"
            case .off: return "Off (only ⌃S)"
            }
        }
    }

    public var activation: Activation

    public init(activation: Activation = .controlOption) {
        self.activation = activation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activation = (try? c.decodeIfPresent(Activation.self, forKey: .activation)).flatMap { $0 } ?? .controlOption
    }

    public static let standard = QuickSearchOptions()
}

/// A folder saved in the directory hotlist (the ▼ on the path bar, ⌃D), as in Total Commander.
public struct QuickLocation: Equatable, Codable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Everything on the Options dialog.
public struct Settings: Equatable {
    public var theme: Theme
    public var display: DisplayOptions
    public var operation: OperationOptions
    public var keys: KeyBindings
    public var quickSearch: QuickSearchOptions
    /// The directory hotlist, in the order shown.
    public var quickLocations: [QuickLocation]

    public init(theme: Theme = .standard, display: DisplayOptions = .standard,
                operation: OperationOptions = .standard, keys: KeyBindings = .standard,
                quickSearch: QuickSearchOptions = .standard, quickLocations: [QuickLocation] = []) {
        self.quickLocations = quickLocations
        self.theme = theme
        self.display = display
        self.operation = operation
        self.keys = keys
        self.quickSearch = quickSearch
    }

    public static let standard = Settings()
}

/// Exported settings: one readable JSON file with every section of the Options dialog.
///   { "format": "ClassicCommander settings", "version": 1, "theme": {…}, "display": {…},
///     "operation": {…}, "keys": {…} }
/// On import, sections missing from the file keep the current values, and unknown keys are ignored,
/// so files from older or newer versions still load.
public enum SettingsFile {
    public static let format = "ClassicCommander settings"
    public static let version = 1

    private struct File: Codable {
        var format: String
        var version: Int
        var theme: Theme?
        var display: DisplayOptions?
        var operation: OperationOptions?
        var keys: KeyBindings?
        var quickSearch: QuickSearchOptions?
        var quickLocations: [QuickLocation]?
    }

    public static func export(_ settings: Settings) throws -> Data {
        let file = File(format: format, version: version, theme: settings.theme, display: settings.display,
                        operation: settings.operation, keys: settings.keys, quickSearch: settings.quickSearch,
                        quickLocations: settings.quickLocations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// Reads an exported file over `current`. Throws a readable message for anything else.
    public static func importing(_ data: Data, onto current: Settings) throws -> Settings {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw SearchValidationError(message: "This is not a ClassicCommander settings file (or it is damaged).")
        }
        guard file.format == format else {
            throw SearchValidationError(message: "This is not a ClassicCommander settings file.")
        }
        var s = current
        if let t = file.theme { s.theme = t }
        if let d = file.display { s.display = d }
        if let o = file.operation { s.operation = o }
        if let k = file.keys { s.keys = k }
        if let q = file.quickSearch { s.quickSearch = q }
        if let l = file.quickLocations { s.quickLocations = l }
        return s
    }
}

/// Persists the settings in UserDefaults (one key per section, so a bad or old section only
/// resets itself) and posts `didChange` whenever a save actually changes something.
public final class SettingsStore {
    public static let didChange = Notification.Name("ClassicCommander.SettingsStoreDidChange")

    public private(set) var settings: Settings
    private let defaults: UserDefaults

    private enum Key {
        static let theme = "colorTheme"
        static let display = "displayOptions"
        static let operation = "operationOptions"
        static let keys = "keyBindings"
        static let quickSearch = "quickSearchOptions"
        static let quickLocations = "quickLocations"
        static let headerMigration = "migrations.totalCommanderHeader"
        static let holdMigration = "migrations.contextMenuHold1s"
        static func lastFolder(_ side: CommanderModel.Side) -> String { side == .left ? "lastFolder.left" : "lastFolder.right" }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var theme = Self.load(Theme.self, Key.theme, defaults) ?? .standard
        // One-time: themes saved with the old blue column header get Total Commander's grey header.
        if !defaults.bool(forKey: Key.headerMigration) {
            defaults.set(true, forKey: Key.headerMigration)
            if theme.headerBackground == RGBColor(hex: "#0000A8") {
                theme.headerBackground = Theme.classicBlue.headerBackground
                theme.headerText = Theme.classicBlue.headerText
                if let data = try? JSONEncoder().encode(theme) { defaults.set(data, forKey: Key.theme) }
            }
        }
        var operation = Self.load(OperationOptions.self, Key.operation, defaults) ?? .standard
        // One-time: the long right-click went from 3 s to 1 s by default; an untouched 3 s follows.
        if !defaults.bool(forKey: Key.holdMigration) {
            defaults.set(true, forKey: Key.holdMigration)
            if operation.contextMenuHold == 3 {
                operation.contextMenuHold = 1
                if let data = try? JSONEncoder().encode(operation) { defaults.set(data, forKey: Key.operation) }
            }
        }
        settings = Settings(
            theme: theme,
            display: Self.load(DisplayOptions.self, Key.display, defaults) ?? .standard,
            operation: operation,
            keys: Self.load(KeyBindings.self, Key.keys, defaults) ?? .standard,
            quickSearch: Self.load(QuickSearchOptions.self, Key.quickSearch, defaults) ?? .standard,
            quickLocations: Self.load([QuickLocation].self, Key.quickLocations, defaults) ?? []
        )
    }

    /// The folder a panel showed last, to open there at the next launch. A folder that is gone
    /// gives its nearest parent that still exists; nil when nothing was remembered.
    public func lastFolder(_ side: CommanderModel.Side) -> URL? {
        guard let path = defaults.string(forKey: Key.lastFolder(side)), path.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: path, isDirectory: true)
        var isFolder: ObjCBool = false
        while !(FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue) {
            guard url.path != "/" else { return nil }
            url = url.deletingLastPathComponent()
        }
        return url
    }

    /// Where the divider between the panels was left (the left panel's share; 0.5 = halves).
    public var splitRatio: CGFloat {
        get {
            let value = defaults.double(forKey: "panels.split")
            return value > 0.05 && value < 0.95 ? CGFloat(value) : 0.5
        }
        set { defaults.set(Double(newValue), forKey: "panels.split") }
    }

    /// A panel's tabs as saved (folders, and which one was active).
    public func tabs(_ side: CommanderModel.Side) -> (paths: [String], active: Int) {
        let key = side == .left ? "tabs.left" : "tabs.right"
        return (defaults.stringArray(forKey: key) ?? [], defaults.integer(forKey: key + ".active"))
    }

    public func saveTabs(_ tabs: PanelTabs, side: CommanderModel.Side) {
        let key = side == .left ? "tabs.left" : "tabs.right"
        let saved = tabs.saved
        defaults.set(saved.paths, forKey: key)
        defaults.set(saved.active, forKey: key + ".active")
    }

    /// Remembers a panel's folder (folders on this Mac only; a server connection isn't reopened).
    public func rememberFolder(_ url: URL, side: CommanderModel.Side) {
        guard url.isFileURL else { return }
        defaults.set(url.path, forKey: Key.lastFolder(side))
    }

    public var theme: Theme { settings.theme }
    public var display: DisplayOptions { settings.display }
    public var operation: OperationOptions { settings.operation }
    public var keys: KeyBindings { settings.keys }

    public func save(_ new: Settings) {
        guard new != settings else { return }
        if new.theme != settings.theme { store(new.theme, Key.theme) }
        if new.display != settings.display { store(new.display, Key.display) }
        if new.operation != settings.operation { store(new.operation, Key.operation) }
        if new.keys != settings.keys { store(new.keys, Key.keys) }
        if new.quickSearch != settings.quickSearch { store(new.quickSearch, Key.quickSearch) }
        if new.quickLocations != settings.quickLocations { store(new.quickLocations, Key.quickLocations) }
        settings = new
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
