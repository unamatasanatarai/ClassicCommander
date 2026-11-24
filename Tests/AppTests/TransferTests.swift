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
    }
}
