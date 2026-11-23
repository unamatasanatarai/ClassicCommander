import Cocoa

@main
struct TestMain {
    static func main() {
        // Initialize NSApplication for AppKit UI components
        _ = NSApplication.shared
        // No dialog may block and nothing may be launched while testing: every dialog answers
        // "Cancel", panels choose nothing; tests that need an answer set these themselves.
        Modal.answerAlert = { _ in .cancel }
        Modal.answerPanel = { _ in [] }
        Modal.opened = { _ in }
        Modal.launched = { _ in }
        Modal.terminated = {}
        Modal.poppedUp = { _ in }
        // Running curl/sftp are polled often, so progress reporting runs even for quick transfers.
        RemoteTiming.pollInterval = 0.01

        print("==================================================")
        print("         Running Swift Native Test Suite          ")
        print("==================================================")

        var passed = 0
        var failed = 0
        let totalStart = CFAbsoluteTimeGetCurrent()

        let runTest: (String, () throws -> Void) -> Void = { name, block in
            let start = CFAbsoluteTimeGetCurrent()
            do {
                try block()
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                print(String(format: "  ✔ PASS: %@ (%.2fms)", name, elapsedMs))
                passed += 1
            } catch {
                print("  ❌ FAIL: \(name) - \(error)")
                failed += 1
            }
        }

        print("\n--- Application Configuration & State Suite ---")
        AppTests.run(testRunner: runTest)

        print("\n--- Two-Pane Commander Suite ---")
        CommanderTests.run(testRunner: runTest)

        print("\n--- Find Files Suite ---")
        SearchTests.run(testRunner: runTest)

        print("\n--- Synchronize Directories Suite ---")
        SyncTests.run(testRunner: runTest)

        print("\n--- FTP Suite ---")
        FTPTests.run(testRunner: runTest)

        print("\n--- SFTP Suite ---")
        SFTPTests.run(testRunner: runTest)

        print("\n--- Security Regression Suite ---")
        SecurityTests.run(testRunner: runTest)

        print("\n--- Coverage Suite ---")
        CoverageTests.run(testRunner: runTest)

        let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000.0

        print("\n--------------------------------------------------")
        print(String(format: "  Summary: %d Passed | %d Failed (Total: %.2fms)", passed, failed, totalElapsedMs))
        print("==================================================")

        if failed > 0 {
            exit(1)
        }
    }
}
