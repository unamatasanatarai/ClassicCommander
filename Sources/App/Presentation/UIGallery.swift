import AppKit

/// Debugging & verification tool: presents every window, popup, dialog, and alert in ClassicCommander
/// so they can be visually inspected and verified at any time.
public final class UIGallery: NSObject {
    public static let shared = UIGallery()
    weak var appDelegate: AppDelegate?

    /// Retains open gallery window controllers so they remain interactive on screen.
    private var activeControllers: [NSWindowController] = []
    private var tempFiles: [URL] = []
    private var paletteController: NSWindowController?

    public override init() {
        super.init()
    }

    deinit {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
    }

    private func getCommander() -> CommanderView {
        if let cv = appDelegate?.commanderView { return cv }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let model = CommanderModel(left: PanelModel(directory: home), right: PanelModel(directory: home))
        return CommanderView(model: model)
    }

    @objc public func closeAllGalleryWindows() {
        for controller in activeControllers {
            controller.close()
            controller.window?.orderOut(nil)
        }
        activeControllers.removeAll()
        paletteController?.close()
        paletteController?.window?.orderOut(nil)
        paletteController = nil
        appDelegate?.commanderView?.findFiles.close()
        appDelegate?.commanderView?.synchronize.close()
        appDelegate?.commanderView?.multiRename.close()
        appDelegate?.commanderView?.ftp.managerWindow.close()
        appDelegate?.commanderView?.ftp.transfersWindow.close()
    }

