import AppKit

/// The connection settings dialog: General and Advanced tabs, Test connection, OK, Cancel.
final class FTPProfileEditorController: NSWindowController {
    private(set) var profile: FTPProfile
    private let initialPassword: String?
    private let isNew: Bool
    var onSave: ((FTPProfile, String?) -> Void)?
    var onCancel: (() -> Void)?

    let nameField = NSTextField()
    let hostField = NSTextField()
    let userField = NSTextField()
    let passwordField = NSSecureTextField()
    private let plainPasswordField = NSTextField()
    private let showPassword = NSButton(checkboxWithTitle: "Show", target: nil, action: nil)
    let remoteDirField = NSTextField()
    let localDirField = NSTextField()
    let folderPopup = NSPopUpButton()
    let securityPopup = NSPopUpButton()
    let protocolPopup = NSPopUpButton()
    let authPopup = NSPopUpButton()
    let keyFileField = NSTextField()
    private let chooseKeyButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let passwordLabel = NSTextField(labelWithString: "Password:")
    private var general: NSGridView!
    private var advanced: NSGridView!
    let anonymousBox = NSButton(checkboxWithTitle: "Anonymous login", target: nil, action: nil)
    let passiveBox = NSButton(checkboxWithTitle: "Passive mode (recommended behind NAT/firewalls)", target: nil, action: nil)
    let savePasswordBox = NSButton(checkboxWithTitle: "Save password in Keychain", target: nil, action: nil)
    private let securityWarning = NSTextField(wrappingLabelWithString: "")

    let serverTypePopup = NSPopUpButton()
    let transferPopup = NSPopUpButton()
    let commandsView = NSTextView()
    let cacheBox = NSButton(checkboxWithTitle: "Enable directory listing cache (Refresh with ⌃R)", target: nil, action: nil)
    let proxyPopup = NSPopUpButton()
    let proxyHostField = NSTextField()
    let proxyUserField = NSTextField()
    private let pinLabel = NSTextField(wrappingLabelWithString: "")
    private let forgetPin = NSButton(title: "Forget trusted key", target: nil, action: nil)
    private let testResult = NSTextField(wrappingLabelWithString: "")

