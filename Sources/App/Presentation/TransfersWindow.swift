import AppKit

/// The transfer queue: every upload/download job with progress, speed, elapsed time and per-file
/// results. Cancel stops a job (nothing unfinished is reported as done); Retry re-runs the failed
/// files, resuming partial ones where the server allows.
public final class TransfersWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let manager: TransferManager
    let table = NSTableView()
    let details = NSTextView()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry failed", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear finished", target: nil, action: nil)

    init(manager: TransferManager) {
        self.manager = manager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 460), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = "Transfers"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()
        window.setFrameAutosaveName("Transfers")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func present() {
        refresh()
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

        details.isEditable = false
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let detailScroll = NSScrollView()
        detailScroll.documentView = details
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        details.autoresizingMask = [.width]

        for (b, sel) in [(cancelButton, #selector(cancelSelected)), (retryButton, #selector(retrySelected)), (clearButton, #selector(clearFinished))] {
            b.bezelStyle = .rounded
            b.target = self
            b.action = sel
        }
        let buttons = NSStackView(views: [cancelButton, retryButton, NSView(), clearButton])
        let stack = NSStackView(views: [scroll, NSTextField(labelWithString: "Files of the selected transfer:"), detailScroll, buttons])
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
            detailScroll.heightAnchor.constraint(equalToConstant: 150),
        ])
        return root
    }

    private var selectedJob: TransferJob? {
        manager.jobs.indices.contains(table.selectedRow) ? manager.jobs[table.selectedRow] : manager.jobs.last
    }

    /// Redraws rows and the details of the selected job (called on every progress update).
    public func refresh() {
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0 && selected < manager.jobs.count {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        showDetails()
    }

    private func showDetails() {
        guard let job = selectedJob else {
            details.string = ""
            cancelButton.isEnabled = false
            retryButton.isEnabled = false
            return
        }
        var lines: [String] = []
        for (item, result) in zip(job.items, job.results) {
            let mark: String
            switch result {
            case .pending: mark = job.state == .cancelled ? "–  not done" : "…"
            case .done: mark = "✓"
            case .skipped(let why): mark = "↷  skipped: \(why)"
            case .failed(let why): mark = "✗  \(why)"
            }
            lines.append("\(mark)   \(item.isFolder ? "[folder] " : "")\(item.destination.displayPath)")
        }
        details.string = lines.joined(separator: "\n")
        cancelButton.isEnabled = job.state == .running || job.state == .queued
        retryButton.isEnabled = (job.state == .finished || job.state == .cancelled) && job.failedCount > 0
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

    public func numberOfRows(in tableView: NSTableView) -> Int { manager.jobs.count }

    public func tableViewSelectionDidChange(_ notification: Notification) { showDetails() }

    public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
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
            let label = NSTextField(labelWithString: "\(job.title)   (\(f.compact(job.bytesDone)) of \(f.compact(job.bytesTotal)))")
            label.lineBreakMode = .byTruncatingMiddle
            return label
        }
    }
}
