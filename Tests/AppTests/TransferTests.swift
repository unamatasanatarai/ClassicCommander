import Cocoa

/// The Copy / Move dialog, "target file exists", the queue (OK vs Queue), and conflicts on a server.
enum TransferTests {
    typealias Fail = CommanderTests.TestFailure
    static func expect(_ c: @autoclosure () throws -> Bool, _ m: String) throws {
        if try !c() { throw Fail(description: m) }
    }

    static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("Copy dialog: target, files of type with live stats, Verify, OK / Queue / Cancel, histories") {
            defer { CoverageTests.resetAnswers() }
            let dir = try CoverageTests.tempDir("CopyDialog")
            defer { try? FileManager.default.removeItem(at: dir) }
            for name in ["a.jpg", "b.txt"] { try Data(repeating: 1, count: 1024).write(to: dir.appendingPathComponent(name)) }
            let suite = "CopyDialog-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let entries = PanelModel(directory: dir).entries.filter { $0.kind != .parent }
            let question = FileCommands.question(verb: "Copy", items: entries, target: "/tmp/")
            try expect(question.message == "Copy 2 files to:", question.message)

            let dialog = TransferDialogController(question: question, sizeFormat: .readable, defaults: defaults)
            try expect(dialog.window?.title == AppWindows.title("Copy") && dialog.targetField.stringValue == "/tmp/", "target preset")
            CoverageTests.wait(5) { dialog.stats != nil }
            try expect(dialog.stats?.files == 2 && dialog.statsLabel.stringValue == "2,0 KB · 2 files", "stats: \(dialog.statsLabel.stringValue)")
            dialog.maskField.stringValue = "*.jpg"
            dialog.maskChanged()
            CoverageTests.wait(5) { dialog.stats?.files == 1 }
            try expect(dialog.statsLabel.stringValue == "1,0 KB · 1 file", "masked: \(dialog.statsLabel.stringValue)")
            dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            dialog.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification))
            dialog.show(TransferStats(files: 1, folders: 2, bytes: 5, complete: false))
            try expect(dialog.statsLabel.stringValue == "5 B · 1 file · 2 folders (server folders not counted)", dialog.statsLabel.stringValue)
            dialog.okPressed(); dialog.queuePressed(); dialog.cancelPressed()   // no modal session: nothing happens

            Modal.answerWindow = { window in
                dialog.verifyBox.state = .on
                return TransferDialogController.queue
            }
            let answer = dialog.run()
            try expect(answer == TransferAnswer(target: "/tmp/", mask: "*.jpg", verify: true, queue: true), "answer: \(String(describing: answer))")
            try expect(defaults.stringArray(forKey: "copy.targetHistory") == ["/tmp/"] && defaults.stringArray(forKey: "copy.maskHistory") == ["*.jpg"]
                       && defaults.bool(forKey: "copy.verify"), "remembered")
            Modal.answerWindow = { _ in .OK }
            let again = TransferDialogController(question: question, sizeFormat: .bytes, defaults: defaults)
            try expect(again.verifyBox.state == .on, "Verify remembered")
            try expect(again.run()?.queue == false, "OK starts now")
            again.targetField.stringValue = "  "
            try expect(again.run() == nil, "no target: nothing")
            Modal.answerWindow = { _ in .cancel }
            try expect(again.run() == nil, "cancelled")

            // The real prompts use these dialogs.
            let prompts = AlertPrompts()
            Modal.answerWindow = { _ in .OK }
            try expect(prompts.askTransfer(question)?.target == "/tmp/", "AlertPrompts asks with the dialog")

            // Tab navigation key view loop
            try expect(dialog.targetField.nextKeyView === dialog.maskField, "target -> mask")
            try expect(dialog.maskField.nextKeyView === dialog.verifyBox, "mask -> verify")
            try expect(dialog.verifyBox.nextKeyView === dialog.okButton, "verify -> ok")
            try expect(dialog.okButton.nextKeyView === dialog.queueButton, "ok -> queue")
            try expect(dialog.queueButton.nextKeyView === dialog.cancelButton, "queue -> cancel")
            try expect(dialog.cancelButton.nextKeyView === dialog.targetField, "cancel -> target")
        }

        testRunner("Target file exists: both sides shown, every button, Rename asks for the name") {
            defer { CoverageTests.resetAnswers() }
            let date = Date(timeIntervalSince1970: 1_432_327_138)
            let conflict = TransferConflict(source: .local(URL(fileURLWithPath: "/from/photo.jpg")), target: .local(URL(fileURLWithPath: "/to/photo.jpg")),
                                            sourceSize: 2_042_908, sourceDate: date, targetSize: 1024, targetDate: nil)
            let dialog = ConflictDialogController(conflict: conflict, sizeFormat: .readable)
            try expect(dialog.window?.title == AppWindows.title("Target file exists"), "title")
            let labels = CommanderTests.allViews(NSTextField.self, in: dialog.window!.contentView!).map(\.stringValue)
            try expect(labels.contains("/to/photo.jpg") && labels.contains("/from/photo.jpg")
                       && labels.contains("1,0 KB, date unknown") && labels.contains { $0.hasPrefix("1,9 MB, ") }, "both sides: \(labels)")
            try expect(dialog.buttons.map(\.title) == ["Replace", "Replace All", "Skip", "Skip All", "Replace All Older", "Rename…", "Cancel"], "buttons")
            dialog.pressed(dialog.buttons[0])   // no modal session: nothing happens
            for (i, expected) in [ConflictDecision.replace, .replaceAll, .skip, .skipAll, .replaceAllOlder, .cancel].enumerated() {
                let code = i == 5 ? 1006 : 1000 + i
                Modal.answerWindow = { _ in NSApplication.ModalResponse(rawValue: code) }
                try expect(dialog.run(askName: { _ in nil }) == expected, "button \(code)")
            }
            var asked: [String] = []
            Modal.answerWindow = { _ in NSApplication.ModalResponse(rawValue: ConflictDialogController.renameCode) }
            var first = true
            let renamed = dialog.run { suggested in
                asked.append(suggested)
                defer { first = false }
                return first ? nil : "photo-new.jpg"   // cancelled once: asked again
            }
            try expect(renamed == .rename("photo-new.jpg") && asked == ["photo (2).jpg", "photo (2).jpg"], "rename: \(asked)")
            Modal.answerWindow = { _ in NSApplication.ModalResponse(rawValue: 5) }
            try expect(dialog.run(askName: { _ in nil }) == .cancel, "unknown button: cancel")
            try expect(ConflictDialogController.suggestedName(for: "README") == "README (2)", "no extension")
            try expect(ConflictDialogController.describe(nil, nil, format: .bytes) == "size unknown, date unknown", "unknowns")

            // The real prompts: Rename asks with a text field.
            let prompts = AlertPrompts()
            Modal.answerWindow = { _ in NSApplication.ModalResponse(rawValue: ConflictDialogController.renameCode) }
            CoverageTests.answer(.alertFirstButtonReturn, text: "other.jpg")
            Modal.answerWindow = { _ in NSApplication.ModalResponse(rawValue: ConflictDialogController.renameCode) }
            try expect(prompts.resolveConflict(conflict) == .rename("other.jpg"), "AlertPrompts renames")
        }

        testRunner("Queue: OK starts at once, Queue waits for the queued job before it; cancel a waiting job") {
            let dir = try CoverageTests.tempDir("QueueOrder")
            defer { try? FileManager.default.removeItem(at: dir) }
            let src = dir.appendingPathComponent("src.bin")
            try Data(repeating: 7, count: 4096).write(to: src)
            func job(_ name: String, queue: Bool) -> TransferJob {
                let j = TransferJob(title: name, items: [TransferItem(source: .local(src), destination: .local(dir.appendingPathComponent(name)),
                                                                     size: 4096, isFolder: false)], isMove: false)
                j.waitsInQueue = queue
                return j
            }
            let manager = TransferManager()
            var order: [String] = []
            manager.onChange = { j in if j.state == .finished && !order.contains(j.title) { order.append(j.title) } }
            let first = job("q1", queue: true), second = job("q2", queue: true), third = job("q3", queue: true)
            manager.enqueue(first)
            manager.enqueue(second)
            manager.enqueue(third)
            try expect(second.statusText == "Waiting in the queue" || second.statusText.hasPrefix("Done"), second.statusText)
            manager.cancel(third)
            CoverageTests.wait(2) { third.state == .cancelled }
            try expect(third.state == .cancelled, "a waiting job is taken off the queue")
            CoverageTests.wait(10) { order.count == 2 }
            try expect(order == ["q1", "q2"], "one after another: \(order)")
            let now = job("now", queue: false)
            manager.enqueue(now)
            CoverageTests.wait(10) { now.state == .finished }
            try expect(now.doneCount == 1, "OK starts at once")
            manager.removeCompleted()
            try expect(manager.jobs.map(\.title) == ["q3"], "completed jobs removed, the cancelled one kept: \(manager.jobs.map(\.title))")
            // Queued jobs in synchronous mode (tests) run as soon as the one before finishes.
            let sync = TransferManager()
            sync.runSynchronously = true
            let s1 = job("s1", queue: true), s2 = job("s2", queue: true)
            sync.enqueue(s1)
            sync.enqueue(s2)
            try expect(s1.state == .finished && s2.state == .finished, "both ran")
            try expect(TransferLocation.local(src).sibling(named: "x").name == "x", "sibling")
        }

        testRunner("Copy in the commander: queue window after a moment, problems shown, marks cleared, mask, create folder") {
            defer { CoverageTests.resetAnswers() }
            let left = try CoverageTests.tempDir("QLeft"), right = try CoverageTests.tempDir("QRight")
            defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
            for name in ["a.txt", "b.jpg"] { try Data(name.utf8).write(to: left.appendingPathComponent(name)) }
            let (view, prompts, window) = SelectTests.commander(left, right)
            defer { window.close() }
            let panel = view.leftView
            panel.model.markAll(true)
            view.perform(.copy)
            try expect(prompts.lastMessage == "Copy 2 files to:" && FileManager.default.fileExists(atPath: right.appendingPathComponent("b.jpg").path), "copied")
            try expect(panel.model.marked.isEmpty, "marks cleared (Restore brings them back)")

            // Several files into a folder that doesn't exist yet: it is created.
            panel.model.markAll(true)
            prompts.answer = right.appendingPathComponent("new/").path
            view.perform(.copy)
            try expect(FileManager.default.fileExists(atPath: right.appendingPathComponent("new/a.txt").path), "folder created")

            // Copying a file onto itself is reported, not done.
            panel.model.focus(name: "a.txt", visibleRows: 20)
            prompts.answer = left.path
            view.perform(.copy)
            try expect(prompts.problems.contains { $0.contains("same") }, "onto itself: \(prompts.problems)")

            // A mask nothing matches.
            final class MaskPrompts: FileCommandPrompts {
                func askText(title: String, message: String, defaultValue: String, okTitle: String) -> String? { defaultValue }
                func askTransfer(_ q: TransferQuestion) -> TransferAnswer? { TransferAnswer(target: q.defaultTarget, mask: "*.zip") }
                func confirm(title: String, message: String, okTitle: String) -> Bool { true }
                func resolveConflict(_ c: TransferConflict) -> ConflictDecision { .skip }
                func showProblems(title: String, report: OperationReport) {}
            }
            view.fileCommands.prompts = MaskPrompts()
            view.perform(.copy)

            // In the background: the queue window opens when the job takes a while.
            view.fileCommands.prompts = prompts
            view.fileCommands.runInBackground = true
            FTPController.queueWindowDelay = 0
            defer { FTPController.queueWindowDelay = 0.7 }
            panel.model.focus(name: "b.jpg", visibleRows: 20)
            prompts.answer = right.appendingPathComponent("bg").path + "/"
            view.perform(.copy)
            CoverageTests.wait(10) { FileManager.default.fileExists(atPath: right.appendingPathComponent("bg/b.jpg").path) }
            try expect(FileManager.default.fileExists(atPath: right.appendingPathComponent("bg/b.jpg").path), "copied in the background")
            CoverageTests.wait(1) { false }
            let running = TransferJob(title: "r", items: [], isMove: false)
            view.ftp.showQueueIfRunning(running)
            try expect(view.ftp.transfersWindow.window?.isVisible == true, "queue shown for a job still running")
            view.ftp.transfersWindow.close()
            let queued = TransferJob(title: "w", items: [], isMove: false)
            queued.waitsInQueue = true
            view.ftp.startJob(queued)
            CoverageTests.wait(5) { queued.state == .finished }
            try expect(view.ftp.transfersWindow.window?.isVisible == true, "Queue (⌃2) shows the queue window")
            view.ftp.transfersWindow.close()

            // A failed planning step is reported.
            panel.model.focus(name: "a.txt", visibleRows: 20)
            view.fileCommands.runInBackground = false
            try FileManager.default.removeItem(at: left.appendingPathComponent("a.txt"))
            prompts.answer = right.appendingPathComponent("fresh").path + "/"
            view.perform(.copy)
            try expect(view.ftp.transfers.jobs.last?.failedCount == 1, "a vanished file fails in the queue")
        }

        testRunner("Chunked local copy: progress reporting, cancellation, and cleanup") {
            let dir = try CoverageTests.tempDir("ChunkedTest")
            defer { try? FileManager.default.removeItem(at: dir) }
            let src = dir.appendingPathComponent("large.bin")
            let dst = dir.appendingPathComponent("large_copy.bin")

            // 9MB test file to test multiple 4MB chunks
            let testSize = 9 * 1024 * 1024
            let testData = Data(repeating: 0x42, count: testSize)
            try testData.write(to: src)

            var progressCalls: [Int64] = []
            try TransferManager.copyLocalChunked(from: src, to: dst, cancel: nil, job: nil) { bytes in
                progressCalls.append(bytes)
            }
            try expect(progressCalls.count >= 2, "Progress was called multiple times: \(progressCalls)")
            try expect(progressCalls.last == Int64(testSize), "Final progress equals testSize")
            try expect(FileManager.default.fileExists(atPath: dst.path), "Target exists")
            try expect((try? FileComparison.fileSize(dst)) == Int64(testSize), "Target size matches")

            // Test cancellation
            let cancelDst = dir.appendingPathComponent("cancelled.bin")
            let cancelFlag = CancelFlag()
            cancelFlag.cancel()
            var threw = false
            do {
                try TransferManager.copyLocalChunked(from: src, to: cancelDst, cancel: cancelFlag, job: nil, progress: nil)
            } catch {
                threw = true
            }
            try expect(threw, "Cancellation threw error")
            try expect(!FileManager.default.fileExists(atPath: cancelDst.path), "Cancelled file was cleaned up")
        }

        testRunner("Skipped files: progress tracking, skippedBytes, and statusText") {
            let item1 = TransferItem(source: .local(URL(fileURLWithPath: "/src/f1.txt")),
                                     destination: .local(URL(fileURLWithPath: "/dst/f1.txt")),
                                     size: 5000, isFolder: false)
            let item2 = TransferItem(source: .local(URL(fileURLWithPath: "/src/f2.txt")),
                                     destination: .local(URL(fileURLWithPath: "/dst/f2.txt")),
                                     size: 8000, isFolder: false)
            let job = TransferJob(title: "Test", items: [item1, item2], isMove: false)
            try expect(job.bytesTotal == 13000, "total bytes")
            try expect(job.bytesProcessed == 0 && job.processedCount == 0, "initial processed")

            // Simulate file 1 being skipped
            job.results[0] = .skipped("the target exists")
            job.skippedBytes = 5000
            try expect(job.skippedCount == 1, "skipped count is 1")
            try expect(job.processedCount == 1, "processed count is 1")
            try expect(job.bytesProcessed == 5000, "bytesProcessed includes skipped bytes")

            // Simulate file 2 being copied
            job.results[1] = .done
            job.completedBytes = 8000
            try expect(job.doneCount == 1, "done count is 1")
            try expect(job.processedCount == 2, "processed count is 2")
            try expect(job.bytesProcessed == 13000, "bytesProcessed is total")
            job.state = .finished
            try expect(job.statusText.contains("1 skipped") && job.statusText.hasPrefix("Done"), "statusText reflects skipped: \(job.statusText)")
        }

        testRunner("Large copy in the background while the windows read its progress: no crash, all copied") {
            // The app died copying large files: the progress windows read the job's live state
            // (active files, bytes per file, results) on the main thread while copy threads changed it.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BigCopy-\(UUID().uuidString)")
            let src = dir.appendingPathComponent("src"), dst = dir.appendingPathComponent("dst")
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            let chunk = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            var items: [TransferItem] = []
            for i in 0..<4 {
                let url = src.appendingPathComponent("video\(i).mp4")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let h = try FileHandle(forWritingTo: url)
                for _ in 0..<12 { h.write(chunk) }
                try h.close()
                items.append(TransferItem(source: .local(url), destination: .local(dst.appendingPathComponent(url.lastPathComponent)),
                                          size: Int64(12 * chunk.count), isFolder: false))
            }
            let manager = TransferManager()
            manager.limits = TransferLimits(total: 4, locals: 4)   // several copy threads at once
            let job = TransferJob(title: "Big", items: items, isMove: false)
            var notified = 0
            manager.onChange = { _ in notified += 1 }
            manager.enqueue(job, synchronously: false)
            var reads = 0
            let deadline = Date().addingTimeInterval(60)
            while TransferManager.isUnfinished(job) && Date() < deadline {
                // What the progress and queue windows read, as fast as possible.
                _ = job.active.first.map { job.partial[$0] }
                _ = (job.bytesDone, job.bytesProcessed, job.processedCount, job.statusText, job.speed)
                for i in items.indices { _ = TransfersWindowController.status(of: job, at: i) }
                if reads % 500 == 0 { job.isPaused.toggle() }
                reads += 1
                RunLoop.main.run(until: Date().addingTimeInterval(0.0005))
            }
            job.isPaused = false
            CoverageTests.wait(30) { !TransferManager.isUnfinished(job) }
            try expect(job.state == .finished && job.doneCount == 4, "all copied: \(job.statusText)")
            try expect(job.bytesDone == job.bytesTotal && reads > 0 && notified > 0, "progress complete: \(job.bytesDone) of \(job.bytesTotal)")
            for item in items {
                guard case .local(let s) = item.source, case .local(let d) = item.destination else { continue }
                try expect(FileManager.default.contentsEqual(atPath: s.path, andPath: d.path), "\(d.lastPathComponent) identical")
            }

            // Cancelled with files still waiting for a copy slot: they are dropped and the job ends cancelled.
            manager.limits = TransferLimits(total: 1, locals: 1)
            let cancelled = TransferJob(title: "Big again", items: items, isMove: false)
            manager.enqueue(cancelled, synchronously: false)
            manager.cancel(cancelled)
            CoverageTests.wait(30) { !TransferManager.isUnfinished(cancelled) }
            try expect(cancelled.state == .cancelled && cancelled.active.isEmpty && cancelled.running == 0,
                       "cancelled cleanly: \(cancelled.statusText)")
        }

        testRunner("Queue cancellation: active and waiting items transition cleanly") {
            let manager = TransferManager()
            let item1 = TransferItem(source: .local(URL(fileURLWithPath: "/src/f1.txt")),
                                     destination: .local(URL(fileURLWithPath: "/dst/f1.txt")),
                                     size: 5000, isFolder: false)
            let item2 = TransferItem(source: .local(URL(fileURLWithPath: "/src/f2.txt")),
                                     destination: .local(URL(fileURLWithPath: "/dst/f2.txt")),
                                     size: 8000, isFolder: false)
            let job = TransferJob(title: "CancelTest", items: [item1, item2], isMove: false)
            job.state = .running
            job.running = 1
            job.active.insert(0)
            try expect(TransfersWindowController.status(of: job, at: 0).0.contains("Copying"), "active copying")
            try expect(TransfersWindowController.status(of: job, at: 1).0 == "Pending", "pending item")

            // User clicks Cancel while running
            job.cancel()
            try expect(job.cancelFlag.isCancelled, "flag cancelled")
            try expect(job.statusText == "Cancelling…", "job status shows Cancelling… while workers active")
            try expect(TransfersWindowController.status(of: job, at: 0).0 == "Cancelling…", "active file status shows Cancelling…")
            try expect(TransfersWindowController.status(of: job, at: 1).0 == "Not done", "waiting file status shows Not done")

            // Worker finishes cancelling
            job.running = 0
            job.active.remove(0)
            manager.cancel(job)
            try expect(job.state == .cancelled, "job finished cancelling")
            try expect(job.statusText.hasPrefix("Cancelled"), "job status shows Cancelled when done")
        }

        testRunner("Local transfer concurrency: local-to-local runs strictly sequential (concurrency 1) by default") {
            let limits = TransferLimits(total: 4, uploads: 0, downloads: 0)
            try expect(limits.effectiveLocals == 1, "default local concurrency is 1")
            try expect(TransferLimits(total: 4, locals: 2).effectiveLocals == 2, "explicit locals respected")

            let dir = try CoverageTests.tempDir("LocalConcurrency")
            defer { try? FileManager.default.removeItem(at: dir) }
            let srcDir = dir.appendingPathComponent("src")
            let dstDir = dir.appendingPathComponent("dst")
            try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

            var items: [TransferItem] = []
            for i in 0..<4 {
                let file = srcDir.appendingPathComponent("file\(i).bin")
                try Data(repeating: UInt8(i + 1), count: 64 * 1024).write(to: file)
                let dst = dstDir.appendingPathComponent("file\(i).bin")
                items.append(TransferItem(source: .local(file), destination: .local(dst), size: 64 * 1024, isFolder: false))
            }

            let manager = TransferManager()
            manager.limits = TransferLimits(total: 4, uploads: 0, downloads: 0, locals: 1)
            let job = TransferJob(title: "Copy 4 local files", items: items, isMove: false)
            manager.enqueue(job)

            CoverageTests.wait(10) { job.state == .finished }
            try expect(job.state == .finished && job.failedCount == 0, "job finished successfully: \(job.statusText)")
            try expect(job.doneCount == 4, "all 4 items done")
            try expect(manager.peakLocals == 1, "local files transferred sequentially (peakLocals = \(manager.peakLocals))")
            try expect(manager.peakConcurrency == 1, "peakConcurrency was 1: \(manager.peakConcurrency)")
            for i in 0..<4 {
                let dst = dstDir.appendingPathComponent("file\(i).bin")
                try expect(FileManager.default.fileExists(atPath: dst.path), "destination file\(i) exists")
            }
        }
    }
}
