import AppKit

/// The questions file commands ask. `AlertPrompts` shows real dialogs; tests answer directly.
public protocol FileCommandPrompts: AnyObject {
    /// A text question (copy/move target, new folder name). nil means Cancel.
    func askText(title: String, message: String, defaultValue: String, okTitle: String) -> String?
    func confirm(title: String, message: String, okTitle: String) -> Bool
    /// The Copy / Move dialog: target, "only files of type", Verify, OK or Queue. nil means Cancel.
    func askTransfer(_ question: TransferQuestion) -> TransferAnswer?
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
        var source: PanelView? = commander.activeView
        var items = commander.activeView.model.operationTargets
        var folder = commander.view(for: commander.model.activeSide.other).model.directory
        if let drop = drop {
            source = drop.source
            items = drop.entries
            folder = drop.folder
        }
        guard !items.isEmpty else { return NSSound.beep() }

        let verb = move ? "Move" : "Copy"
        let defaultTarget = folder.path == "/" ? "/" : folder.path + "/"
        guard let answer = prompts.askTransfer(Self.question(verb: verb, items: items, target: defaultTarget)) else { return }

        let base = source?.model.directory ?? folder
        let (pairs, create) = TransferTarget.plan(sources: items.map(\.url), target: answer.target, base: base)
        var problems: [String] = []
        var planned: [(TransferPlanner.Source, TransferLocation)] = []
        for (entry, pair) in zip(items, pairs) {
            if let problem = TransferTarget.problem(pair.0, pair.1, move: move) { problems.append(problem); continue }
            planned.append((TransferPlanner.Source(location: .local(pair.0), isFolder: entry.kind == .directory,
                                                   size: entry.size ?? 0, modified: entry.modified), .local(pair.1)))
        }
        if !problems.isEmpty {
            var report = OperationReport()
            report.errors = problems
            prompts.showProblems(title: "\(verb) problems", report: report)
        }
        guard !planned.isEmpty else { return }
        source?.model.clearMarks()   // Select → Restore Selection brings them back
        let title = "\(verb) \(Self.describe(items)) → \(create?.path ?? pairs.first?.1.deletingLastPathComponent().path ?? "")"
        let work = { [weak self] in
            let result = Result { try TransferPlanner.plan(planned, move: move, mask: answer.fileMask) }
            let finish: () -> Void = { self?.enqueue(result, title: title, create: create, move: move, answer: answer) }
            if self?.runInBackground == true { DispatchQueue.main.async(execute: finish) } else { finish() }
        }
        if runInBackground { planning.async(execute: work) } else { work() }
    }

    /// Hands a planned copy or move to the queue (the queue window shows it if it takes a while).
    private func enqueue(_ result: Result<TransferPlanner.Plan, Error>, title: String, create: URL?, move: Bool, answer: TransferAnswer) {
        guard let commander = commander else { return }
        switch result {
        case .failure(let error):
            var report = OperationReport()
            report.errors = [error.localizedDescription]
            prompts.showProblems(title: "\(move ? "Move" : "Copy") problems", report: report)
        case .success(let plan):
            guard !plan.items.isEmpty else {
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
            commander.ftp.startJob(job, synchronously: !runInBackground)
        }
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
        guard !items.isEmpty else { return NSSound.beep() }
        let report: OperationReport
        if permanently {
            guard prompts.confirm(title: "Delete permanently",
                                  message: "Permanently delete \(Self.describe(items))?\nThey don't go to the Trash and can't be restored.",
                                  okTitle: "Delete Permanently") else { return }
            report = remove(items.map(\.url))
        } else {
            guard prompts.confirm(title: "Delete", message: "Move \(Self.describe(items)) to the Trash?",
                                  okTitle: "Move to Trash") else { return }
            report = trash(items.map(\.url))
        }
        finish(report, title: "Delete problems", marksFrom: panel)
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
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard Modal.run(alert) == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    func confirm(title: String, message: String, okTitle: String) -> Bool {
        let alert = NSAlert()
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

    func resolveConflict(_ conflict: TransferConflict) -> ConflictDecision {
        ConflictDialogController(conflict: conflict, sizeFormat: sizeFormat).run { [weak self] suggested in
            self?.askText(title: "Rename", message: "New name for the copy of “\(conflict.source.name)”:",
                          defaultValue: suggested, okTitle: "Rename")
        }
    }

    func showProblems(title: String, report: OperationReport) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        let shown = report.errors.prefix(12).joined(separator: "\n")
        let more = report.errors.count > 12 ? "\n…and \(report.errors.count - 12) more" : ""
        alert.informativeText = shown + more
        Modal.run(alert)
    }
}
