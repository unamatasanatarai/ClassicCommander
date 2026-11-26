import AppKit

/// About ClassicCommander panel: app icon, name, version, copyright, and a blue "View on GitHub" link.
public final class AboutWindowController: NSWindowController {
    public static let shared = AboutWindowController()
    public static let githubURL = URL(string: "https://github.com/unamatasanatarai/ClassicCommander")!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 245),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = AppWindows.title("About")
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        window.backgroundColor = isDark
            ? NSColor(srgbRed: 36/255, green: 36/255, blue: 38/255, alpha: 1)
            : NSColor(srgbRed: 244/255, green: 244/255, blue: 244/255, alpha: 1)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func present() {
        guard let window = window else { return }
        AppWindows.place(window)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSView {
        let icon = NSApp.applicationIconImage ?? NSImage()
        icon.size = NSSize(width: 72, height: 72)
        let iconView = NSImageView(image: icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 72).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let nameLabel = NSTextField(labelWithString: AppConfig.appName)
        nameLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        nameLabel.alignment = .center

        let versionLabel = NSTextField(labelWithString: "Version \(AppConfig.version) (\(AppConfig.buildNumber))")
        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center

        let copyrightLabel = NSTextField(labelWithString: "© 2026. All rights reserved.")
        copyrightLabel.font = .systemFont(ofSize: 12)
        copyrightLabel.textColor = .secondaryLabelColor
        copyrightLabel.alignment = .center

        let githubButton = NSButton(title: "View on GitHub", target: self, action: #selector(openGitHub))
        githubButton.isBordered = false
        githubButton.attributedTitle = NSAttributedString(string: "View on GitHub", attributes: [
            .foregroundColor: AppWindows.accent,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        githubButton.toolTip = Self.githubURL.absoluteString
        githubButton.setAccessibilityLabel("View on GitHub")

        let stack = NSStackView(views: [iconView, nameLabel, versionLabel, copyrightLabel, githubButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(10, after: iconView)
        stack.setCustomSpacing(12, after: copyrightLabel)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 28, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 340),
        ])
        return root
    }

    @objc private func openGitHub() {
        Modal.open(Self.githubURL)
    }
}
