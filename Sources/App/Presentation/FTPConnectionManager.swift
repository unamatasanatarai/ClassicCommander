import AppKit

/// "Connect to FTP server" (⌃F): saved profiles in folders, with Connect, New connection…, New URL…,
/// Duplicate…, New folder…, Edit…, Delete, Encrypt… and Cancel.
/// Double-click (or Return) connects. A failed connection leaves the dialog open with the profile selected.
public final class FTPConnectionManagerController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Weak: AppKit may still ask this window's outline for data after the controller is gone.
    private weak var ftp: FTPController?
    /// Used when the controller is gone (nothing is shown or saved through it then).
    private lazy var detachedRepository = FTPProfileRepository(defaults: UserDefaults(suiteName: "ClassicCommander.detached") ?? .standard,
                                                              credentials: MemoryCredentialStore())
    let outline = NSOutlineView()
    let status = NSTextField(wrappingLabelWithString: "Double-click a saved profile to connect.")
    private(set) var editor: FTPProfileEditorController?
    /// Need a saved connection selected (Delete also takes a folder); greyed out otherwise.
    let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    let duplicateButton = NSButton(title: "Duplicate…", target: nil, action: nil)
    let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)

    /// Folder rows are their names; profile rows are profile ids.
    private final class Node: NSObject {
        let folder: String?
        let profileID: UUID?
        init(folder: String?, profileID: UUID?) { self.folder = folder; self.profileID = profileID }
    }
    private var folderNodes: [String: Node] = [:]
    private var profileNodes: [UUID: Node] = [:]

    init(ftp: FTPController) {
        self.ftp = ftp
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 280), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: true)
        window.title = AppWindows.title("Connect to FTP server")
        AppWindows.style(window)
        window.minSize = NSSize(width: 500, height: 250)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func present(newConnection: Bool = false) {
        reload()
        if let window = window { AppWindows.place(window) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if newConnection { newProfile() }
    }

    private var repository: FTPProfileRepository { ftp?.repository ?? detachedRepository }

    // MARK: Building

    private func build() -> NSView {
        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Saved connections"
        column.width = 220
        column.minWidth = 150
        outline.addTableColumn(column)
        let detail = NSTableColumn(identifier: .init("detail"))
        detail.title = "Connection"
        detail.width = 240
        outline.addTableColumn(detail)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = 22
        outline.target = self
        outline.doubleAction = #selector(connectSelected)
        outline.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let buttons: [(NSButton, Selector)] = [
            (connectButton, #selector(connectSelected)),
            (NSButton(title: "New connection…", target: nil, action: nil), #selector(newProfile)),
            (NSButton(title: "New URL…", target: nil, action: nil), #selector(newURL)),
            (duplicateButton, #selector(duplicate)),
            (NSButton(title: "New folder…", target: nil, action: nil), #selector(newFolder)),
            (editButton, #selector(edit)), (deleteButton, #selector(deleteSelected)),
        ]
        var views: [NSView] = []
        for (b, sel) in buttons {
            b.target = self
            b.action = sel
            b.bezelStyle = .rounded
            b.widthAnchor.constraint(equalToConstant: 160).isActive = true
            views.append(b)
        }
        connectButton.keyEquivalent = "\r"
        let side = NSStackView(views: views)
        side.orientation = .vertical
        side.spacing = 6
        // All buttons always visible: the column must not be clipped by the stack layout.
        side.setClippingResistancePriority(.required, for: .vertical)
        side.setHuggingPriority(.required, for: .vertical)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        let bottom = NSStackView(views: [status, NSView(), cancel])
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 420

        let title = NSTextField(labelWithString: "Connect to FTP server")
        title.font = .boldSystemFont(ofSize: 15)
        let main = NSStackView(views: [scroll, side])
        main.alignment = .top
        main.spacing = 12
        let stack = NSStackView(views: [title, main, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            main.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            scroll.heightAnchor.constraint(greaterThanOrEqualTo: side.heightAnchor),
        ])
        return root
    }

    func reload(select id: UUID? = nil) {
        let selected = id ?? selectedProfile?.id
        outline.reloadData()
        for folder in repository.folders { outline.expandItem(folderNode(folder)) }
        if let id = selected, let node = profileNodes[id] {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        updateButtons()
    }

    /// Connect, Duplicate and Edit need a saved connection; Delete a connection or a folder.
    func updateButtons() {
        let hasProfile = selectedProfile != nil
        for b in [connectButton, duplicateButton, editButton] { b.isEnabled = hasProfile }
        deleteButton.isEnabled = outline.selectedRow >= 0
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private func folderNode(_ name: String) -> Node {
        if let n = folderNodes[name] { return n }
        let n = Node(folder: name, profileID: nil)
        folderNodes[name] = n
        return n
    }

    private func profileNode(_ id: UUID) -> Node {
        if let n = profileNodes[id] { return n }
        let n = Node(folder: nil, profileID: id)
        profileNodes[id] = n
        return n
    }

    private func children(of item: Any?) -> [Node] {
        if let node = item as? Node {
            guard let folder = node.folder else { return [] }
            return repository.profiles(in: folder).map { profileNode($0.id) }
        }
        return repository.folders.map(folderNode) + repository.profiles(in: nil).map { profileNode($0.id) }
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.folder != nil }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let text: String
        if let folder = node.folder {
            text = tableColumn?.identifier.rawValue == "name" ? folder : ""
        } else if let p = node.profileID.flatMap(repository.profile) {
            text = tableColumn?.identifier.rawValue == "name" ? p.name : p.summary
        } else {
            text = ""
        }
        let label = NSTextField(labelWithString: text)
        if node.folder != nil { label.font = .boldSystemFont(ofSize: 13) }
        if tableColumn?.identifier.rawValue == "detail" {
            label.textColor = .secondaryLabelColor
            if let p = node.profileID.flatMap(repository.profile), !p.isEncrypted { label.textColor = .systemOrange }
        }
        label.lineBreakMode = .byTruncatingTail
        return Self.centered(label)
    }

    /// A cell with its text vertically centred in the row (a bare label sits at the top).
    static func centered(_ label: NSTextField) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    var selectedProfile: FTPProfile? {
        guard let node = outline.item(atRow: outline.selectedRow) as? Node, let id = node.profileID else { return nil }
        return repository.profile(id)
    }

    private var selectedFolder: String? {
        guard let node = outline.item(atRow: outline.selectedRow) as? Node else { return nil }
        if let f = node.folder { return f }
        return node.profileID.flatMap(repository.profile)?.folder
    }

    // MARK: Actions

    @objc func connectSelected() {
        guard let profile = selectedProfile else {
            status.stringValue = "Select a saved profile (not a folder) to connect."
            return NSSound.beep()
        }
        var password = profile.anonymous ? nil : repository.credentials.password(for: profile.id)
        // A key file only needs a passphrase when it is protected by one.
        let needsSecret = profile.usesKeyFile ? SFTPClient.keyNeedsPassphrase(profile.keyFilePath) : !profile.anonymous
        var remember = false
        if needsSecret && password == nil {
            guard let typed = askPassword(for: profile) else { return }
            password = typed.password.isEmpty ? nil : typed.password
            remember = typed.save && password != nil
        }
        connect(profile, password: password, remember: remember)
    }

    /// `remember`: once the login works, the password typed in the prompt goes into the Keychain.
    func connect(_ profile: FTPProfile, password: String?, remember: Bool = false) {
        status.stringValue = "Connecting to \(profile.hostAndPort)…"
        guard let ftp = ftp, let commander = ftp.commander else { return }
        ftp.connect(profile, password: password, side: commander.model.activeSide) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                if remember, let password = password {
                    var saved = profile
                    saved.savePassword = true
                    self.repository.save(saved, password: password)
                }
                self.status.stringValue = "Connected to \(profile.hostAndPort)."
                self.close()
            case .failure(let e):
                // Stay open with the profile still selected, and say what to do.
                self.status.stringValue = "Could not connect to \(profile.hostAndPort): \(e.message)"
                self.reload(select: profile.id)
                if self.ftp?.runSynchronously != true { NSSound.beep() }
            }
        }
    }

    /// The password (or key passphrase) prompt, with "Save in Keychain" (ticked when the profile saves passwords).
    private func askPassword(for profile: FTPProfile) -> (password: String, save: Bool)? {
        let alert = NSAlert()
        if profile.usesKeyFile {
            alert.messageText = "Passphrase for the key \(profile.keyFile)"
            alert.informativeText = "Used to unlock the key on this Mac; it is not sent to the server. Leave it empty to use ssh-agent."
        } else {
            alert.messageText = "Password for \(profile.loginName)@\(profile.hostAndPort)"
            alert.informativeText = profile.isEncrypted ? "" : "Warning: this connection is not encrypted; the password is sent in plain text."
        }
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = profile.usesKeyFile ? "Save passphrase in Keychain" : "Save password in Keychain"
        alert.suppressionButton?.state = profile.savePassword ? .on : .off
        guard Modal.run(alert) == .alertFirstButtonReturn else { return nil }
        return (field.stringValue, alert.suppressionButton?.state == .on)
    }

    @objc func newProfile() {
        var p = FTPProfile()
        p.folder = selectedFolder
        openEditor(p, password: nil, isNew: true)
    }

    @objc private func newURL() {
        let alert = NSAlert()
        alert.messageText = "New connection from URL"
        alert.informativeText = "e.g. ftp://user@ftp.example.com:21/var/www, ftps://… (implicit TLS) or sftp://user@host/path. A password in the URL is moved to the Keychain."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard Modal.run(alert) == .alertFirstButtonReturn else { return }
        guard let (profile, password) = FTPProfile.fromURL(field.stringValue) else {
            status.stringValue = "That is not an ftp://, ftps:// or sftp:// address."
            return NSSound.beep()
        }
        openEditor(profile, password: password, isNew: true)
    }

    @objc private func duplicate() {
        guard let p = selectedProfile, let copy = repository.duplicate(p.id) else { return NSSound.beep() }
        reload(select: copy.id)
        edit()
    }

    @objc private func newFolder() {
        let alert = NSAlert()
        alert.messageText = "New folder for connections"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard Modal.run(alert) == .alertFirstButtonReturn else { return }
        repository.addFolder(field.stringValue)
        reload()
    }

    @objc func edit() {
        guard let p = selectedProfile else { return NSSound.beep() }
        openEditor(p, password: repository.credentials.password(for: p.id), isNew: false)
    }

    private func openEditor(_ profile: FTPProfile, password: String?, isNew: Bool) {
        let editor = FTPProfileEditorController(profile: profile, password: password, folders: repository.folders, isNew: isNew)
        editor.onSave = { [weak self] saved, pw in
            self?.repository.save(saved, password: pw)
            self?.reload(select: saved.id)
            self?.editor = nil
        }
        editor.onCancel = { [weak self] in self?.editor = nil }
        self.editor = editor
        if let window = window, ftp?.runSynchronously != true { window.beginSheet(editor.window!) }
    }

    @objc private func deleteSelected() {
        guard let node = outline.item(atRow: outline.selectedRow) as? Node else { return NSSound.beep() }
        let alert = NSAlert()
        if let folder = node.folder {
            alert.messageText = "Delete the folder “\(folder)”?"
            alert.informativeText = "Its connections move to the top level; no connection settings are lost."
        } else if let p = selectedProfile {
            alert.messageText = "Delete the saved connection “\(p.name)”?"
            alert.informativeText = "Only the saved profile and its stored password are removed. Files on the server are not touched."
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard Modal.run(alert) == .alertFirstButtonReturn else { return }
        if let folder = node.folder { repository.deleteFolder(folder) } else if let id = node.profileID { repository.delete(id) }
        reload()
    }

}
