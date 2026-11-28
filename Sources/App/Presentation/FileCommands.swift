import AppKit

private final class BlockAction: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func invoke() { block() }
}

/// The questions file commands ask. `AlertPrompts` shows real dialogs; tests answer directly.
public protocol FileCommandPrompts: AnyObject {
    /// A text question (copy/move target, new folder name). nil means Cancel.
    func askText(title: String, message: String, defaultValue: String, okTitle: String) -> String?
    func confirm(title: String, message: String, okTitle: String) -> Bool
    /// The Copy / Move dialog: target, "only files of type", Verify, OK or Queue. nil means Cancel.
    func askTransfer(_ question: TransferQuestion) -> TransferAnswer?
    /// Unpack dialog: destination path and "Overwrite existing files" checkbox. nil means Cancel.
    func askUnpack(archiveName: String, defaultTarget: String) -> (target: String, overwrite: Bool)?
    /// "Target file exists": replace, skip, rename… Always called on the main thread.
    func resolveConflict(_ conflict: TransferConflict) -> ConflictDecision
    func showProblems(title: String, report: OperationReport)
}

extension FileCommandPrompts {
    /// Just the target (the other options at their defaults), through `askText`.
    public func askTransfer(_ question: TransferQuestion) -> TransferAnswer? {
        askText(title: question.verb, message: question.message, defaultValue: question.defaultTarget, okTitle: question.verb)
            .map { TransferAnswer(target: $0) }
    }

    public func askUnpack(archiveName: String, defaultTarget: String) -> (target: String, overwrite: Bool)? {
        askText(title: "Unpack Files", message: "Unpack \(archiveName) to:", defaultValue: defaultTarget, okTitle: "Unpack")
            .map { ($0, false) }
    }
}

/// F5 Copy, F6 Move/Rename, F7 New folder, F8 Delete — acting on the marked entries of the active
/// panel (or the entry under the cursor), with the other panel's folder as the default target.
/// Copies and moves run in the queue (Net → Queue), local and FTP/SFTP alike.
public final class FileCommands {
    weak var commander: CommanderView?
    public var prompts: FileCommandPrompts = AlertPrompts()
    /// Off in tests, so operations finish before the call returns.
    public var runInBackground = true
    /// How F8 removes items; the Trash by default (tests swap in a plain delete of temp files).
    public var trash: ([URL]) -> OperationReport = FileCommandsCore.trash
    /// How ⇧8 removes items for good (tests swap it like `trash`).
    public var remove: ([URL]) -> OperationReport = FileCommandsCore.remove
    private let planning = DispatchQueue(label: "ClassicCommander.planning", qos: .userInitiated)

    init(commander: CommanderView) {
        self.commander = commander
    }

    // MARK: F5 / F6

    public func copy() {
        if commander?.ftp.transfer(move: false, prompts: prompts) == true { return }
        transfer(move: false, drop: nil)
    }

    public func move() {
        if commander?.ftp.transfer(move: true, prompts: prompts) == true { return }
        transfer(move: true, drop: nil)
    }

    /// Alt+F5: Pack selected items into an archive in the other panel's directory.
    public func pack() {
        guard let (sourcePanel, items, targetDir) = validatedPackContext() else { return NSSound.beep() }
        let defaultArchive = Self.defaultPackArchivePath(items: items, sourceDir: sourcePanel.model.directory, targetDir: targetDir)
        guard let answer = prompts.askText(title: "Pack Files", message: "Pack \(Self.describe(items)) to:",
                                           defaultValue: defaultArchive, okTitle: "Pack") else { return }
        runPackJob(items: items, from: sourcePanel.model.directory, to: URL(fileURLWithPath: answer, isDirectory: false), sourcePanel: sourcePanel)
    }

    private func validatedPackContext() -> (PanelView, [FileEntry], URL)? {
        guard let commander = commander else { return nil }
        let sourcePanel = commander.activeView
        guard !sourcePanel.model.isRemote, !sourcePanel.model.isInsideZip else { return nil }
        let items = sourcePanel.model.operationTargets
        let targetDir = commander.view(for: commander.model.activeSide.other).model.directory
        guard !items.isEmpty, !targetDir.isRemoteLocation, ZipArchive.split(targetDir) == nil else { return nil }
        return (sourcePanel, items, targetDir)
    }

    private static func defaultPackArchivePath(items: [FileEntry], sourceDir: URL, targetDir: URL) -> String {
        let baseName = items.count == 1 ? items[0].url.deletingPathExtension().lastPathComponent : sourceDir.lastPathComponent
        return targetDir.appendingPathComponent("\(baseName).zip").path
    }

