import Foundation

/// "Open terminal here": which terminal app to start and how to tell it the folder.
///
/// Most macOS terminals open a folder handed to them (`open -a Terminal /path`); others need a
/// command-line option (`alacritty --working-directory /path`). The arguments template holds that
/// option with `{dir}` for the folder; an empty template means "hand the folder to the app".
/// The folder replaces `{dir}` inside a single argument: no shell is involved, so names with spaces,
/// quotes or `$` are passed through exactly.
public enum TerminalLauncher {
    public struct Preset: Equatable {
        public let name: String
        public let bundleID: String
        public let arguments: String
    }

    /// Terminals the Options page offers when installed, with how each takes a starting folder.
    public static let presets: [Preset] = [
        Preset(name: "Terminal", bundleID: "com.apple.Terminal", arguments: ""),
        Preset(name: "iTerm2", bundleID: "com.googlecode.iterm2", arguments: ""),
        Preset(name: "Alacritty", bundleID: "org.alacritty", arguments: "--working-directory {dir}"),
        Preset(name: "kitty", bundleID: "net.kovidgoyal.kitty", arguments: "--directory {dir}"),
        Preset(name: "WezTerm", bundleID: "com.github.wez.wezterm", arguments: "start --cwd {dir}"),
        Preset(name: "Ghostty", bundleID: "com.mitchellh.ghostty", arguments: "--working-directory={dir}"),
        Preset(name: "Warp", bundleID: "dev.warp.Warp-Stable", arguments: ""),
        Preset(name: "Hyper", bundleID: "co.zeit.hyper", arguments: ""),
    ]

    public static let defaultApp = "/System/Applications/Utilities/Terminal.app"

    /// How to start the terminal for a folder.
    public enum Launch: Equatable {
        /// Open the folder with the app (it starts a shell there).
        case openFolder(app: URL, folder: URL)
        /// Start a new instance of the app with these arguments.
        case run(app: URL, arguments: [String])
    }

    public static func launch(appPath: String, template: String, folder: URL) -> Launch {
        let path: String = appPath.isEmpty ? defaultApp : appPath
        let app = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let parts = template.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !parts.isEmpty else { return .openFolder(app: app, folder: folder) }
        return .run(app: app, arguments: parts.map { $0.replacingOccurrences(of: "{dir}", with: folder.path) })
    }

    /// The preset matching an app bundle (by its identifier), if it is a known terminal.
    public static func preset(forBundleID id: String?) -> Preset? {
        presets.first { $0.bundleID == id }
    }
}
