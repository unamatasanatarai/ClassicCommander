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
            try expect(dialog.verifyBox.nextKeyView === dialog.queueButton, "verify -> queue")
            try expect(dialog.queueButton.nextKeyView === dialog.cancelButton, "queue -> cancel")
            try expect(dialog.cancelButton.nextKeyView === dialog.okButton, "cancel -> ok")
            try expect(dialog.okButton.nextKeyView === dialog.targetField, "ok -> target")
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

        testRunner("Local copy (copyfile): progress, clone, metadata, links, atomic replace, cancel") {
            let fm = FileManager.default
            let dir = try CoverageTests.tempDir("LocalCopyTest")
            defer { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/chflags"), arguments: ["-R", "nouchg", dir.path]).waitUntilExit()
                    try? fm.removeItem(at: dir) }
            let src = dir.appendingPathComponent("large.bin")
            let testSize = 9 * 1024 * 1024
            try Data(repeating: 0x42, count: testSize).write(to: src)
            let modified = Date(timeIntervalSince1970: 1_000_000_000)
            try fm.setAttributes([.modificationDate: modified, .posixPermissions: 0o640], ofItemAtPath: src.path)
            try expect(setxattr(src.path, "com.example.tag", "blue", 4, 0, 0) == 0, "xattr set on source")
            func xattr(_ url: URL) -> String? {
                var buf = [CChar](repeating: 0, count: 16)
                let n = getxattr(url.path, "com.example.tag", &buf, 16, 0, XATTR_NOFOLLOW)
                return n < 0 ? nil : String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            func leftovers() throws -> [String] { try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".cc-copy-") } }

            // Data copied (no clone): progress in steps, pause is asked, metadata kept.
            let dst = dir.appendingPathComponent("large_copy.bin")
            var progressCalls: [Int64] = []
            var pauseAsked = 0
            try LocalCopy.copy(from: src, to: dst, clone: false, cancel: nil, isPaused: { pauseAsked += 1; return false }) {
                progressCalls.append($0)
            }
            try expect(progressCalls.count >= 2 && pauseAsked > 0, "progress in steps: \(progressCalls), pause asked \(pauseAsked)")
            try expect(progressCalls.last == Int64(testSize), "final progress equals the size")
            try expect(fm.contentsEqual(atPath: src.path, andPath: dst.path), "same data")
            let attrs = try fm.attributesOfItem(atPath: dst.path)
            try expect(attrs[.modificationDate] as? Date == modified, "date kept")
            try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o640, "permissions kept")
            try expect(xattr(dst) == "blue", "extended attribute kept")

            // Default: a clone (APFS) — one progress report, same result; the default isPaused is used.
            let cloned = dir.appendingPathComponent("cloned.bin")
            var cloneCalls: [Int64] = []
            try LocalCopy.copy(from: src, to: cloned, cancel: nil) { cloneCalls.append($0) }
            try expect(cloneCalls == [Int64(testSize)], "clone reports once: \(cloneCalls)")
            try expect(fm.contentsEqual(atPath: src.path, andPath: cloned.path) && xattr(cloned) == "blue", "clone identical")
            let noClone = try LocalCopy.copy(from: src, to: dir.appendingPathComponent("plain.bin"), clone: false, cancel: nil, progress: nil)
            try expect(noClone == Int64(testSize), "returns the size")
            try expect(LocalCopy.flags(clone: true) & copyfile_flags_t(COPYFILE_CLONE) != 0
                       && LocalCopy.flags(clone: false) & copyfile_flags_t(COPYFILE_CLONE) == 0, "clone flag")

            // Replacing an existing file: the target is never removed first (same inode replaced by rename).
            let small = dir.appendingPathComponent("small.txt")
            try Data("new".utf8).write(to: small)
            try Data("old contents".utf8).write(to: dst)
            try LocalCopy.copy(from: small, to: dst, clone: false, cancel: nil, progress: nil)
            try expect(try String(contentsOf: dst, encoding: .utf8) == "new", "replaced")

            // A folder in the way of a file is replaced too.
            let folderInWay = dir.appendingPathComponent("inway")
            try fm.createDirectory(at: folderInWay.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try LocalCopy.copy(from: small, to: folderInWay, cancel: nil, progress: nil)
            var isDir: ObjCBool = true
            try expect(fm.fileExists(atPath: folderInWay.path, isDirectory: &isDir) && !isDir.boolValue, "folder replaced by the file")

            // A symbolic link (even a dangling one) is copied as a link; verify compares where it points.
            let link = dir.appendingPathComponent("link")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../nowhere")
            let linkCopy = dir.appendingPathComponent("sub/link")
            try LocalCopy.copy(from: link, to: linkCopy, cancel: nil, progress: nil)
            try expect(try fm.destinationOfSymbolicLink(atPath: linkCopy.path) == "../nowhere", "link copied as a link")
            let linkItem = TransferItem(source: .local(link), destination: .local(linkCopy), size: 10, isFolder: false)
            try TransferManager().verify(linkItem, at: .local(linkCopy))
            try fm.removeItem(at: linkCopy)
            try fm.createSymbolicLink(atPath: linkCopy.path, withDestinationPath: "elsewhere")
            var verifyFailed = false
            do { try TransferManager().verify(linkItem, at: .local(linkCopy)) } catch { verifyFailed = true }
            try expect(verifyFailed, "a link pointing elsewhere fails verify")

            // A locked file is copied locked (the lock is lifted only for the rename).
            let locked = dir.appendingPathComponent("locked.txt")
            try Data("keep".utf8).write(to: locked)
            try fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
            let lockedCopy = dir.appendingPathComponent("locked_copy.txt")
            try LocalCopy.copy(from: locked, to: lockedCopy, cancel: nil, progress: nil)
            try expect((try fm.attributesOfItem(atPath: lockedCopy.path))[.immutable] as? Bool == true, "copy is locked too")
            try expect(try String(contentsOf: lockedCopy, encoding: .utf8) == "keep", "locked copy has the data")

            // Cancelled before starting, and while copying: nothing is left behind, an old target stays.
            let cancelDst = dir.appendingPathComponent("cancelled.bin")
            let cancelFlag = CancelFlag()
            cancelFlag.cancel()
            var threw = false
            do { try LocalCopy.copy(from: src, to: cancelDst, cancel: cancelFlag, progress: nil) } catch FTPError.cancelled { threw = true }
            try expect(threw && !fm.fileExists(atPath: cancelDst.path), "cancelled up front")
            try Data("old".utf8).write(to: cancelDst)
            let midway = CancelFlag()
            threw = false
            do {
                try LocalCopy.copy(from: src, to: cancelDst, clone: false, cancel: midway) { if $0 > 0 { midway.cancel() } }
            } catch FTPError.cancelled { threw = true }
            try expect(threw, "cancelled while copying")
            try expect(try String(contentsOf: cancelDst, encoding: .utf8) == "old", "old target untouched")

            // Errors: a missing source, a rename into a folder that is not there.
            threw = false
            do { try LocalCopy.copy(from: dir.appendingPathComponent("missing"), to: cancelDst, cancel: nil, progress: nil) }
            catch let e as NSError { threw = e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT) }
            try expect(threw, "missing source is an error")
            threw = false
            do { try LocalCopy.replace(dir.appendingPathComponent("no/such/dir/x"), with: small) }
            catch let e as NSError { threw = e.code == Int(ENOENT) }
            try expect(threw, "rename into a missing folder is an error")
            try expect(try leftovers().isEmpty, "no temporary files left: \(try leftovers())")
        }

        testRunner("Symbolic links are copied and moved as links: selected, nested, cyclic, dangling, counted") {
            defer { CoverageTests.resetAnswers() }
            let fm = FileManager.default
            let left = try CoverageTests.tempDir("LinkLeft"), right = try CoverageTests.tempDir("LinkRight")
            defer { try? fm.removeItem(at: left); try? fm.removeItem(at: right) }
            func target(_ url: URL) -> String? { try? fm.destinationOfSymbolicLink(atPath: url.path) }
            func isLink(_ url: URL) -> Bool { target(url) != nil }

            // Selected in a panel: a link to a folder is copied as the link, not as a copy of the folder.
            try fm.createDirectory(at: left.appendingPathComponent("real/inner"), withIntermediateDirectories: true)
            try Data("data".utf8).write(to: left.appendingPathComponent("real/inner/f.txt"))
            try fm.createSymbolicLink(atPath: left.appendingPathComponent("dirlink").path, withDestinationPath: "real")
            try fm.createSymbolicLink(atPath: left.appendingPathComponent("dangling").path, withDestinationPath: "nowhere")
            try fm.createSymbolicLink(atPath: left.appendingPathComponent("filelink").path, withDestinationPath: "real/inner/f.txt")
            let (view, prompts, window) = SelectTests.commander(left, right)
            defer { window.close() }
            view.fileCommands.runInBackground = false
            view.leftView.model.markAll(true)
            view.perform(.copy)
            try expect(prompts.lastMessage.hasPrefix("Copy"), "the copy was asked")
            try expect(target(right.appendingPathComponent("dirlink")) == "real", "link to a folder copied as a link")
            try expect(target(right.appendingPathComponent("dangling")) == "nowhere", "dangling link copied as a link")
            try expect(target(right.appendingPathComponent("filelink")) == "real/inner/f.txt", "link to a file copied as a link")
            try expect(fm.fileExists(atPath: right.appendingPathComponent("real/inner/f.txt").path), "the real folder is copied too")

            // Nested in a folder: links are items of their own and are never entered (a cycle ends too).
            let tree = left.appendingPathComponent("tree")
            try fm.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: tree.appendingPathComponent("sub/x.txt"))
            try fm.createSymbolicLink(atPath: tree.appendingPathComponent("loop").path, withDestinationPath: ".")
            try fm.createSymbolicLink(atPath: tree.appendingPathComponent("up").path, withDestinationPath: "../real")
            let dest = right.appendingPathComponent("tree_copy")
            let plan = try TransferPlanner.plan([.init(location: .local(tree), isFolder: true, size: 0)], into: .local(dest.deletingLastPathComponent()))
            try expect(plan.items.filter { !$0.isFolder }.count == 3, "x.txt and two links: \(plan.items.map(\.source.displayPath))")
            try expect(plan.items.filter { $0.source.name == "loop" || $0.source.name == "up" }.allSatisfy { !$0.isFolder && $0.size == 0 },
                       "links are items without data")
            let manager = TransferManager()
            manager.runSynchronously = true
            let job = TransferJob(title: "tree", items: plan.items, isMove: false)
            job.verify = true
            manager.enqueue(job)
            let copied = right.appendingPathComponent("tree")
            try expect(job.state == .finished && job.failedCount == 0, "tree copied and verified: \(job.statusText)")
            try expect(target(copied.appendingPathComponent("loop")) == "." && target(copied.appendingPathComponent("up")) == "../real", "links kept")
            try expect(fm.fileExists(atPath: copied.appendingPathComponent("sub/x.txt").path), "file copied")

            // A move that has to copy (Verify) deletes the link only; what it pointed to is untouched.
            let moveSrc = left.appendingPathComponent("dirlink")
            let movePlan = try TransferPlanner.plan([.init(location: .local(moveSrc), isFolder: false, size: 0)],
                                                    into: .local(right.appendingPathComponent("moved")), move: true)
            let move = TransferJob(title: "move", items: movePlan.items, isMove: true)
            move.verify = true
            manager.enqueue(move)
            try expect(move.state == .finished && move.failedCount == 0, "link moved: \(move.statusText)")
            try expect(!isLink(moveSrc), "source link gone")
            try expect(fm.fileExists(atPath: left.appendingPathComponent("real/inner/f.txt").path), "the target of the link is untouched")
            try expect(target(right.appendingPathComponent("moved/dirlink")) == "real", "moved as a link")

            // The Copy dialog counts a link as one file without data, whatever it points to.
            let entries = [
                FileEntry(name: "dirlink", url: left.appendingPathComponent("dirlink"), kind: .directory, size: nil, isSymlink: true),
                FileEntry(name: "filelink", url: left.appendingPathComponent("filelink"), kind: .file, size: 999, isSymlink: true),
            ]
            let stats = TransferStats.count(entries, mask: nil, cancel: CancelFlag())
            try expect(stats.files == 2 && stats.folders == 0 && stats.bytes == 0, "links counted as files: \(stats)")
            let nested = TransferStats.count([FileEntry(name: "tree", url: tree, kind: .directory)], mask: nil, cancel: CancelFlag())
            try expect(nested.files == 3 && nested.folders == 2 && nested.bytes == 1, "nested links are not entered: \(nested)")
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
            manager.cloneLocalCopies = false   // copy the data, so pausing really happens mid-copy
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
