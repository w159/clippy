import XCTest
@testable import Clippy

@MainActor
final class ScriptStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-scripts-\(UUID().uuidString).json")
    }

    func testCRUDAndPersistence() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ScriptStore(fileURL: url)
        XCTAssertTrue(store.scripts.isEmpty)

        var script = Script(name: "Greeting", interpreter: .zsh, body: "echo hi")
        store.add(script)
        XCTAssertEqual(store.scripts.count, 1)

        script.body = "echo bye"
        store.update(script)
        XCTAssertEqual(store.script(id: script.id)?.body, "echo bye")

        // A fresh store reading the same file sees the persisted script.
        let reloaded = ScriptStore(fileURL: url)
        XCTAssertEqual(reloaded.scripts.count, 1)
        XCTAssertEqual(reloaded.scripts.first?.name, "Greeting")
        XCTAssertEqual(reloaded.scripts.first?.body, "echo bye")

        store.delete(id: script.id)
        XCTAssertTrue(store.scripts.isEmpty)
        XCTAssertTrue(ScriptStore(fileURL: url).scripts.isEmpty)
    }

    func testInterpreterLaunchMapping() {
        XCTAssertEqual(ScriptInterpreter.zsh.launch.executable, "/bin/zsh")
        XCTAssertEqual(ScriptInterpreter.python3.launch.executable, "/usr/bin/env")
        XCTAssertEqual(ScriptInterpreter.python3.launch.leadingArgs, ["python3"])
        XCTAssertEqual(ScriptInterpreter.applescript.launch.executable, "/usr/bin/osascript")
    }
}

final class ScriptRunnerTests: XCTestCase {
    func testRunsAndCapturesStdout() async {
        let script = Script(name: "echo", interpreter: .zsh, body: "echo hello")
        let result = await ScriptRunner.run(script)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testNonZeroExitIsNotSuccess() async {
        let script = Script(name: "fail", interpreter: .zsh, body: "exit 3")
        let result = await ScriptRunner.run(script)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 3)
    }

    func testTruncatedOutputCountsAsSuccess() {
        // A truncation-kill yields a SIGTERM (non-zero) exit, but the captured
        // output is valid up to the ceiling, so it must report success.
        let truncated = ScriptResult(stdout: "x", stderr: "", exitCode: 15,
                                     durationMs: 1, timedOut: false, truncated: true)
        XCTAssertTrue(truncated.succeeded)
        let realFailure = ScriptResult(stdout: "", stderr: "boom", exitCode: 1,
                                       durationMs: 1, timedOut: false, truncated: false)
        XCTAssertFalse(realFailure.succeeded)
    }

    func testLargeStdinDoesNotDeadlock() async {
        // Regression: stdin larger than the ~64KB pipe buffer used to deadlock
        // because the synchronous write ran before the output readers started.
        let big = String(repeating: "a", count: 200_000)
        let script = Script(name: "cat", interpreter: .zsh, body: "cat")
        let result = await ScriptRunner.run(script, input: big, timeout: 15)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.count, big.count)
    }

    func testReceivesClipOnStdin() async {
        let script = Script(name: "cat", interpreter: .zsh, body: "cat")
        let result = await ScriptRunner.run(script, input: "ping")
        XCTAssertEqual(result.stdout, "ping")
    }

    func testReceivesClipInEnvironment() async {
        let script = Script(name: "env", interpreter: .zsh, body: "printf '%s' \"$CLIPPY_CLIP\"")
        let result = await ScriptRunner.run(script, input: "from-env")
        XCTAssertEqual(result.stdout, "from-env")
    }
}