    init(profile: FTPProfile, password: String?, folders: [String], isNew: Bool) {
        self.profile = profile
        self.initialPassword = password
        self.isNew = isNew
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "Connection settings"
        super.init(window: window)
        window.contentView = build(folders: folders)
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    private func build(folders: [String]) -> NSView {
        for f in [nameField, hostField, userField, passwordField, plainPasswordField, remoteDirField, localDirField, proxyHostField, proxyUserField, keyFileField] {
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        }
        hostField.placeholderString = "ftp.example.com or ftp.example.com:2121"
        remoteDirField.placeholderString = "/var/www/site  (empty: the login folder)"
        localDirField.placeholderString = "~/Sites/project  (opens in the other panel)"
        protocolPopup.addItems(withTitles: RemoteProtocol.allCases.map(\.label))
        protocolPopup.target = self
        protocolPopup.action = #selector(protocolChanged)
        authPopup.addItems(withTitles: SSHAuthMethod.allCases.map(\.label))
        authPopup.target = self
        authPopup.action = #selector(authChanged)
        keyFileField.placeholderString = "~/.ssh/id_ed25519"
        chooseKeyButton.bezelStyle = .rounded
        chooseKeyButton.target = self
        chooseKeyButton.action = #selector(chooseKeyFile)
        let keyRow = NSStackView(views: [keyFileField, chooseKeyButton])
        securityPopup.addItems(withTitles: FTPSecurity.allCases.map(\.label))
        securityPopup.target = self
        securityPopup.action = #selector(securityChanged)
        folderPopup.addItems(withTitles: ["(top level)"] + folders)
        anonymousBox.target = self
        anonymousBox.action = #selector(anonymousChanged)
        showPassword.target = self
        showPassword.action = #selector(togglePassword)
        plainPasswordField.isHidden = true
        securityWarning.textColor = .systemRed
        securityWarning.preferredMaxLayoutWidth = 520
        let passwordRow = NSStackView(views: [passwordField, plainPasswordField, showPassword])
        let general = NSGridView(views: [
            [label("Session:"), nameField],
            [label("Protocol:"), protocolPopup],
            [label("Host name[:Port]:"), hostField],
            [label("Security:"), securityPopup],
            [label("Login with:"), authPopup],
            [label("Key file:"), keyRow],
            [NSGridCell.emptyContentView, securityWarning],
            [label("User name:"), userField],
            [passwordLabel, passwordRow],
            [label("Remote dir:"), remoteDirField],
            [label("Local dir:"), localDirField],
            [label("Folder:"), folderPopup],
            [anonymousBox, passiveBox],
            [NSGridCell.emptyContentView, savePasswordBox],
        ])
        general.rowSpacing = 8
        general.columnSpacing = 10
        general.column(at: 0).xPlacement = .trailing
        general.row(at: Row.ftpOptions).cell(at: 0).xPlacement = .leading
        self.general = general

        serverTypePopup.addItems(withTitles: FTPServerType.allCases.map(\.label))
        serverTypePopup.toolTip = "How folder listings are read. Automatic tries MLSD and falls back to LIST."
        transferPopup.addItems(withTitles: FTPTransferMode.allCases.map(\.label))
        transferPopup.toolTip = "Binary keeps every byte; text mode converts line endings and can damage non-text files."
        commandsView.isRichText = false
        commandsView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let commandsScroll = NSScrollView()
        commandsScroll.documentView = commandsView
        commandsScroll.hasVerticalScroller = true
        commandsScroll.borderType = .bezelBorder
        commandsScroll.heightAnchor.constraint(equalToConstant: 70).isActive = true
        commandsScroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        commandsView.frame = NSRect(x: 0, y: 0, width: 420, height: 70)
        commandsView.autoresizingMask = [.width]
        let warning = label("Sent to the server after every login, one per line (e.g. SITE UMASK 022). Only use commands you understand.")
        warning.textColor = .secondaryLabelColor
        warning.font = .systemFont(ofSize: 11)
        cacheBox.toolTip = "Re-use folder listings while browsing; Refresh (⌃R) and file operations re-read them."
        proxyPopup.addItems(withTitles: FTPProxyKind.allCases.map(\.label))
        proxyHostField.placeholderString = "proxy.example.com:8080"
        pinLabel.textColor = .secondaryLabelColor
        pinLabel.preferredMaxLayoutWidth = 420
        forgetPin.bezelStyle = .rounded
        forgetPin.target = self
        forgetPin.action = #selector(forgetPinned)
        let advanced = NSGridView(views: [
            [label("Server type:"), serverTypePopup],
            [label("Transfer mode:"), transferPopup],
            [label("Commands after login:"), commandsScroll],
            [NSGridCell.emptyContentView, warning],
            [NSGridCell.emptyContentView, cacheBox],
            [label("Proxy:"), proxyPopup],
            [label("Proxy host:port:"), proxyHostField],
            [label("Proxy user:"), proxyUserField],
            [label("Trusted key:"), pinLabel],
            [NSGridCell.emptyContentView, forgetPin],
        ])
        advanced.rowSpacing = 8
        advanced.columnSpacing = 10
        advanced.column(at: 0).xPlacement = .trailing
        self.advanced = advanced

        let tabs = NSTabView()
        for (title, view) in [("General", general), ("Advanced", advanced)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            let container = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                view.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            ])
            item.view = container
            tabs.addTabViewItem(item)
        }

