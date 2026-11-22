import Foundation

/// Options from the Display page.
public struct DisplayOptions: Equatable, Codable {
    /// Show folders as "[name]", Total Commander's "Show square brackets around directory names".
    public var showFolderBrackets: Bool
    /// The "5 Copy  6 Move  7 NewFolder  8 Delete" button bar under the panels.
    public var showFunctionKeyBar: Bool
    /// The floppy icon in the menu bar.
    public var showStatusBarIcon: Bool

    public init(showFolderBrackets: Bool = true, showFunctionKeyBar: Bool = true, showStatusBarIcon: Bool = true) {
        self.showFolderBrackets = showFolderBrackets
        self.showFunctionKeyBar = showFunctionKeyBar
        self.showStatusBarIcon = showStatusBarIcon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showFolderBrackets = try c.decodeIfPresent(Bool.self, forKey: .showFolderBrackets) ?? true
        showFunctionKeyBar = try c.decodeIfPresent(Bool.self, forKey: .showFunctionKeyBar) ?? true
        showStatusBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showStatusBarIcon) ?? true
    }

    public static let standard = DisplayOptions()
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

    public init(spaceCalculatesFolderSize: Bool = true, spaceMovesCursorDown: Bool = true,
                maxTransfers: Int = 3, maxUploads: Int = 0, maxDownloads: Int = 0,
                terminalApp: String = TerminalLauncher.defaultApp, terminalArguments: String = "") {
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
    }

    public static let standard = OperationOptions()
}

/// Options → Quick Search: which keys start Quick Search when typed with a letter.
public struct QuickSearchOptions: Equatable, Codable {
    public enum Activation: String, Codable, CaseIterable {
        case controlOption, option, lettersOnly, off

        public var label: String {
            switch self {
            case .controlOption: return "⌃⌥ + letter"
            case .option: return "⌥ + letter"
            case .lettersOnly: return "Letter alone"
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

/// Everything on the Options dialog.
public struct Settings: Equatable {
    public var theme: Theme
    public var display: DisplayOptions
    public var operation: OperationOptions
    public var keys: KeyBindings
    public var quickSearch: QuickSearchOptions

    public init(theme: Theme = .standard, display: DisplayOptions = .standard,
                operation: OperationOptions = .standard, keys: KeyBindings = .standard,
                quickSearch: QuickSearchOptions = .standard) {
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
    }

    public static func export(_ settings: Settings) throws -> Data {
        let file = File(format: format, version: version, theme: settings.theme, display: settings.display,
                        operation: settings.operation, keys: settings.keys, quickSearch: settings.quickSearch)
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
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = Settings(
            theme: Self.load(Theme.self, Key.theme, defaults) ?? .standard,
            display: Self.load(DisplayOptions.self, Key.display, defaults) ?? .standard,
            operation: Self.load(OperationOptions.self, Key.operation, defaults) ?? .standard,
            keys: Self.load(KeyBindings.self, Key.keys, defaults) ?? .standard,
            quickSearch: Self.load(QuickSearchOptions.self, Key.quickSearch, defaults) ?? .standard
        )
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
