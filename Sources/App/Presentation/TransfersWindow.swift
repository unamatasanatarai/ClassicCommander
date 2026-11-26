import AppKit

/// The queue: every copy and move (local, upload, download) with progress, speed, elapsed time,
/// and each file as pending, copying, copied, skipped or failed. Cancel stops a job (nothing
/// unfinished is reported as done); Retry re-runs the failed files, resuming partial ones where
/// the server allows. "Remove completed" takes finished files and jobs off the lists at once.
public final class TransfersWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
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
    private let allDoneBadge = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry failed", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear finished", target: nil, action: nil)
    private var monitor: Any?

    init(manager: TransferManager, defaults: UserDefaults = .standard) {
        self.manager = manager
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 320), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = AppWindows.title("Queue")
        AppWindows.style(window)
        window.minSize = NSSize(width: 580, height: 240)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()
        window.setFrameAutosaveName("Transfers")
        setupKeyMonitor()
    }

    deinit {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    }

    private func setupKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let win = self.window, win.isKeyWindow else { return event }
            if self.handleKey(event) { return nil }
            return event
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Escape
            let active = manager.jobs.contains { TransferManager.isUnfinished($0) }
            if !active {
                close()
                return true
            }
        }
        return false
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

        for (id, title, width) in [("state", "Status", 175), ("file", "File", 530), ("size", "Size", 110)] {
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

        allDoneBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        allDoneBadge.textColor = .systemGreen
        allDoneBadge.alignment = .left

        for (b, sel) in [(cancelButton, #selector(cancelSelected)), (retryButton, #selector(retrySelected)), (clearButton, #selector(clearFinished))] {
            b.bezelStyle = .rounded
            b.target = self
            b.action = sel
        }
        let buttons = NSStackView(views: [cancelButton, retryButton, allDoneBadge, NSView(), removeCompletedBox, clearButton])

        let topContainer = NSView()
        topContainer.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(labelWithString: "Files of the selected job:")
        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor

        let bottomContainer = NSView()
        let bottomStack = NSStackView(views: [detailLabel, detailScroll])
        bottomStack.orientation = .vertical
        bottomStack.alignment = .leading
        bottomStack.spacing = 4
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomContainer.addSubview(bottomStack)

        let splitView = NSSplitView()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autosaveName = NSSplitView.AutosaveName("QueueSplitView")
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addSubview(topContainer)
        splitView.addSubview(bottomContainer)
        splitView.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        let root = NSView()
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: topContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: topContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: topContainer.bottomAnchor),

            bottomStack.leadingAnchor.constraint(equalTo: bottomContainer.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: bottomContainer.trailingAnchor),
            bottomStack.topAnchor.constraint(equalTo: bottomContainer.topAnchor, constant: 4),
            bottomStack.bottomAnchor.constraint(equalTo: bottomContainer.bottomAnchor),
            detailLabel.widthAnchor.constraint(equalTo: bottomStack.widthAnchor),
            detailScroll.widthAnchor.constraint(equalTo: bottomStack.widthAnchor),

            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            splitView.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            splitView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),

            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            buttons.heightAnchor.constraint(equalToConstant: 24),

            topContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            bottomContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        return root
    }

    // MARK: NSSplitViewDelegate

    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 60
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return max(60, splitView.bounds.height - 70)
    }

    public func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        return drawnRect.insetBy(dx: 0, dy: -4)
    }

    public func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        splitView.adjustSubviews()
    }

    var selectedJob: TransferJob? {
        if manager.jobs.indices.contains(table.selectedRow) {
            return manager.jobs[table.selectedRow]
        }
        return manager.jobs.first { TransferManager.isUnfinished($0) } ?? manager.jobs.last
    }

    /// Redraws rows and the details of the selected job (called on every progress update).
    public func refresh() {
        if removeCompletedBox.state == .on { manager.removeCompleted() }
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0 && selected < manager.jobs.count {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        } else if !manager.jobs.isEmpty {
            let defaultIdx = manager.jobs.firstIndex(where: { TransferManager.isUnfinished($0) }) ?? (manager.jobs.count - 1)
            table.selectRowIndexes(IndexSet(integer: defaultIdx), byExtendingSelection: false)
        }
        showDetails()
    }

    private func showDetails() {
        guard let job = selectedJob else {
            fileRows = []
            files.reloadData()
            cancelButton.isEnabled = false
            cancelButton.title = "Cancel"
            retryButton.isEnabled = false
            updateAllDoneStatus()
            return
        }
        let hideDone = removeCompletedBox.state == .on
        fileRows = job.items.indices.filter { !(hideDone && job.results[$0] == .done) }
        files.reloadData()
        let isCancelling = job.cancelFlag.isCancelled && job.state != .cancelled
        cancelButton.isEnabled = TransferManager.isUnfinished(job) && !isCancelling
        cancelButton.title = isCancelling ? "Cancelling…" : "Cancel"
        retryButton.isEnabled = (job.state == .finished || job.state == .cancelled) && job.failedCount > 0

        updateAllDoneStatus()
    }

    private func updateAllDoneStatus() {
        if manager.jobs.isEmpty {
            allDoneBadge.stringValue = ""
            return
        }
        let hasUnfinished = manager.jobs.contains { TransferManager.isUnfinished($0) }
        if !hasUnfinished {
            let totalFailed = manager.jobs.reduce(0) { $0 + $1.failedCount }
            if totalFailed > 0 {
                allDoneBadge.textColor = .systemOrange
                allDoneBadge.stringValue = "● Finished (\(totalFailed) failed) — Press Esc to close"
            } else {
                allDoneBadge.textColor = .systemGreen
                allDoneBadge.stringValue = "● All transfers done — Press Esc to close"
            }
        } else {
            allDoneBadge.stringValue = ""
        }
    }

    /// "Pending", "Copying 45 %", "Copied", "Moved", "Skipped: …", "Failed: …", "Not done".
    static func status(of job: TransferJob, at index: Int) -> (String, NSColor) {
        switch job.results[index] {
        case .pending:
            if job.active.contains(index) {
                if job.cancelFlag.isCancelled {
                    return ("Cancelling…", .systemOrange)
                }
                let size = job.items[index].size
                let percent = size > 0 ? " \(Int(100 * Double(job.partial[index] ?? 0) / Double(size))) %" : "…"
                return ((job.isMove ? "Moving" : "Copying") + percent, .systemBlue)
            }
            return (job.cancelFlag.isCancelled || job.state == .cancelled) ? ("Not done", .secondaryLabelColor) : ("Pending", .secondaryLabelColor)
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
        refresh()
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
            bar.doubleValue = job.state == .finished && job.failedCount == 0 ? bar.maxValue : Double(job.bytesProcessed)
            bar.controlSize = .small
            return bar
        case "status":
            let label = NSTextField(labelWithString: job.statusText)
            if job.failedCount > 0 { label.textColor = .systemRed }
            return AppWindows.centeredCell(label)
        case "speed":
            let time = Int(job.elapsed)
            let text = job.state == .queued ? "" : "\(f.compact(Int64(job.speed)))/s · \(time / 60):\(String(format: "%02d", time % 60))"
            return AppWindows.centeredCell(NSTextField(labelWithString: text))
        default:
            let label = NSTextField(labelWithString: "\(job.title)   (\(f.size(job.bytesProcessed, as: sizeFormat)) of \(f.size(job.bytesTotal, as: sizeFormat)))")
            label.lineBreakMode = .byTruncatingMiddle
            return AppWindows.centeredCell(label)
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
            return AppWindows.centeredCell(label)
        case "size":
            let label = NSTextField(labelWithString: item.isFolder ? "folder" : EntryFormatter.shared.size(item.size, as: sizeFormat))
            label.alignment = .right
            return AppWindows.centeredCell(label)
        default:
            let label = NSTextField(labelWithString: EntryFormatter.visible(item.destination.displayPath))
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = "From \(item.source.displayPath)"
            return AppWindows.centeredCell(label)
        }
    }
}