    private func runPackJob(items: [FileEntry], from sourceDir: URL, to archiveURL: URL, sourcePanel: PanelView) {
        var runningProcess: Process?
        var cancelled = false
        let (progressWindow, cancelHandler) = makePackProgressWindow(archiveName: archiveURL.lastPathComponent) {
            cancelled = true
            runningProcess?.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var packError: Error?
            do { try ZipArchive.pack(items: items, from: sourceDir, to: archiveURL) { runningProcess = $0 } }
            catch { packError = error }
            DispatchQueue.main.async {
                _ = cancelHandler
                progressWindow.orderOut(nil)
                self.finishPackJob(error: packError, cancelled: cancelled, archiveURL: archiveURL, sourcePanel: sourcePanel)
            }
        }
    }

    private func finishPackJob(error: Error?, cancelled: Bool, archiveURL: URL, sourcePanel: PanelView) {
        if cancelled { try? FileManager.default.removeItem(at: archiveURL); return }
        if error != nil { NSSound.beep(); return }
        sourcePanel.model.clearMarks()
        commander?.reloadPanels()
    }

    private func makePackProgressWindow(archiveName: String, onCancel: @escaping () -> Void) -> (NSWindow, BlockAction) {
        let progressWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 116),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        progressWindow.title = AppWindows.title("Pack Files")
        AppWindows.style(progressWindow)
        let content = NSView()
        let label = NSTextField(labelWithString: "Packing \(archiveName)…")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
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
        progressWindow.contentView = content
        AppWindows.place(progressWindow)
        progressWindow.makeKeyAndOrderFront(nil)
        let cancelHandler = BlockAction(onCancel)
        cancelBtn.target = cancelHandler
        cancelBtn.action = #selector(BlockAction.invoke)
        return (progressWindow, cancelHandler)
    }

    /// Alt+F9: Unpack the archive under the cursor into the other panel's directory.
    public func unpack() {
        guard let commander = commander, let entry = unpackableEntry(in: commander) else { return NSSound.beep() }
        let targetDir = commander.view(for: commander.model.activeSide.other).model.directory
        guard !targetDir.isRemoteLocation, ZipArchive.split(targetDir) == nil else { NSSound.beep(); return }
        guard let answer = prompts.askUnpack(archiveName: entry.name, defaultTarget: targetDir.path) else { return }
        performUnpack(entry: entry, target: answer.target, overwrite: answer.overwrite, commander: commander)
    }

    private func performUnpack(entry: FileEntry, target: String, overwrite: Bool, commander: CommanderView) {
        do {
            try ZipArchive.unpack(archive: entry.url, to: URL(fileURLWithPath: target, isDirectory: true), overwrite: overwrite)
            commander.reloadPanels()
        } catch {
            NSSound.beep()
        }
    }

    private func unpackableEntry(in commander: CommanderView) -> FileEntry? {
        let panel = commander.activeView
        guard !panel.model.isRemote, !panel.model.isInsideZip,
              let entry = panel.model.currentEntry, entry.kind == .file else { return nil }
        return entry
    }

    /// Files dropped on a panel: 5 Copy (6 Move) of exactly those files into the drop's folder,
    /// with the usual dialog. Works for servers on either side.
    public func drop(_ drop: PanelDrop) {
        if commander?.ftp.transfer(move: drop.move, prompts: prompts, drop: drop) == true { return }
        transfer(move: drop.move, drop: drop)
    }

    /// 5 / 6 on local folders: the marked entries of the active panel to the other panel,
    /// or the files of a drop into its folder.
    /// The Copy / Move dialog's question for these entries; it counts them (with a mask) when asked.
    static func question(verb: String, items: [FileEntry], target: String) -> TransferQuestion {
        TransferQuestion(verb: verb, message: "\(verb) \(describe(items)) to:", defaultTarget: target,
                         count: { mask, cancel in TransferStats.count(items, mask: mask, cancel: cancel) })
    }

    /// 5 / 6 on local folders: the marked entries of the active panel to the other panel, or the
    /// files of a drop into its folder. Planned in the background, then handed to the queue.
    private func transfer(move: Bool, drop: PanelDrop?) {
        guard let commander = commander else { return NSSound.beep() }
        let (source, items, folder) = resolveLocalTransferTarget(drop: drop, commander: commander)
        guard !items.isEmpty else { return NSSound.beep() }
        if source?.model.isInsideZip == true {
            transferFromZip(items: items, source: source, folder: folder, move: move, isDrop: drop != nil, commander: commander)
            return
        }
        if ZipArchive.split(folder) != nil { NSSound.beep(); return }
        promptAndRunLocalTransfer(items: items, source: source, folder: folder, move: move)
    }

    private func promptAndRunLocalTransfer(items: [FileEntry], source: PanelView?, folder: URL, move: Bool) {
        let verb = move ? "Move" : "Copy"
        guard let answer = prompts.askTransfer(Self.question(verb: verb, items: items, target: Self.defaultLocalTarget(folder))) else { return }
        let (planned, create, title) = planLocalTransfer(items: items, target: answer.target, base: source?.model.directory ?? folder, move: move, verb: verb)
        if !planned.isEmpty {
            runNonEmptyLocalTransfer(planned, items: items, source: source, title: title, create: create, move: move, answer: answer)
        }
    }

    private static func defaultLocalTarget(_ folder: URL) -> String {
        folder.path == "/" ? "/" : folder.path + "/"
    }

    private func runNonEmptyLocalTransfer(
        _ planned: [(TransferPlanner.Source, TransferLocation)], items: [FileEntry], source: PanelView?,
        title: String, create: URL?, move: Bool, answer: TransferAnswer
    ) {
        source?.model.clearMarks()   // Select → Restore Selection brings them back
        startPlannedLocalTransfer(planned, items: items, title: title, create: create, move: move, answer: answer)
    }

    private func startPlannedLocalTransfer(
        _ planned: [(TransferPlanner.Source, TransferLocation)], items: [FileEntry],
        title: String, create: URL?, move: Bool, answer: TransferAnswer
    ) {
        let cancelFlag = CancelFlag()
        let progressWindow = makeBackgroundProgress(
            enabled: runInBackground && !answer.queue, verb: move ? "Move" : "Copy",
            fromDesc: items.first?.name ?? "", toDesc: create?.path ?? answer.target, cancelFlag: cancelFlag
        )
        runPlannedTransfer(planned, title: title, create: create, move: move, answer: answer,
                           progressWindow: progressWindow, cancelFlag: cancelFlag)
    }

    private func runPlannedTransfer(
        _ planned: [(TransferPlanner.Source, TransferLocation)],
        title: String,
        create: URL?,
        move: Bool,
        answer: TransferAnswer,
        progressWindow: TransferProgressWindowController?,
        cancelFlag: CancelFlag
    ) {
        let work = { [weak self] in
            let result = Result { try TransferPlanner.plan(planned, move: move, mask: answer.fileMask, cancel: cancelFlag) }
            let finish: () -> Void = { self?.enqueue(result, title: title, create: create, move: move, answer: answer,
                                                     existingProgressWindow: progressWindow, cancelFlag: cancelFlag) }
            if self?.runInBackground == true { DispatchQueue.main.async(execute: finish) } else { finish() }
        }
        if runInBackground { planning.async(execute: work) } else { work() }
    }

    private func resolveLocalTransferTarget(drop: PanelDrop?, commander: CommanderView) -> (PanelView?, [FileEntry], URL) {
        if let drop = drop {
            return (drop.source, drop.entries, drop.folder)
        }
        return (commander.activeView,
                commander.activeView.model.operationTargets,
                commander.view(for: commander.model.activeSide.other).model.directory)
    }

    private func makeBackgroundProgress(
        enabled: Bool,
        verb: String,
        fromDesc: String,
        toDesc: String,
        cancelFlag: CancelFlag
    ) -> TransferProgressWindowController? {
        guard enabled else { return nil }
        let pw = TransferProgressWindowController(title: verb, from: fromDesc, to: toDesc,
                                                  cancelFlag: cancelFlag, onCancel: nil) { [weak self] in
            self?.commander?.ftp.transfersWindow.present()
        }
        pw.present()
        return pw
    }

    private func planLocalTransfer(
        items: [FileEntry],
        target: String,
        base: URL,
        move: Bool,
        verb: String
    ) -> ([(TransferPlanner.Source, TransferLocation)], URL?, String) {
        let (pairs, create) = TransferTarget.plan(sources: items.map(\.url), target: target, base: base)
        var problems: [String] = []
        var planned: [(TransferPlanner.Source, TransferLocation)] = []
        for (entry, pair) in zip(items, pairs) {
            if let problem = TransferTarget.problem(pair.0, pair.1, move: move) { problems.append(problem); continue }
            // A symbolic link is copied or moved as the link (it has no data), never as what it points to.
            planned.append((TransferPlanner.Source(location: .local(pair.0), isFolder: entry.kind == .directory && !entry.isSymlink,
                                                   size: entry.isSymlink ? 0 : entry.size ?? 0, modified: entry.modified), .local(pair.1)))
        }
        if !problems.isEmpty {
            var report = OperationReport()
            report.errors = problems
            prompts.showProblems(title: "\(verb) problems", report: report)
        }
        let title = "\(verb) \(Self.describe(items)) → \(create?.path ?? pairs.first?.1.deletingLastPathComponent().path ?? "")"
        return (planned, create, title)
    }

    private func transferFromZip(
        items: [FileEntry],
        source: PanelView?,
        folder: URL,
        move: Bool,
        isDrop: Bool,
        commander: CommanderView
    ) {
        if move { NSSound.beep(); return }
        guard let targetDir = resolveZipExtractTarget(items: items, folder: folder, isDrop: isDrop),
              ZipArchive.split(targetDir) == nil else { NSSound.beep(); return }
        do {
            try ZipArchive.extractItems(items, to: targetDir, resolveConflict: { [prompts] conflict in
                prompts.resolveConflict(conflict)
            })
            source?.model.clearMarks()
            reloadBothPanels(in: commander)
        } catch {
            NSSound.beep()
        }
    }

    private func resolveZipExtractTarget(items: [FileEntry], folder: URL, isDrop: Bool) -> URL? {
        if isDrop { return folder }
        let q = Self.question(verb: "Copy", items: items, target: folder.path)
        guard let answer = prompts.askTransfer(q) else { return nil }
        return URL(fileURLWithPath: answer.target, isDirectory: true)
    }

    private func reloadBothPanels(in commander: CommanderView) {
        for view in [commander.leftView, commander.rightView] {
            view.model.reload(visibleRows: view.visibleRows)
            view.needsDisplay = true
        }
    }

    /// Hands a planned copy or move to the queue (the queue window shows it if it takes a while).
    private func enqueue(_ result: Result<TransferPlanner.Plan, Error>, title: String, create: URL?, move: Bool, answer: TransferAnswer,
                         existingProgressWindow: TransferProgressWindowController? = nil, cancelFlag: CancelFlag? = nil) {
        guard let commander = commander, cancelFlag?.isCancelled != true else {
            existingProgressWindow?.close()
            return
        }
        switch result {
        case .failure(let error):
            existingProgressWindow?.close()
            handlePlanFailure(error, move: move)
        case .success(let plan):
            enqueuePlan(plan, title: title, create: create, move: move, answer: answer,
                        commander: commander, existingProgressWindow: existingProgressWindow)
        }
    }

    private func enqueuePlan(
        _ plan: TransferPlanner.Plan, title: String, create: URL?, move: Bool, answer: TransferAnswer,
        commander: CommanderView, existingProgressWindow: TransferProgressWindowController?
    ) {
        guard !plan.items.isEmpty else {
            existingProgressWindow?.close()
            commander.showHint("No files match “\(answer.mask)”", duration: 2)
            return NSSound.beep()
        }
        var items = plan.items
        if let folder = create {
            items.insert(TransferItem(source: .local(folder), destination: .local(folder), size: 0, isFolder: true), at: 0)
        }
        let job = TransferJob(title: title, items: items, isMove: move, sourceFoldersToRemove: move ? plan.foldersToRemove : [])
        job.verify = answer.verify
        job.waitsInQueue = answer.queue
        commander.ftp.startJob(job, synchronously: !runInBackground, existingProgressWindow: existingProgressWindow)
    }

    private func handlePlanFailure(_ error: Error, move: Bool) {
        if let ftpErr = error as? FTPError, ftpErr == .cancelled { return }
        var report = OperationReport()
        report.errors = [error.localizedDescription]
        prompts.showProblems(title: "\(move ? "Move" : "Copy") problems", report: report)
    }

    // MARK: F7

    public func newFolder() {
        guard let commander = commander else { return NSSound.beep() }
        if commander.ftp.newFolder(prompts: prompts) { return }
        let panel = commander.activeView
        guard let name = prompts.askText(title: "New Folder", message: "New folder (directory):",
                                         defaultValue: "", okTitle: "Create") else { return }
        do {
            let created = try FileCommandsCore.makeFolder(named: name, in: panel.model.directory)
            commander.reloadPanels()
            panel.model.focus(name: created, visibleRows: panel.visibleRows)
            panel.needsDisplay = true
        } catch {
            var report = OperationReport()
            report.errors = ["\(name): \(error.localizedDescription)"]
            prompts.showProblems(title: "New folder", report: report)
        }
    }

    // MARK: F8

    /// 8 moves to the Trash; ⇧8 (`permanently`) deletes for good, after a clear warning.
    /// On a server there is no Trash: both delete permanently.
    public func delete(permanently: Bool = false) {
        guard let commander = commander else { return NSSound.beep() }
        if commander.ftp.delete(prompts: prompts) { return }
        let panel = commander.activeView
        let items = panel.model.operationTargets
        guard !items.isEmpty, !panel.model.isInsideZip else { return NSSound.beep() }
        guard let report = confirmAndDelete(items: items, permanently: permanently) else { return }
        finish(report, title: "Delete problems", marksFrom: panel)
    }

    private func confirmAndDelete(items: [FileEntry], permanently: Bool) -> OperationReport? {
        let title = permanently ? "Delete permanently" : "Delete"
        let message = permanently
            ? "Permanently delete \(Self.describe(items))?\nThey don't go to the Trash and can't be restored."
            : "Move \(Self.describe(items)) to the Trash?"
        let okTitle = permanently ? "Delete Permanently" : "Move to Trash"
        guard prompts.confirm(title: title, message: message, okTitle: okTitle) else { return nil }
        return (permanently ? remove : trash)(items.map(\.url))
    }

    // MARK: Shared

    private func finish(_ report: OperationReport, title: String, marksFrom panel: PanelView?) {
        if report.done > 0 && report.errors.isEmpty { panel?.model.clearMarks() }
        commander?.reloadPanels()
        commander?.showHint(report.cancelled ? "Cancelled" : "Done", duration: 0.8)
        if !report.errors.isEmpty { prompts.showProblems(title: title, report: report) }
    }

    /// "“notes.txt”", "folder “media”", "3 files and 2 folders".
    static func describe(_ items: [FileEntry]) -> String {
        if items.count == 1, let item = items.first {
            return item.kind == .directory ? "folder “\(item.name)”" : "“\(item.name)”"
        }
        let files = items.filter { $0.kind == .file }.count
        let dirs = items.count - files
        var parts: [String] = []
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        if dirs > 0 { parts.append("\(dirs) folder\(dirs == 1 ? "" : "s")") }
        return parts.joined(separator: " and ")
    }
}