    private func layoutSubmenuWindows(_ windows: [NSWindow]) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 20, y: 20, width: 1440, height: 900)
        var x = screen.minX + 30
        var y = screen.maxY - 30
        for win in windows {
            let winW = win.frame.width
            let winH = win.frame.height
            if y - winH < screen.minY {
                y = screen.maxY - 30
                x += 120
            }
            if x + winW > screen.maxX {
                x = screen.minX + 30
            }
            win.setFrameOrigin(NSPoint(x: x, y: max(screen.minY, y - winH)))
            win.makeKeyAndOrderFront(nil)
            x += 40
            y -= 40
        }
    }

    /// Opens all Windows & Tools in the first submenu simultaneously.
    @objc public func openAllTools() {
        closeAllGalleryWindows()
        showFindFiles()
        showSynchronize()
        showMultiRename()
        showChmodFile()
        showChmodFolder()
        showLister()
        showDiff()
        showOptions()
        showFTPConnectionManager()
        showFTPProfileEditor()
        showQueue()
        let wins = activeControllers.compactMap(\.window)
        layoutSubmenuWindows(wins)
    }

    /// Opens all Transfer & Operation Popups in the second submenu simultaneously.
    @objc public func openAllPopups() {
        closeAllGalleryWindows()
        showCopyDialog()
        showMoveDialog()
        showConflictDialog()
        showTransferProgressActive()
        showTransferProgressPreparing()
        showPackFilesProgress()
        showSyncConfirmation()
        let wins = activeControllers.compactMap(\.window)
        layoutSubmenuWindows(wins)
    }

    /// Opens all Dialogs, Prompts & Alerts in the third submenu simultaneously.
    @objc public func openAllDialogs() {
        closeAllGalleryWindows()
        showNewFolderPrompt()
        showSelectMaskPrompt()
        showDeselectMaskPrompt()
        showDeleteTrashConfirm()
        showDeletePermanentConfirm()
        showOperationProblems()
        showCertTrustAlert()
        showHostKeyAlert()
        showAboutPanel()
        let wins = activeControllers.compactMap(\.window)
        layoutSubmenuWindows(wins)
    }

    /// Opens every single UI debug window, popup, dialog, and alert simultaneously,
    /// arranging them in an organized cascading matrix across the display for instant visual inspection.
    @objc public func openAllWindows() {
        closeAllGalleryWindows()

        // 1. Windows & Tools
        showFindFiles()
        showSynchronize()
        showMultiRename()
        showChmodFile()
        showChmodFolder()
        showLister()
        showDiff()
        showOptions()
        showFTPConnectionManager()
        showFTPProfileEditor()
        showQueue()

        // 2. Transfer & Operation Popups (Modeless)
        showCopyDialog()
        showMoveDialog()
        showConflictDialog()
        showTransferProgressActive()
        showTransferProgressPreparing()
        showPackFilesProgress()
        showSyncConfirmation()

        // 3. Dialogs, Prompts & Alerts (Modeless)
        showNewFolderPrompt()
        showSelectMaskPrompt()
        showDeselectMaskPrompt()
        showDeleteTrashConfirm()
        showDeletePermanentConfirm()
        showOperationProblems()
        showCertTrustAlert()
        showHostKeyAlert()

        arrangeGalleryColumns()
    }

    private func arrangeGalleryColumns() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 20, y: 20, width: 1440, height: 900)
        let colWidth = (screen.width - 40) / 4
        for (colIdx, wins) in groupedGalleryColumns().enumerated() {
            placeGalleryColumn(wins, colX: screen.minX + 10 + CGFloat(colIdx) * colWidth, colWidth: colWidth, screen: screen)
        }
    }

    private func groupedGalleryColumns() -> [[NSWindow]] {
        var cols: [[NSWindow]] = [[], [], [], []]
        for ctrl in activeControllers {
            guard let win = ctrl.window else { continue }
            cols[columnIndex(for: win.title.lowercased())].append(win)
        }
        return cols
    }

    private func columnIndex(for title: String) -> Int {
        if ["find files", "synchronize", "multi-rename", "lister", "compare"].contains(where: { title.contains($0) }) { return 0 }
        if ["copy", "move", "conflict", "transfer", "pack", "queue", "target file"].contains(where: { title.contains($0) }) { return 1 }
        if ["chmod", "permission", "options", "connection", "profile", "problem"].contains(where: { title.contains($0) }) { return 2 }
        return 3
    }

    private func placeGalleryColumn(_ wins: [NSWindow], colX: CGFloat, colWidth: CGFloat, screen: NSRect) {
        var currentY = screen.maxY - 10
        for win in wins {
            let winW = min(win.frame.width, colWidth - 8)
            let winH = win.frame.height
            if currentY - winH < screen.minY { currentY = screen.maxY - 40 }
            let targetX = max(screen.minX, min(colX, screen.maxX - winW))
            let targetY = max(screen.minY, currentY - winH)
            win.setFrameOrigin(NSPoint(x: targetX, y: targetY))
            win.makeKeyAndOrderFront(nil)
            currentY = targetY - 14
        }
    }

    /// Shows a compact floating HUD panel with big one-click actions:
    /// "Open All Windows at Once" and "Close All Gallery Windows".
    @objc public func showGalleryPalette() {
        if let pc = paletteController {
            pc.showWindow(nil)
            pc.window?.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSPanel(
            contentRect: NSRect(x: 80, y: 150, width: 320, height: 160),
            styleMask: [.titled, .closable, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        win.title = "UI Debug Gallery"
        win.isFloatingPanel = true
        win.level = .floating

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "UI Debug Gallery")
        titleLabel.font = .boldSystemFont(ofSize: 13)

        let openAllBtn = NSButton(title: "🚀 Open All Windows at Once", target: self, action: #selector(openAllWindows))
        openAllBtn.bezelStyle = .rounded
        openAllBtn.font = .boldSystemFont(ofSize: 12)

        let closeAllBtn = NSButton(title: "✕ Close All Gallery Windows", target: self, action: #selector(closeAllGalleryWindows))
        closeAllBtn.bezelStyle = .rounded

        let descLabel = NSTextField(labelWithString: "Visually inspects all 20+ windows, popups & dialogs.")
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.alignment = .center

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(openAllBtn)
        stack.addArrangedSubview(closeAllBtn)
        stack.addArrangedSubview(descLabel)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
        ])

        win.contentView = content
        let pc = NSWindowController(window: win)
        paletteController = pc
        activeControllers.append(pc)
        pc.showWindow(nil)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: - Windows & Tools

    @objc public func showFindFiles() {
        if let ff = appDelegate?.commanderView?.findFiles {
            ff.present()
        } else {
            let ff = FindFilesWindowController(commander: getCommander())
            activeControllers.append(ff)
            ff.present()
        }
    }

    @objc public func showSynchronize() {
        if let sync = appDelegate?.commanderView?.synchronize {
            sync.present()
        } else {
            let sync = SyncWindowController(commander: getCommander())
            activeControllers.append(sync)
            sync.present()
        }
    }

    @objc public func showMultiRename() {
        let commander = getCommander()
        commander.multiRename.present(for: commander.activeView)
    }

    @objc public func showChmodFile() {
        let entry = FileEntry(name: "artcraft-launcher.dmg", url: URL(fileURLWithPath: "/Users/citizen/Downloads/artcraft-launcher.dmg"),
                              kind: .file, size: 20_971_520, modified: Date(), permissions: 0o755)
        let dlg = ChmodDialogController(targets: [entry]) { _ in }
        activeControllers.append(dlg)
        dlg.present()
    }

    @objc public func showChmodFolder() {
        let entry = FileEntry(name: "Application Documents", url: URL(fileURLWithPath: "/Users/citizen/Documents"),
                              kind: .directory, size: 0, modified: Date(), permissions: 0o755)
        let dlg = ChmodDialogController(targets: [entry]) { _ in }
        activeControllers.append(dlg)
        dlg.present()
    }

    @objc public func showLister() {
        let sampleURL = prepareSampleFile(name: "SAMPLE.md", content: """
        # ClassicCommander Lister Preview

        This is a live visual test of the **Lister** window.
        Use `1` (Text), `2` (Binary), `3` (Hex), `4` (Preview) to switch modes.

        ### Features:
        - Monospaced editing font with line wrapping (`w`)
        - Real-time encoding selection
        - Keyboard navigation (`n` / `p`) synchronizing with panels
        - Markdown and text rendering

        | Shortcut | Action |
        | --- | --- |
        | F3 / 3 | Open Lister |
        | Esc / q | Close Lister |
        | n / p | Next / Previous file |
        """)
        let lister = ListerWindowController(files: [sampleURL], index: 0)
        activeControllers.append(lister)
        lister.present()
    }

    @objc public func showDiff() {
        let leftURL = URL(fileURLWithPath: "/Original/server.conf")
        let rightURL = URL(fileURLWithPath: "/Modified/server.conf")
        let diff = DiffWindowController(leftTitle: leftURL.path, rightTitle: rightURL.path)
        let leftLines = [
            "# Server Configuration (v1.0)",
            "port = 8080",
            "host = 127.0.0.1",
            "max_connections = 100",
            "timeout = 30",
            "enable_ssl = false",
            "cache_size = 256MB"
        ]
        let rightLines = [
            "# Server Configuration (v2.0)",
            "port = 8443",
            "host = 0.0.0.0",
            "max_connections = 500",
            "timeout = 60",
            "enable_ssl = true",
            "ssl_cert = /etc/ssl/cert.pem",
            "cache_size = 512MB"
        ]
        diff.show(.text(TextDiff(left: leftLines, right: rightLines)))
        activeControllers.append(diff)
        diff.showWindow(nil)
        diff.window?.makeKeyAndOrderFront(nil)
    }

    @objc public func showOptions() {
        appDelegate?.showOptions()
    }

    @objc public func showFTPConnectionManager() {
        if let ftp = appDelegate?.commanderView?.ftp {
            ftp.managerWindow.present()
        }
    }

    @objc public func showFTPProfileEditor() {
        var profile = FTPProfile()
        profile.name = "Production SFTP Server"
        profile.host = "sftp.production.internal"
        profile.port = 22
        profile.username = "deploy"
        profile.connectionProtocol = .sftp
        let editor = FTPProfileEditorController(profile: profile, password: "sample_password", folders: ["Websites", "Databases", "Backups"], isNew: false)
        editor.window?.center()
        editor.onCancel = { [weak editor] in editor?.close() }
        editor.onSave = { [weak editor] (saved: FTPProfile, pw: String?) in editor?.close() }
        activeControllers.append(editor)
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    @objc public func showQueue() {
        if let ftp = appDelegate?.commanderView?.ftp {
            ftp.transfersWindow.present()
        }
    }

    // MARK: - Transfer & Operation Popups

    @objc public func showCopyDialog() {
        let entry = FileEntry(name: "wolfs.mp4", url: URL(fileURLWithPath: "/Movies/wolfs.mp4"),
                              kind: .file, size: 1_101_493_179, modified: Date(), permissions: 0o644)
        let question = FileCommands.question(verb: "Copy", items: [entry], target: "/Volumes/BB/movies/")
        let dlg = TransferDialogController(question: question, sizeFormat: .readable)
        activeControllers.append(dlg)
        dlg.showWindow(nil)
        dlg.window?.makeKeyAndOrderFront(nil)
    }

    @objc public func showMoveDialog() {
        let entry = FileEntry(name: "superman.mp4", url: URL(fileURLWithPath: "/Movies/superman.mp4"),
                              kind: .file, size: 2_785_283_877, modified: Date(), permissions: 0o644)
        let question = FileCommands.question(verb: "Move", items: [entry], target: "/Volumes/BB/movies/")
        let dlg = TransferDialogController(question: question, sizeFormat: .readable)
        activeControllers.append(dlg)
        dlg.showWindow(nil)
        dlg.window?.makeKeyAndOrderFront(nil)
    }

    @objc public func showConflictDialog() {
        let conflict = TransferConflict(
            source: .local(URL(fileURLWithPath: "/Users/citizen/dwhelper/scripts/.DS_Store")),
            target: .local(URL(fileURLWithPath: "/Users/citizen/Downloads/scripts/.DS_Store")),
            sourceSize: 6148,
            sourceDate: Date(),
            targetSize: 6148,
            targetDate: Date().addingTimeInterval(-3600)
        )
        let dlg = ConflictDialogController(conflict: conflict, sizeFormat: .readable)
        activeControllers.append(dlg)
        if let win = dlg.window { AppWindows.place(win) }
        dlg.showWindow(nil)
        dlg.window?.makeKeyAndOrderFront(nil)
    }

    @objc public func showTransferProgressActive() {
        let item1 = TransferItem(source: .local(URL(fileURLWithPath: "/dwhelper/scripts/.DS_Store")),
                                 destination: .local(URL(fileURLWithPath: "/Downloads/scripts/.DS_Store")),
                                 size: 6148, isFolder: false)
        let item2 = TransferItem(source: .local(URL(fileURLWithPath: "/dwhelper/scripts/build.sh")),
                                 destination: .local(URL(fileURLWithPath: "/Downloads/scripts/build.sh")),
                                 size: 8452, isFolder: false)
        let job = TransferJob(title: "Copying 2 files", items: [item1, item2], isMove: false)
        job.state = .running
        job.started = Date().addingTimeInterval(-10)
        job.active.insert(0)
        job.partial[0] = 3074
        let pw = TransferProgressWindowController(job: job) {}
        activeControllers.append(pw)
        pw.present()
    }

    @objc public func showTransferProgressPreparing() {
        let cancel = CancelFlag()
        let pw = TransferProgressWindowController(title: "Copying", from: "/Users/citizen/Projects", to: "/Volumes/Backup/Projects", cancelFlag: cancel) {}
        activeControllers.append(pw)
        pw.present()
    }

    @objc public func showPackFilesProgress() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 116), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = AppWindows.title("Pack Files")
        AppWindows.style(win)
        let content = NSView()
        let label = NSTextField(labelWithString: "Packing release-archive.zip…")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let cancelBtn = NSButton(title: "Cancel", target: win, action: #selector(NSWindow.performClose(_:)))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: AppWindows.Layout.buttonMinWidth).isActive = true
        let btnRow = NSStackView(views: [NSView(), cancelBtn])
        let m = AppWindows.Layout.margin
        let stack = NSStackView(views: [label, bar, btnRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AppWindows.Layout.controlSpacing
        stack.edgeInsets = NSEdgeInsets(top: m, left: m, bottom: m, right: m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 400),
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            btnRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
        ])
        win.contentView = content
        AppWindows.place(win)
        let wc = NSWindowController(window: win)
        activeControllers.append(wc)
        win.makeKeyAndOrderFront(nil)
    }

    @objc public func showSyncConfirmation() {
        let f1 = SyncFileInfo(url: URL(fileURLWithPath: "/Left/photo1.jpg"), size: 2_450_000, modified: Date(), isDirectory: false)
        let f2 = SyncFileInfo(url: URL(fileURLWithPath: "/Right/notes.md"), size: 8192, modified: Date().addingTimeInterval(-3600), isDirectory: false)
        let f3 = SyncFileInfo(url: URL(fileURLWithPath: "/Left/temp.cache"), size: 14_000, modified: Date(), isDirectory: false)

        let row1 = SyncRow(path: "photo1.jpg", left: f1, right: nil, state: .leftOnly, action: .copyToRight, recommended: .copyToRight)
        let row2 = SyncRow(path: "notes.md", left: nil, right: f2, state: .rightOnly, action: .copyToLeft, recommended: .copyToLeft)
        let row3 = SyncRow(path: "temp.cache", left: f3, right: nil, state: .different, action: .deleteLeft, recommended: .deleteLeft)

        let cfg = SyncConfiguration(left: URL(fileURLWithPath: "/Left"), right: URL(fileURLWithPath: "/Right"))
        let plan = SyncPlan(rows: [row1, row2, row3], config: cfg)
        let conf = SyncConfirmationController(plan: plan, config: cfg)
        activeControllers.append(conf)
        conf.showWindow(nil)
        conf.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Dialogs, Prompts & Alerts

    private func showModelessAlert(_ alert: NSAlert) {
        var winRef: NSWindow?
        let win = Modal.dialogWindow(for: alert) { _ in
            winRef?.performClose(nil)
        }
        winRef = win
        let wc = NSWindowController(window: win)
        activeControllers.append(wc)
        AppWindows.place(win)
        win.makeKeyAndOrderFront(nil)
    }

    @objc public func showNewFolderPrompt() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "New Folder"
        alert.informativeText = "Create in ~/Documents/Projects"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.placeholderString = "Folder name"
        field.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        showModelessAlert(alert)
    }

    @objc public func showSelectMaskPrompt() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Select files"
        alert.informativeText = "Match by file name mask"
        alert.addButton(withTitle: "Select")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "*")
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        showModelessAlert(alert)
    }

    @objc public func showDeselectMaskPrompt() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Deselect files"
        alert.informativeText = "Remove matching files from the selection"
        alert.addButton(withTitle: "Deselect")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "*.tmp;*.bak")
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        showModelessAlert(alert)
    }

    @objc public func showDeleteTrashConfirm() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Move 4 files to the Trash?"
        alert.informativeText = "You can restore them from the Trash later."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        showModelessAlert(alert)
    }

    @objc public func showDeletePermanentConfirm() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete 4 files permanently?"
        alert.informativeText = "They will be removed immediately and can't be recovered."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        showModelessAlert(alert)
    }

    @objc public func showOperationProblems() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Copy finished with 3 errors"
        let text = """
        These items were not copied.
        • Permission denied: /Volumes/BB/system/config.sys
        • Target volume is read-only: /Volumes/Backup
        • Connection reset by peer: The SFTP transfer was interrupted.
        """
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy details")
        showModelessAlert(alert)
    }

    @objc public func showCertTrustAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can't verify this server's certificate"
        alert.informativeText = """
        sftp.example.com
        Problem: Expired on 2026-10-15
        Issuer: Let's Encrypt Authority X3
        SHA-256: 3A:5B:C8:41:9E:52:19:D4:E8:22:15:AC…

        Only trust it if you know this is the right server.
        """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Trust anyway")
        showModelessAlert(alert)
    }

    @objc public func showHostKeyAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Unknown SSH host key"
        alert.informativeText = """
        You haven't connected to this server before.
        Server: sftp.example.com (port 22)
        Key type: ED25519 (256 bit)
        Fingerprint: SHA256:4d82f7c00643ea1824c77609a84b067d983415eb…

        Trust this host key and continue connecting?
        """
        alert.addButton(withTitle: "Trust and connect")
        alert.addButton(withTitle: "Cancel")
        showModelessAlert(alert)
    }

    @objc public func showAboutPanel() {
        AboutWindowController.shared.present()
        if !activeControllers.contains(where: { $0 === AboutWindowController.shared }) {
            activeControllers.append(AboutWindowController.shared)
        }
    }

    // MARK: - Helpers

    private func prepareSampleFile(name: String, content: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CC-Gallery-\(name)")
        try? content.data(using: .utf8)?.write(to: url)
        tempFiles.append(url)
        return url
    }
}
