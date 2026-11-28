import Foundation

public enum ZipArchiveTests {
    typealias Fail = CommanderTests.TestFailure

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Fail(description: message) }
    }

    static func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("ZipArchive: split paths") {
            let root = try tempDir("ZipArchiveSplit")
            defer { try? FileManager.default.removeItem(at: root) }

            let nonZip = root.appendingPathComponent("file.txt")
            try "hi".write(to: nonZip, atomically: true, encoding: .utf8)
            try expect(ZipArchive.split(nonZip) == nil, "Non-zip path should return nil")

            let missingZip = root.appendingPathComponent("missing.zip")
            try expect(ZipArchive.split(missingZip) == nil, "Missing zip on disk should return nil")

            let realZip = root.appendingPathComponent("ARCHIVE.ZIP")
            try Data().write(to: realZip)
            let splitRoot = ZipArchive.split(realZip)
            try expect(splitRoot?.archive.path == realZip.path, "Archive path mismatch")
            try expect(splitRoot?.innerPath == "", "Root zip should have empty innerPath")

            let nested = realZip.appendingPathComponent("sub/dir/file.txt")
            let splitNested = ZipArchive.split(nested)
            try expect(splitNested?.archive.path == realZip.path, "Case-insensitive .ZIP should match")
            try expect(splitNested?.innerPath == "sub/dir/file.txt", "Nested innerPath mismatch: \(splitNested?.innerPath ?? "nil")")
        }

        testRunner("ZipArchive: parseZipInfo formats and edge cases") {
            let output = """
            Archive:  /tmp/test.zip
            -rw-r--r--  2.0 unx      123 bx defN 20240501.123045 folder/file with spaces.txt
            drwxr-xr-x  2.0 unx        0 bx stor 20240501.123045 folder/
            lrwxrwxrwx  2.0 unx       10 bx stor 20240501.123045 symlink_name
            ?---------  2.0 unx       42 bx stor invalid_date unknown.bin
            short line
            Archive size: 175 bytes
            """
            let entries = ZipArchive.parseZipInfo(output)
            try expect(entries.count == 4, "Expected 4 parsed entries, got \(entries.count)")

            try expect(entries[0].path == "folder/file with spaces.txt", "Spaces in filename preserved")
            try expect(entries[0].size == 123, "Size mismatch")
            try expect(!entries[0].isDirectory, "File should not be isDirectory")

            try expect(entries[1].path == "folder", "Trailing slash should be trimmed from dir")
            try expect(entries[1].isDirectory, "Directory entry should have isDirectory == true")

            try expect(entries[2].path == "symlink_name", "Symlink entry should parse")
            try expect(entries[3].path == "unknown.bin" && entries[3].size == 42, "? entry with invalid date")
        }

        testRunner("ZipArchive: pack, entries(in:), extractToTemp, unpack") {
            let root = try tempDir("ZipArchivePack")
            defer { try? FileManager.default.removeItem(at: root) }

            let srcDir = root.appendingPathComponent("src")
            let subDir = srcDir.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

            let helloURL = srcDir.appendingPathComponent("hello.txt")
            let nestedURL = subDir.appendingPathComponent("nested.txt")
            try "hello world".write(to: helloURL, atomically: true, encoding: .utf8)
            try "nested content".write(to: nestedURL, atomically: true, encoding: .utf8)

            let itemsToPack = [
                FileEntry(name: "hello.txt", url: helloURL, kind: .file, size: 11, modified: Date()),
                FileEntry(name: "sub", url: subDir, kind: .directory, size: 0, modified: Date()),
            ]

            let archiveURL = root.appendingPathComponent("bundle.zip")
            try ZipArchive.pack(items: itemsToPack, from: srcDir, to: archiveURL)
            try expect(FileManager.default.fileExists(atPath: archiveURL.path), "Archive should be created")

            // entries(in:) root
            let rootEntries = try ZipArchive.entries(in: archiveURL)
            try expect(rootEntries.contains(where: { $0.name == "hello.txt" && $0.kind == .file }), "Root should contain hello.txt")
            try expect(rootEntries.contains(where: { $0.name == "sub" && $0.kind == .directory }), "Root should contain sub dir")

            // entries(in:) subdirectory
            let subEntries = try ZipArchive.entries(in: archiveURL.appendingPathComponent("sub"))
            try expect(subEntries.count == 1 && subEntries[0].name == "nested.txt", "Subdir should contain nested.txt")

            // entries(in:) non-zip throws
            var threwNotZip = false
            do {
                _ = try ZipArchive.entries(in: srcDir)
            } catch ZipArchive.ZipError.notAZipArchive {
                threwNotZip = true
            }
            try expect(threwNotZip, "entries(in:) on non-zip should throw notAZipArchive")

            // extractToTemp valid file
            let tempFile = try ZipArchive.extractToTemp(url: archiveURL.appendingPathComponent("hello.txt"))
            defer { try? FileManager.default.removeItem(at: tempFile.deletingLastPathComponent()) }
            let tempContent = try String(contentsOf: tempFile, encoding: .utf8)
            try expect(tempContent == "hello world", "extractToTemp content mismatch")

            // extractToTemp on zip root throws
            var threwTempRoot = false
            do {
                _ = try ZipArchive.extractToTemp(url: archiveURL)
            } catch ZipArchive.ZipError.notAZipArchive {
                threwTempRoot = true
            }
            try expect(threwTempRoot, "extractToTemp on archive root should throw")

            // unpack overwrite: false vs true
            let unpackDir = root.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: unpackDir, withIntermediateDirectories: true)
            let existingHello = unpackDir.appendingPathComponent("hello.txt")
            try "existing".write(to: existingHello, atomically: true, encoding: .utf8)

            try ZipArchive.unpack(archive: archiveURL, to: unpackDir, overwrite: false)
            let afterNoOverwrite = try String(contentsOf: existingHello, encoding: .utf8)
            try expect(afterNoOverwrite == "existing", "unpack(overwrite: false) should keep existing file")

            try ZipArchive.unpack(archive: archiveURL, to: unpackDir, overwrite: true)
            let afterOverwrite = try String(contentsOf: existingHello, encoding: .utf8)
            try expect(afterOverwrite == "hello world", "unpack(overwrite: true) should overwrite existing file")
        }

        testRunner("ZipArchive: extractItems and conflict resolution") {
            let root = try tempDir("ZipArchiveExtract")
            defer { try? FileManager.default.removeItem(at: root) }

            let srcDir = root.appendingPathComponent("src")
            let folderDir = srcDir.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
            let aURL = srcDir.appendingPathComponent("a.txt")
            let bURL = srcDir.appendingPathComponent("b.txt")
            let innerURL = folderDir.appendingPathComponent("inner.txt")
            try "new-a".write(to: aURL, atomically: true, encoding: .utf8)
            try "new-b".write(to: bURL, atomically: true, encoding: .utf8)
            try "new-inner".write(to: innerURL, atomically: true, encoding: .utf8)

            let archiveURL = root.appendingPathComponent("items.zip")
            try ZipArchive.pack(
                items: [
                    FileEntry(name: "a.txt", url: aURL, kind: .file, size: 5, modified: Date()),
                    FileEntry(name: "b.txt", url: bURL, kind: .file, size: 5, modified: Date()),
                    FileEntry(name: "folder", url: folderDir, kind: .directory, size: 0, modified: Date()),
                ],
                from: srcDir,
                to: archiveURL
            )

            let entries = try ZipArchive.entries(in: archiveURL)
            let targetDir = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

            // 1. Fresh extract (no conflicts)
            try ZipArchive.extractItems(entries, to: targetDir)
            try expect(try String(contentsOf: targetDir.appendingPathComponent("a.txt"), encoding: .utf8) == "new-a", "Fresh file extract")
            try expect(try String(contentsOf: targetDir.appendingPathComponent("folder/inner.txt"), encoding: .utf8) == "new-inner", "Fresh dir extract")

            // 2. Skip & SkipAll
            try "old-a".write(to: targetDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "old-b".write(to: targetDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            try "old-inner".write(to: targetDir.appendingPathComponent("folder/inner.txt"), atomically: true, encoding: .utf8)

            var skipCalls = 0
            try ZipArchive.extractItems(entries, to: targetDir) { _ in
                skipCalls += 1
                return .skipAll
            }
            try expect(skipCalls == 1, "skipAll should only prompt once, got \(skipCalls)")
            try expect(try String(contentsOf: targetDir.appendingPathComponent("a.txt"), encoding: .utf8) == "old-a", "skipAll preserves a.txt")
            try expect(try String(contentsOf: targetDir.appendingPathComponent("b.txt"), encoding: .utf8) == "old-b", "skipAll preserves b.txt")

            // 3. Replace single & Rename
            let fileEntries = entries.filter { $0.kind == .file }
            var decisions: [ConflictDecision] = [.replace, .rename("b_renamed.txt")]
            try ZipArchive.extractItems(fileEntries, to: targetDir) { _ in
                decisions.removeFirst()
            }
            try expect(try String(contentsOf: targetDir.appendingPathComponent("a.txt"), encoding: .utf8) == "new-a", "replace overwrote a.txt")
            try expect(try String(contentsOf: targetDir.appendingPathComponent("b.txt"), encoding: .utf8) == "old-b", "rename kept old b.txt")
            try expect(try String(contentsOf: targetDir.appendingPathComponent("b_renamed.txt"), encoding: .utf8) == "new-b", "rename wrote b_renamed.txt")

            // 4. ReplaceAll
            try "old-a".write(to: targetDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "old-b".write(to: targetDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            var replaceAllCalls = 0
            try ZipArchive.extractItems(fileEntries, to: targetDir) { _ in
                replaceAllCalls += 1
                return .replaceAll
            }
            try expect(replaceAllCalls == 1, "replaceAll should only prompt once")
            try expect(try String(contentsOf: targetDir.appendingPathComponent("a.txt"), encoding: .utf8) == "new-a", "replaceAll overwrote a.txt")
            try expect(try String(contentsOf: targetDir.appendingPathComponent("b.txt"), encoding: .utf8) == "new-b", "replaceAll overwrote b.txt")

            // 5. ReplaceAllOlder (make a.txt target future-dated so it is NOT overwritten, b.txt past-dated so it IS overwritten)
            let future = Date().addingTimeInterval(3600)
            let past = Date().addingTimeInterval(-3600)
            try "future-a".write(to: targetDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "past-b".write(to: targetDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: targetDir.appendingPathComponent("a.txt").path)
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: targetDir.appendingPathComponent("b.txt").path)

            var olderCalls = 0
            try ZipArchive.extractItems(fileEntries, to: targetDir) { _ in
                olderCalls += 1
                return .replaceAllOlder
            }
            try expect(olderCalls == 1, "replaceAllOlder should prompt once")
            try expect(try String(contentsOf: targetDir.appendingPathComponent("a.txt"), encoding: .utf8) == "future-a", "replaceAllOlder should keep newer target")
            try expect(try String(contentsOf: targetDir.appendingPathComponent("b.txt"), encoding: .utf8) == "new-b", "replaceAllOlder should replace older target")

            // 6. Cancel stops extraction early without overwriting subsequent files
            try "keep-a".write(to: targetDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "keep-b".write(to: targetDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            var cancelCalls = 0
            try ZipArchive.extractItems(fileEntries, to: targetDir) { _ in
                cancelCalls += 1
                return .cancel
            }
            try expect(cancelCalls == 1, ".cancel should stop after first conflict")
            try expect(try String(contentsOf: targetDir.appendingPathComponent("a.txt"), encoding: .utf8) == "keep-a", ".cancel should not overwrite a.txt")
            try expect(try String(contentsOf: targetDir.appendingPathComponent("b.txt"), encoding: .utf8) == "keep-b", ".cancel should not overwrite b.txt")

            // 7. Single skip inside directory extraction
            try "keep-inner".write(to: targetDir.appendingPathComponent("folder/inner.txt"), atomically: true, encoding: .utf8)
            let dirOnly = entries.filter { $0.kind == .directory }
            try ZipArchive.extractItems(dirOnly, to: targetDir) { _ in .skip }
            try expect(try String(contentsOf: targetDir.appendingPathComponent("folder/inner.txt"), encoding: .utf8) == "keep-inner", ".skip inside directory should preserve inner.txt")
        }

        testRunner("ZipArchive: ZipError descriptions") {
            let url = URL(fileURLWithPath: "/tmp/not.txt")
            let e1 = ZipArchive.ZipError.notAZipArchive(url).errorDescription ?? ""
            let e2 = ZipArchive.ZipError.unzipFailed(2, "bad zip").errorDescription ?? ""
            let e3 = ZipArchive.ZipError.unzipFailed(3, "").errorDescription ?? ""
            try expect(e1.contains("not.txt"), "notAZipArchive should mention filename")
            try expect(e2 == "bad zip", "unzipFailed with message should return message")
            try expect(e3.contains("3"), "unzipFailed with empty message should mention status")
        }

        testRunner("FileCommands: pack single, multiple marked, cancelled, and empty") {
            final class PackPrompts: FileCommandPrompts {
                var answer: String?
                var lastDefault: String?
                var askCount = 0
                func askText(title: String, message: String, defaultValue: String, okTitle: String) -> String? {
                    askCount += 1
                    lastDefault = defaultValue
                    return answer
                }
                func askTransfer(_ q: TransferQuestion) -> TransferAnswer? { nil }
                func confirm(title: String, message: String, okTitle: String) -> Bool { true }
                func resolveConflict(_ c: TransferConflict) -> ConflictDecision { .skip }
                func showProblems(title: String, report: OperationReport) {}
            }

            let root = try tempDir("FileCommandsPack")
            defer { try? FileManager.default.removeItem(at: root) }
            let src = root.appendingPathComponent("src")
            let dst = root.appendingPathComponent("dst")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            try "one".write(to: src.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
            try "two".write(to: src.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)

            let view = CoverageTests.commander(src)
            view.rightView.model.go(to: dst, visibleRows: 20)
            let prompts = PackPrompts()
            view.fileCommands.prompts = prompts

            // 1. Empty targets (cursor on ..) -> does not prompt
            view.leftView.model.focus(name: "..", visibleRows: 20)
            view.fileCommands.pack()
            try expect(prompts.askCount == 0, "pack on .. should not prompt")

            // 2. Cancelled prompt -> does not create archive
            view.leftView.model.focus(name: "one.txt", visibleRows: 20)
            prompts.answer = nil
            view.fileCommands.pack()
            try expect(prompts.askCount == 1, "pack should prompt once")
            let singleZip = dst.appendingPathComponent("one.zip")
            try expect(!FileManager.default.fileExists(atPath: singleZip.path), "Cancelled pack should not create zip")

            // 3. Single file pack -> creates one.zip
            prompts.answer = singleZip.path
            view.fileCommands.pack()
            CoverageTests.wait(10) { FileManager.default.fileExists(atPath: singleZip.path) }
            try expect(FileManager.default.fileExists(atPath: singleZip.path), "Single file pack should create one.zip")

            // 4. Multiple marked files -> defaults to source directory name (src.zip) and clears marks
            view.leftView.model.setMarks(["one.txt", "two.txt"])
            let multiZip = dst.appendingPathComponent("src.zip")
            prompts.answer = multiZip.path
            view.fileCommands.pack()
            try expect(prompts.lastDefault == multiZip.path, "Multi-item pack default should be src.zip, got \(prompts.lastDefault ?? "nil")")
            CoverageTests.wait(10) {
                FileManager.default.fileExists(atPath: multiZip.path) && view.leftView.model.marked.isEmpty
            }
            try expect(FileManager.default.fileExists(atPath: multiZip.path), "Multi-item pack should create src.zip")
            try expect(view.leftView.model.marked.isEmpty, "Pack should clear marks on completion")
        }

        testRunner("FileCommands: unpack archive, cancel, overwrite, and non-file guard") {
            final class UnpackPrompts: FileCommandPrompts {
                var answer: (target: String, overwrite: Bool)?
                var askCount = 0
                func askText(title: String, message: String, defaultValue: String, okTitle: String) -> String? { nil }
                func askUnpack(archiveName: String, defaultTarget: String) -> (target: String, overwrite: Bool)? {
                    askCount += 1
                    return answer
                }
                func askTransfer(_ q: TransferQuestion) -> TransferAnswer? { nil }
                func confirm(title: String, message: String, okTitle: String) -> Bool { true }
                func resolveConflict(_ c: TransferConflict) -> ConflictDecision { .skip }
                func showProblems(title: String, report: OperationReport) {}
            }

            let root = try tempDir("FileCommandsUnpack")
            defer { try? FileManager.default.removeItem(at: root) }
            let src = root.appendingPathComponent("src")
            let dst = root.appendingPathComponent("dst")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

            let payload = src.appendingPathComponent("note.txt")
            try "fresh content".write(to: payload, atomically: true, encoding: .utf8)
            let zipURL = src.appendingPathComponent("bundle.zip")
            try ZipArchive.pack(
                items: [FileEntry(name: "note.txt", url: payload, kind: .file, size: 13, modified: Date())],
                from: src,
                to: zipURL
            )
            let badZip = src.appendingPathComponent("corrupt.zip")
            try "not a zip".write(to: badZip, atomically: true, encoding: .utf8)

            let view = CoverageTests.commander(src)
            view.rightView.model.go(to: dst, visibleRows: 20)
            let prompts = UnpackPrompts()
            view.fileCommands.prompts = prompts

            // 1. Non-file (..) -> does not prompt
            view.leftView.model.focus(name: "..", visibleRows: 20)
            view.fileCommands.unpack()
            try expect(prompts.askCount == 0, "unpack on .. should not prompt")

            // 2. Cancelled unpack -> does not extract
            view.leftView.model.focus(name: "bundle.zip", visibleRows: 20)
            prompts.answer = nil
            view.fileCommands.unpack()
            try expect(prompts.askCount == 1, "unpack should prompt once")
            let extracted = dst.appendingPathComponent("note.txt")
            try expect(!FileManager.default.fileExists(atPath: extracted.path), "Cancelled unpack should not extract")

            // 3. Successful unpack with overwrite: true
            try "stale".write(to: extracted, atomically: true, encoding: .utf8)
            prompts.answer = (dst.path, true)
            view.fileCommands.unpack()
            try expect(try String(contentsOf: extracted, encoding: .utf8) == "fresh content", "Unpack should overwrite note.txt")

            // 4. Corrupt zip -> catches error cleanly without crashing
            view.leftView.model.focus(name: "corrupt.zip", visibleRows: 20)
            prompts.answer = (dst.path, true)
            view.fileCommands.unpack()
        }

        testRunner("FileCommands: copy, move (blocked), and drop from inside zip archive") {
            final class ZipTransferPrompts: FileCommandPrompts {
                var targetPath: String
                init(targetPath: String) { self.targetPath = targetPath }
                func askText(title: String, message: String, defaultValue: String, okTitle: String) -> String? { nil }
                func askTransfer(_ q: TransferQuestion) -> TransferAnswer? {
                    TransferAnswer(target: targetPath, mask: "*")
                }
                func confirm(title: String, message: String, okTitle: String) -> Bool { true }
                func resolveConflict(_ c: TransferConflict) -> ConflictDecision { .replace }
                func showProblems(title: String, report: OperationReport) {}
            }

            let root = try tempDir("FileCommandsZipTransfer")
            defer { try? FileManager.default.removeItem(at: root) }
            let src = root.appendingPathComponent("src")
            let dst = root.appendingPathComponent("dst")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

            let fileURL = src.appendingPathComponent("inside.txt")
            try "zip payload".write(to: fileURL, atomically: true, encoding: .utf8)
            let zipURL = src.appendingPathComponent("archive.zip")
            try ZipArchive.pack(
                items: [FileEntry(name: "inside.txt", url: fileURL, kind: .file, size: 11, modified: Date())],
                from: src,
                to: zipURL
            )

            let view = CoverageTests.commander(src)
            view.rightView.model.go(to: dst, visibleRows: 20)
            view.leftView.model.go(to: zipURL, visibleRows: 20)
            try expect(view.leftView.model.isInsideZip, "Left panel should be inside zip")

            view.leftView.model.focus(name: "inside.txt", visibleRows: 20)
            let prompts = ZipTransferPrompts(targetPath: dst.path)
            view.fileCommands.prompts = prompts

            // 1. Move from inside zip is disallowed (no-op)
            view.fileCommands.move()
            let extracted = dst.appendingPathComponent("inside.txt")
            try expect(!FileManager.default.fileExists(atPath: extracted.path), "Move from inside zip should not extract")

            // 2. Copy from inside zip extracts to target
            view.fileCommands.copy()
            try expect(try String(contentsOf: extracted, encoding: .utf8) == "zip payload", "Copy from inside zip should extract")

            // 3. Drop from inside zip overwrites existing via conflict prompt
            try "stale".write(to: extracted, atomically: true, encoding: .utf8)
            if let entry = view.leftView.model.currentEntry {
                let drop = PanelDrop(entries: [entry], source: view.leftView, target: view.rightView, folder: dst, folderRow: nil, move: false)
                view.fileCommands.drop(drop)
            }
            try expect(try String(contentsOf: extracted, encoding: .utf8) == "zip payload", "Drop from inside zip should extract and replace")
        }
    }
}
