import AppKit
import CoreImage

/// Total Commander-style Copy / Move progress dialog showing:
/// - Operation, transfer speed and estimated time remaining
/// - Source ("From: ...") and destination ("To: ...")
/// - Current file progress bar and percentage
/// - Total progress bar and percentage
/// - File count and byte progress
/// - [Pause] [Cancel] [Background] buttons
public final class TransferProgressWindowController: NSWindowController {
    public private(set) var job: TransferJob?
    private let onBackground: () -> Void
    private var cancelFlag: CancelFlag?
    private var onCancel: (() -> Void)?
    private var isPreparing = false

    private let statusLabel = NSTextField(labelWithString: "")
    private let fromLabel = NSTextField(labelWithString: "From: ")
    private let toLabel = NSTextField(labelWithString: "To: ")
    private let fileProgress = NSProgressIndicator()
    private let filePercentLabel = NSTextField(labelWithString: "0 %")
    private let totalProgress = NSProgressIndicator()
    private let totalPercentLabel = NSTextField(labelWithString: "0 %")
    private let filesCountLabel = NSTextField(labelWithString: "")
    private let bytesCountLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let cancelButton = NSButton()
    private let backgroundButton = NSButton()

    public init(job: TransferJob, onBackground: @escaping () -> Void) {
        self.job = job
        self.onBackground = onBackground
        self.isPreparing = false
        self.cancelFlag = job.cancelFlag

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 195),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        let opName = job.isMove ? "Moving" : "Copying"
        window.title = AppWindows.title(opName)
        AppWindows.style(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()
        update()
    }

    /// Progress window started during the preparation / planning phase.
    public init(title: String, from: String, to: String, cancelFlag: CancelFlag, onCancel: (() -> Void)? = nil, onBackground: @escaping () -> Void) {
        self.job = nil
        self.onBackground = onBackground
        self.cancelFlag = cancelFlag
        self.onCancel = onCancel
        self.isPreparing = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 195),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = AppWindows.title(title)
        AppWindows.style(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = build()

        statusLabel.stringValue = "Preparing \(title.lowercased())…"
        fromLabel.stringValue = "From: " + from
        toLabel.stringValue = "To: " + to
        fileProgress.isIndeterminate = true
        fileProgress.startAnimation(nil)
        totalProgress.isIndeterminate = true
        totalProgress.startAnimation(nil)
        filePercentLabel.stringValue = "…"
        totalPercentLabel.stringValue = "…"
        filesCountLabel.stringValue = "Scanning files…"
        bytesCountLabel.stringValue = ""
        pauseButton.isEnabled = false
        backgroundButton.isEnabled = false
    }

