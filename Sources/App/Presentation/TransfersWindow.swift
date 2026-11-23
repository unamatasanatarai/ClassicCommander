import AppKit

/// The queue: every copy and move (local, upload, download) with progress, speed, elapsed time,
/// and each file as pending, copying, copied, skipped or failed. Cancel stops a job (nothing
/// unfinished is reported as done); Retry re-runs the failed files, resuming partial ones where
/// the server allows. "Remove completed" takes finished files and jobs off the lists at once.
public final class TransfersWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let manager: TransferManager
    let table = NSTableView()
    /// The files of the selected job.
    let files = NSTableView()
    let removeCompletedBox = NSButton(checkboxWithTitle: "Remove completed", target: nil, action: nil)
    private let defaults: UserDefaults
    /// Sizes as chosen in Options → Display.
    var sizeFormat: SizeFormat = .readable { didSet { refresh() } }
    /// Rows of `files`: indexes into the selected job's items (completed ones left out when removing them).
    private(set) var fileRows: [Int] = []
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry failed", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear finished", target: nil, action: nil)

    init(manager: TransferManager, defaults: UserDefaults = .standard) {
        self.manager = manager
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = AppWindows.title("Queue")
        AppWindows.style(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()
        window.setFrameAutosaveName("Transfers")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func present() {
        refresh()
        if let window = window { AppWindows.place(window) }
        showWindow(nil)
        window?.orderFront(nil)
    }

    private func build() -> NSView {
        for (id, title, width) in [("job", "Transfer", 380), ("status", "Status", 170), ("progress", "Progress", 150), ("speed", "Speed · Time", 130)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = CGFloat(width)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for (id, title, width) in [("state", "Status", 140), ("file", "File", 560), ("size", "Size", 110)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = CGFloat(width)
            files.addTableColumn(c)
        }
        files.dataSource = self
        files.delegate = self
        files.rowHeight = 20
        files.usesAlternatingRowBackgroundColors = true
        let detailScroll = NSScrollView()
        detailScroll.documentView = files
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        removeCompletedBox.target = self
        removeCompletedBox.action = #selector(removeCompletedToggled)
        removeCompletedBox.state = defaults.bool(forKey: "queue.removeCompleted") ? .on : .off

        for (b, sel) in [(cancelButton, #selector(cancelSelected)), (retryButton, #selector(retrySelected)), (clearButton, #selector(clearFinished))] {
            b.bezelStyle = .rounded
            b.target = self
            b.action = sel
        }
        let buttons = NSStackView(views: [cancelButton, retryButton, NSView(), removeCompletedBox, clearButton])
        let stack = NSStackView(views: [scroll, NSTextField(labelWithString: "Files of the selected job:"), detailScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            detailScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        return root
    }

    var selectedJob: TransferJob? {
        manager.jobs.indices.contains(table.selectedRow) ? manager.jobs[table.selectedRow] : manager.jobs.last
    }

    /// Redraws rows and the details of the selected job (called on every progress update).
    public func refresh() {
        if removeCompletedBox.state == .on { manager.removeCompleted() }
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0 && selected < manager.jobs.count {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        showDetails()
    }

    private func showDetails() {
        guard let job = selectedJob else {
            fileRows = []
            files.reloadData()
            cancelButton.isEnabled = false
            retryButton.isEnabled = false
            return
        }
        let hideDone = removeCompletedBox.state == .on
        fileRows = job.items.indices.filter { !(hideDone && job.results[$0] == .done) }
        files.reloadData()
        cancelButton.isEnabled = TransferManager.isUnfinished(job)
        retryButton.isEnabled = (job.state == .finished || job.state == .cancelled) && job.failedCount > 0
    }

    /// "Pending", "Copying 45 %", "Copied", "Moved", "Skipped: …", "Failed: …", "Not done".
    static func status(of job: TransferJob, at index: Int) -> (String, NSColor) {
        switch job.results[index] {
        case .pending:
            if job.active.contains(index) {
                let size = job.items[index].size
                let percent = size > 0 ? " \(Int(100 * Double(job.partial[index] ?? 0) / Double(size))) %" : "…"
                return ((job.isMove ? "Moving" : "Copying") + percent, .systemBlue)
            }
            return job.state == .cancelled ? ("Not done", .secondaryLabelColor) : ("Pending", .secondaryLabelColor)
        case .done: return (job.items[index].isFolder ? "Created" : (job.isMove ? "Moved" : "Copied"), .systemGreen)
        case .skipped(let why): return ("Skipped: \(why)", .systemOrange)
        case .failed(let why): return ("Failed: \(why)", .systemRed)
        }
    }

    @objc func removeCompletedToggled() {
        defaults.set(removeCompletedBox.state == .on, forKey: "queue.removeCompleted")
        refresh()
    }

    @objc private func cancelSelected() {
        guard let job = selectedJob else { return }
        manager.cancel(job)
    }

    @objc private func retrySelected() {
        guard let job = selectedJob, let retry = job.retryJob() else { return NSSound.beep() }
        manager.enqueue(retry)
        refresh()
    }

    @objc private func clearFinished() {
        manager.clearFinished()
        refresh()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === files ? fileRows.count : manager.jobs.count
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) !== files { showDetails() }
    }

    public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        if tableView === files { return fileCell(column?.identifier.rawValue, row: row) }
        let job = manager.jobs[row]
        let f = EntryFormatter.shared
        switch column?.identifier.rawValue {
        case "progress":
            let bar = NSProgressIndicator()
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = Double(max(1, job.bytesTotal))
            bar.doubleValue = job.state == .finished && job.failedCount == 0 ? bar.maxValue : Double(job.bytesDone)
            bar.controlSize = .small
            return bar
        case "status":
            let label = NSTextField(labelWithString: job.statusText)
            if job.failedCount > 0 { label.textColor = .systemRed }
            return label
        case "speed":
            let time = Int(job.elapsed)
            let text = job.state == .queued ? "" : "\(f.compact(Int64(job.speed)))/s · \(time / 60):\(String(format: "%02d", time % 60))"
            return NSTextField(labelWithString: text)
        default:
            let label = NSTextField(labelWithString: "\(job.title)   (\(f.size(job.bytesDone, as: sizeFormat)) of \(f.size(job.bytesTotal, as: sizeFormat)))")
            label.lineBreakMode = .byTruncatingMiddle
            return label
        }
    }

    /// One file of the selected job: its status, where it goes, and its size.
    private func fileCell(_ column: String?, row: Int) -> NSView? {
        guard let job = selectedJob, fileRows.indices.contains(row) else { return nil }
        let index = fileRows[row]
        let item = job.items[index]
        switch column {
        case "state":
            let (text, color) = Self.status(of: job, at: index)
            let label = NSTextField(labelWithString: text)
            label.textColor = color
            label.toolTip = text
            return label
        case "size":
            let label = NSTextField(labelWithString: item.isFolder ? "folder" : EntryFormatter.shared.size(item.size, as: sizeFormat))
            label.alignment = .right
            return label
        default:
            let label = NSTextField(labelWithString: EntryFormatter.visible(item.destination.displayPath))
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = "From \(item.source.displayPath)"
            return label
        }
    }
}
