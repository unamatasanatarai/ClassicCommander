import AppKit

/// The questions file commands ask. `AlertPrompts` shows real dialogs; tests answer directly.
public protocol FileCommandPrompts: AnyObject {
    /// A text question (copy/move target, new folder name). nil means Cancel.
    func askText(title: String, message: String, defaultValue: String, okTitle: String) -> String?
    func confirm(title: String, message: String, okTitle: String) -> Bool
    /// The target already exists. Always called on the main thread.
    func resolveConflict(source: URL, existing: URL) -> (ConflictChoice, applyToAll: Bool)
    func showProblems(title: String, report: OperationReport)
}

/// F5 Copy, F6 Move/Rename, F7 New folder, F8 Delete — acting on the marked entries of the active
/// panel (or the entry under the cursor), with the other panel's folder as the default target.
/// Copies and moves run on a background queue; Esc cancels them between items.
public final class FileCommands {
    weak var commander: CommanderView?
    public var prompts: FileCommandPrompts = AlertPrompts()
    /// Off in tests, so operations finish before the call returns.
    public var runInBackground = true
    /// How F8 removes items; the Trash by default (tests swap in a plain delete of temp files).
    public var trash: ([URL]) -> OperationReport = FileCommandsCore.trash
    public private(set) var isBusy = false
    private var cancelFlag: CancelFlag?
    private let queue = DispatchQueue(label: "ClassicCommander.fileOperation", qos: .userInitiated)

    init(commander: CommanderView) {
        self.commander = commander
    }

    public func cancelRunning() {
        cancelFlag?.cancel()
    }

    // MARK: F5 / F6

    public func copy() {
        if commander?.ftp.transfer(move: false, prompts: prompts) == true { return }
        transfer(.copy)
    }

    public func move() {
        if commander?.ftp.transfer(move: true, prompts: prompts) == true { return }
        transfer(.move)
    }

    private func transfer(_ kind: TransferOperation.Kind) {
        guard !isBusy, let commander = commander else { return NSSound.beep() }
        let source = commander.activeView
        let other = commander.view(for: commander.model.activeSide.other)
        let items = source.model.operationTargets
        guard !items.isEmpty else { return NSSound.beep() }

        let verb = kind == .copy ? "Copy" : "Move"
        let message = "\(verb) \(Self.describe(items)) to:"
        let defaultTarget = other.model.directory.path == "/" ? "/" : other.model.directory.path + "/"
        guard let target = prompts.askText(title: verb, message: message, defaultValue: defaultTarget,
                                           okTitle: verb) else { return }

        let flag = CancelFlag()
        cancelFlag = flag
        isBusy = true
        let base = source.model.directory
        let sources = items.map(\.url)
        let prompts = self.prompts
        let background = runInBackground
        let operation = TransferOperation(
            kind: kind,
            resolve: { src, existing in
                if Thread.isMainThread { return prompts.resolveConflict(source: src, existing: existing) }
                return DispatchQueue.main.sync { prompts.resolveConflict(source: src, existing: existing) }
            },
            isCancelled: { flag.isCancelled },
            progress: { [weak self] url in
                let show: () -> Void = { self?.commander?.showHint("\(kind == .copy ? "Copying" : "Moving") \(url.lastPathComponent)…  (Esc cancels)", duration: 60) }
                if background { DispatchQueue.main.async(execute: show) } else { show() }
            }
        )
        let work = {
            let report = operation.run(sources: sources, target: target, base: base)
            let finish: () -> Void = { [weak self] in self?.finish(report, title: "\(verb) problems", marksFrom: source) }
            if background { DispatchQueue.main.async(execute: finish) } else { finish() }
        }
        if background { queue.async(execute: work) } else { work() }
    }

    // MARK: F7

    public func newFolder() {
        guard !isBusy, let commander = commander else { return NSSound.beep() }
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

    public func delete() {
        guard !isBusy, let commander = commander else { return NSSound.beep() }
        if commander.ftp.delete(prompts: prompts) { return }
        let panel = commander.activeView
        let items = panel.model.operationTargets
        guard !items.isEmpty else { return NSSound.beep() }
        guard prompts.confirm(title: "Delete", message: "Move \(Self.describe(items)) to the Trash?",
                              okTitle: "Move to Trash") else { return }
        let report = trash(items.map(\.url))
        finish(report, title: "Delete problems", marksFrom: panel)
    }

    // MARK: Shared

    private func finish(_ report: OperationReport, title: String, marksFrom panel: PanelView) {
        isBusy = false
        cancelFlag = nil
        if report.done > 0 && report.errors.isEmpty { panel.model.clearMarks() }
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

    func resolveConflict(source: URL, existing: URL) -> (ConflictChoice, applyToAll: Bool) {
        let f = EntryFormatter.shared
        func info(_ url: URL) -> String {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = v?.fileSize.map { f.grouped(Int64($0)) + " bytes" } ?? "folder"
            let date = v?.contentModificationDate.map {
                f.date(FileEntry(name: "", url: url, kind: .file, modified: $0))
            } ?? ""
            return "\(size)  \(date)"
        }
        let alert = NSAlert()
        alert.messageText = "“\(existing.lastPathComponent)” already exists"
        alert.informativeText = "Overwrite:\n   \(info(existing))\nwith:\n   \(info(source))"
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do this for all remaining conflicts"
        let response = Modal.run(alert)
        let all = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.overwrite, all)
        case .alertSecondButtonReturn: return (.skip, all)
        default: return (.cancel, false)
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