    /// Transitions from the preparation phase to active transfer.
    public func startActive(job: TransferJob) {
        self.job = job
        self.cancelFlag = job.cancelFlag
        self.isPreparing = false
        fileProgress.stopAnimation(nil)
        fileProgress.isIndeterminate = false
        totalProgress.stopAnimation(nil)
        totalProgress.isIndeterminate = false
        pauseButton.isEnabled = true
        backgroundButton.isEnabled = true
        let opName = job.isMove ? "Moving" : "Copying"
        window?.title = AppWindows.title(opName)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func present() {
        guard let window = window else { return }
        AppWindows.place(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSView {
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.alignment = .center

        fromLabel.font = .systemFont(ofSize: 11)
        fromLabel.lineBreakMode = .byTruncatingMiddle
        toLabel.font = .systemFont(ofSize: 11)
        toLabel.lineBreakMode = .byTruncatingMiddle

        fileProgress.isIndeterminate = false
        fileProgress.minValue = 0
        fileProgress.maxValue = 100
        fileProgress.heightAnchor.constraint(equalToConstant: 16).isActive = true

        filePercentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        filePercentLabel.alignment = .right
        filePercentLabel.widthAnchor.constraint(equalToConstant: 45).isActive = true

        let fileRow = NSStackView(views: [fileProgress, filePercentLabel])
        fileRow.spacing = 8
        fileRow.alignment = NSLayoutConstraint.Attribute.centerY

        totalProgress.isIndeterminate = false
        totalProgress.minValue = 0
        totalProgress.maxValue = 100
        totalProgress.heightAnchor.constraint(equalToConstant: 18).isActive = true

        totalPercentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        totalPercentLabel.alignment = .right
        totalPercentLabel.widthAnchor.constraint(equalToConstant: 45).isActive = true

        let totalRow = NSStackView(views: [totalProgress, totalPercentLabel])
        totalRow.spacing = 8
        totalRow.alignment = NSLayoutConstraint.Attribute.centerY

        filesCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        filesCountLabel.textColor = .secondaryLabelColor

        bytesCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        bytesCountLabel.textColor = .secondaryLabelColor
        bytesCountLabel.alignment = .right

        let statsRow = NSStackView(views: [filesCountLabel, NSView(), bytesCountLabel])
        statsRow.spacing = 8
        statsRow.alignment = NSLayoutConstraint.Attribute.centerY

        pauseButton.title = "Pause"
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(pausePressed)
        pauseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: AppWindows.Layout.buttonMinWidth).isActive = true

        backgroundButton.title = "Background"
        backgroundButton.bezelStyle = .rounded
        backgroundButton.target = self
        backgroundButton.action = #selector(backgroundPressed)
        backgroundButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: AppWindows.Layout.buttonMinWidth).isActive = true

        let buttonsRow = NSStackView(views: [pauseButton, backgroundButton, NSView(), cancelButton])
        buttonsRow.spacing = AppWindows.Layout.controlSpacing
        buttonsRow.alignment = NSLayoutConstraint.Attribute.centerY

        let m = AppWindows.Layout.margin
        let stack = NSStackView(views: [
            statusLabel,
            fromLabel,
            toLabel,
            fileRow,
            totalRow,
            statsRow,
            buttonsRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: statusLabel)
        stack.setCustomSpacing(8, after: toLabel)
        stack.setCustomSpacing(6, after: fileRow)
        stack.setCustomSpacing(4, after: totalRow)
        stack.setCustomSpacing(AppWindows.Layout.sectionSpacing, after: statsRow)
        stack.edgeInsets = NSEdgeInsets(top: m, left: m, bottom: m, right: m)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            fromLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            toLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            fileRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            totalRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            statsRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
            buttonsRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -m * 2),
        ])
        return root
    }

    public func update() {
        guard let window = window, window.isVisible, !isPreparing, let job = job else { return }
        let verb = job.isMove ? "Move" : "Copy"
        let speedStr = Self.formatSpeed(job.speed)
        let remainingBytes = max(0, job.bytesTotal - job.bytesProcessed)
        let timeStr = Self.formatETA(remainingBytes: remainingBytes, speed: job.speed)
        statusLabel.stringValue = timeStr.isEmpty ? "\(verb): \(speedStr)" : "\(verb): \(speedStr), \(timeStr)"

        if let idx = job.active.first, job.items.indices.contains(idx) {
            let item = job.items[idx]
            fromLabel.stringValue = "From: " + item.source.displayPath
            toLabel.stringValue = "To: " + item.destination.displayPath
            let fDone = job.partial[idx] ?? 0
            let fPct = item.size > 0 ? min(100, Int((Double(fDone) / Double(item.size)) * 100)) : 0
            fileProgress.doubleValue = Double(fPct)
            filePercentLabel.stringValue = "\(fPct) %"
        } else {
            fromLabel.stringValue = "From: …"
            toLabel.stringValue = "To: …"
            fileProgress.doubleValue = 0
            filePercentLabel.stringValue = "0 %"
        }

        let tDone = job.bytesProcessed
        let tTotal = job.bytesTotal
        let tPct = tTotal > 0 ? min(100, Int((Double(tDone) / Double(tTotal)) * 100)) : (job.processedCount == job.items.count ? 100 : 0)
        totalProgress.doubleValue = Double(tPct)
        totalPercentLabel.stringValue = "\(tPct) %"

        filesCountLabel.stringValue = job.skippedCount > 0
            ? "\(job.processedCount) / \(job.items.count)  (\(job.skippedCount) skipped)"
            : "\(job.processedCount) / \(job.items.count)"
        bytesCountLabel.stringValue = "\(EntryFormatter.shared.size(tDone, as: .readable)) / \(EntryFormatter.shared.size(tTotal, as: .readable))"

        pauseButton.title = job.isPaused ? "Resume" : "Pause"
    }

    static func formatSpeed(_ speed: Double) -> String {
        if speed > 1_048_576 { return String(format: "%.1f MB/s", speed / 1_048_576) }
        if speed > 1024 { return String(format: "%.0f kbytes/s", speed / 1024) }
        return "0 kbytes/s"
    }

    static func formatETA(remainingBytes: Int64, speed: Double) -> String {
        guard speed > 1024 && remainingBytes > 0 else { return "" }
        let secs = Int(Double(remainingBytes) / speed)
        if secs < 60 { return "\(secs) s" }
        if secs < 3600 { return "\(secs / 60) m" }
        return "\(secs / 3600) h \((secs % 3600) / 60) m"
    }

    @objc private func pausePressed() {
        guard let job = job else { return }
        job.isPaused.toggle()
        pauseButton.title = job.isPaused ? "Resume" : "Pause"
    }

    @objc private func cancelPressed() {
        cancelFlag?.cancel()
        job?.cancel()
        onCancel?()
        close()
    }

    @objc private func backgroundPressed() {
        close()
        onBackground()
    }
}