        let test = NSButton(title: "Test connection", target: self, action: #selector(testConnection))
        let ok = NSButton(title: "OK", target: self, action: #selector(okPressed))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        for b in [test, ok, cancel] { b.bezelStyle = .rounded }
        ok.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        testResult.preferredMaxLayoutWidth = 560
        testResult.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [test, NSView(), cancel, ok])

        let stack = NSStackView(views: [tabs, testResult, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            tabs.heightAnchor.constraint(equalToConstant: 470),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            testResult.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        return root
    }

    private func load() {
        nameField.stringValue = profile.name
        hostField.stringValue = profile.host.isEmpty ? "" : profile.hostAndPort
        userField.stringValue = profile.username
        passwordField.stringValue = initialPassword ?? ""
        remoteDirField.stringValue = profile.remoteDirectory
        localDirField.stringValue = profile.localDirectory
        securityPopup.selectItem(at: FTPSecurity.allCases.firstIndex(of: profile.security) ?? 0)
        protocolPopup.selectItem(at: RemoteProtocol.allCases.firstIndex(of: profile.connectionProtocol) ?? 0)
        authPopup.selectItem(at: SSHAuthMethod.allCases.firstIndex(of: profile.sshAuth) ?? 0)
        keyFileField.stringValue = profile.keyFile
        if let folder = profile.folder { folderPopup.selectItem(withTitle: folder) } else { folderPopup.selectItem(at: 0) }
        anonymousBox.state = profile.anonymous ? .on : .off
        passiveBox.state = profile.passive ? .on : .off
        savePasswordBox.state = profile.savePassword ? .on : .off
        serverTypePopup.selectItem(at: FTPServerType.allCases.firstIndex(of: profile.serverType) ?? 0)
        transferPopup.selectItem(at: FTPTransferMode.allCases.firstIndex(of: profile.transferMode) ?? 0)
        commandsView.string = profile.commandsAfterLogin.joined(separator: "\n")
        cacheBox.state = profile.cacheListings ? .on : .off
        proxyPopup.selectItem(at: FTPProxyKind.allCases.firstIndex(of: profile.proxyKind) ?? 0)
        proxyHostField.stringValue = profile.proxyHost
        proxyUserField.stringValue = profile.proxyUsername
        updateSecurityWarning()
        updatePin()
        anonymousChanged()
        updateProtocolControls()
    }

    /// Rows of the General grid that depend on the protocol.
    private enum Row {
        static let security = 3, auth = 4, keyFile = 5, ftpOptions = 12
    }

    private var selectedProtocol: RemoteProtocol { RemoteProtocol.allCases[max(0, protocolPopup.indexOfSelectedItem)] }
    private var selectedAuth: SSHAuthMethod { SSHAuthMethod.allCases[max(0, authPopup.indexOfSelectedItem)] }

    /// Shows the settings of the chosen protocol: TLS for FTP, key or password login for SFTP.
    private func updateProtocolControls() {
        let sftp = selectedProtocol == .sftp
        let key = sftp && selectedAuth == .keyFile
        general.row(at: Row.security).isHidden = sftp
        general.row(at: Row.auth).isHidden = !sftp
        general.row(at: Row.keyFile).isHidden = !key
        general.row(at: Row.ftpOptions).isHidden = sftp
        passwordLabel.stringValue = key ? "Key passphrase:" : "Password:"
        passwordField.placeholderString = key ? "empty if the key has none (or it is in ssh-agent)" : nil
        savePasswordBox.title = key ? "Save passphrase in Keychain" : "Save password in Keychain"
        if sftp { anonymousBox.state = .off }
        anonymousChanged()
        for c in [serverTypePopup, transferPopup, proxyUserField] as [NSControl] { c.isEnabled = !sftp }
        commandsView.isEditable = !sftp
        commandsView.textColor = sftp ? .disabledControlTextColor : .controlTextColor
        updateSecurityWarning()
        updatePin()
    }

    @objc private func protocolChanged() {
        let old = profile.defaultPort
        profile.connectionProtocol = selectedProtocol
        if profile.isSFTP && keyFileField.stringValue.isEmpty { keyFileField.stringValue = FTPProfile.defaultKeyFile() }
        // Follow the default port when it was the old default (21 ↔ 22).
        var p = read().0
        if p.port == old {
            p.port = profile.defaultPort
            hostField.stringValue = p.host.isEmpty ? "" : p.hostAndPort
        }
        updateProtocolControls()
    }

    @objc private func authChanged() {
        profile.sshAuth = selectedAuth
        updateProtocolControls()
    }

    @objc private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose your private key (not the .pub file)"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.keyFileField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        }
        if let window = window { panel.beginSheetModal(for: window, completionHandler: apply) } else { apply(panel.runModal()) }
    }

    /// The profile as currently entered (the password separately).
    func read() -> (FTPProfile, String?) {
        var p = profile
        p.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        p.security = FTPSecurity.allCases[max(0, securityPopup.indexOfSelectedItem)]
        p.connectionProtocol = selectedProtocol
        p.sshAuth = selectedAuth
        p.keyFile = keyFileField.stringValue.trimmingCharacters(in: .whitespaces)
        if !p.setHostAndPort(hostField.stringValue) { p.host = hostField.stringValue.trimmingCharacters(in: .whitespaces) }
        p.username = userField.stringValue
        p.remoteDirectory = remoteDirField.stringValue.trimmingCharacters(in: .whitespaces)
        p.localDirectory = localDirField.stringValue.trimmingCharacters(in: .whitespaces)
        p.folder = folderPopup.indexOfSelectedItem > 0 ? folderPopup.titleOfSelectedItem : nil
        p.anonymous = anonymousBox.state == .on && !p.isSFTP
        p.passive = passiveBox.state == .on
        p.savePassword = savePasswordBox.state == .on
        p.serverType = FTPServerType.allCases[max(0, serverTypePopup.indexOfSelectedItem)]
        p.transferMode = FTPTransferMode.allCases[max(0, transferPopup.indexOfSelectedItem)]
        p.commandsAfterLogin = commandsView.string.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.cacheListings = cacheBox.state == .on
        p.proxyKind = FTPProxyKind.allCases[max(0, proxyPopup.indexOfSelectedItem)]
        p.proxyHost = proxyHostField.stringValue.trimmingCharacters(in: .whitespaces)
        p.proxyUsername = proxyUserField.stringValue
        let password = showPassword.state == .on ? plainPasswordField.stringValue : passwordField.stringValue
        return (p, p.anonymous || password.isEmpty ? nil : password)
    }

    @objc private func securityChanged() {
        let old = profile.security
        let new = FTPSecurity.allCases[max(0, securityPopup.indexOfSelectedItem)]
        // Follow the default port when it was the old default (21 ↔ 990).
        var p = read().0
        if p.port == old.defaultPort {
            p.port = new.defaultPort
            hostField.stringValue = p.host.isEmpty ? "" : p.hostAndPort
        }
        profile.security = new
        updateSecurityWarning()
    }

    private func updateSecurityWarning() {
        if selectedProtocol == .sftp {
            securityWarning.stringValue = "Encrypted with SSH. The server's host key is always checked; a key not seen before is shown for you to confirm."
            securityWarning.textColor = .secondaryLabelColor
            return
        }
        let s = FTPSecurity.allCases[max(0, securityPopup.indexOfSelectedItem)]
        securityWarning.stringValue = s == .none
            ? "Unencrypted: user name, password and files are sent in plain text. Use FTPS when the server supports it."
            : "Encrypted with TLS. The certificate is checked; the connection is never downgraded to plain FTP."
        securityWarning.textColor = s == .none ? .systemRed : .secondaryLabelColor
    }

    private func updatePin() {
        if selectedProtocol == .sftp {
            pinLabel.stringValue = profile.trustedHostKeys.isEmpty
                ? "None — the host key must be in ~/.ssh/known_hosts, or you are asked on connect."
                : "You trusted \(profile.trustedHostKeys.count) host key(s): " + profile.trustedHostKeys.map { String($0.split(separator: " ").first ?? "") }.joined(separator: ", ")
            forgetPin.isEnabled = !profile.trustedHostKeys.isEmpty
            return
        }
        pinLabel.stringValue = profile.pinnedPublicKey.map { "You trusted this server key: \($0)" } ?? "None — the certificate must be trusted by macOS."
        forgetPin.isEnabled = profile.pinnedPublicKey != nil
    }

    @objc private func forgetPinned() {
        if selectedProtocol == .sftp { profile.trustedHostKeys = [] } else { profile.pinnedPublicKey = nil }
        updatePin()
    }

    @objc private func anonymousChanged() {
        let anon = anonymousBox.state == .on && selectedProtocol == .ftp
        for c in [userField, passwordField, plainPasswordField, savePasswordBox] as [NSControl] { c.isEnabled = !anon }
    }

    @objc private func togglePassword() {
        if showPassword.state == .on {
            plainPasswordField.stringValue = passwordField.stringValue
        } else {
            passwordField.stringValue = plainPasswordField.stringValue
        }
        plainPasswordField.isHidden = showPassword.state != .on
        passwordField.isHidden = showPassword.state == .on
    }

    /// Logs in with the values as entered, without saving them.
    @objc func testConnection() {
        let (p, password) = read()
        if let problem = p.problems.first {
            testResult.stringValue = problem
            testResult.textColor = .systemRed
            return
        }
        testResult.stringValue = "Testing \(p.hostAndPort)…"
        testResult.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async {
            let client = RemoteClients.make(p, secret: password)
            let result = Result { try client.connect(cancel: nil) }
            client.close()
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let entries):
                    self?.testResult.stringValue = "Connected (\(p.securityLabel)). \(entries.count) entries in \(client.startPath)."
                    self?.testResult.textColor = .systemGreen
                case .failure(let e):
                    let message = (e as? FTPError)?.message ?? e.localizedDescription
                    self?.testResult.stringValue = (e as? FTPError) == .hostKeyUnknown
                        ? message + " Use Connect to see its fingerprint and trust it." : message
                    self?.testResult.textColor = .systemRed
                }
            }
        }
    }

    @objc private func okPressed() {
        let (p, password) = read()
        if let problem = p.problems.first {
            testResult.stringValue = problem
            testResult.textColor = .systemRed
            return NSSound.beep()
        }
        profile = p
        finish()
        onSave?(p, password)
    }

    @objc private func cancelPressed() {
        finish()
        onCancel?()
    }

    private func finish() {
        guard let window = window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }
}