/// Real dialogs for file commands.
final class AlertPrompts: FileCommandPrompts {
    func askText(title: String, message: String, defaultValue: String, okTitle: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard Modal.run(alert) == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    func confirm(title: String, message: String, okTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = title.lowercased().contains("permanently") ? .critical : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: "Cancel")
        return Modal.run(alert) == .alertFirstButtonReturn
    }

    /// Sizes in the dialogs (Options → Display).
    var sizeFormat: SizeFormat = .readable

    func askTransfer(_ question: TransferQuestion) -> TransferAnswer? {
        TransferDialogController(question: question, sizeFormat: sizeFormat).run()
    }

    func askUnpack(archiveName: String, defaultTarget: String) -> (target: String, overwrite: Bool)? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Unpack Files"
        alert.informativeText = "Unpack \(archiveName) to:"
        alert.addButton(withTitle: "Unpack")
        alert.addButton(withTitle: "Cancel")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
        let field = NSTextField(string: defaultTarget)
        field.frame = NSRect(x: 0, y: 28, width: 320, height: 24)
        let checkbox = NSButton(checkboxWithTitle: "Overwrite existing files", target: nil, action: nil)
        checkbox.state = .off
        checkbox.frame = NSRect(x: 0, y: 0, width: 320, height: 20)
        container.addSubview(field)
        container.addSubview(checkbox)
        alert.accessoryView = container
        alert.window.initialFirstResponder = field
        guard Modal.run(alert) == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (text, checkbox.state == .on)
    }

    func resolveConflict(_ conflict: TransferConflict) -> ConflictDecision {
        ConflictDialogController(conflict: conflict, sizeFormat: sizeFormat).run { [weak self] suggested in
            self?.askText(title: "Rename", message: "New name for the copy of “\(conflict.source.name)”:",
                          defaultValue: suggested, okTitle: "Rename")
        }
    }

    func showProblems(title: String, report: OperationReport) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        let count = report.errors.count
        alert.informativeText = "\(count) \(count == 1 ? "item" : "items") could not be processed:"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 444, height: 180))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = report.errors.joined(separator: "\n")
        scroll.documentView = textView
        alert.accessoryView = scroll
        Modal.run(alert)
    }
}
