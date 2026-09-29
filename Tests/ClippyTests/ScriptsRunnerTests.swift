import XCTest
@testable import Clippy

/// Runner behavior with real short-lived children: kill escalation, argument /
/// environment / cwd passing, temp-file uniqueness, and the large-input path.
final class ScriptsRunnerTests: XCTestCase {
    private let path = "/usr/bin:/bin"

    private func run(_ script: Script, input: String? = nil, timeout: TimeInterval? = nil,
                     grace: TimeInterval = 0.3) async -> ScriptResult {
        await ScriptRunner.run(script, input: input, timeout: timeout, gracePeriod: grace, searchPath: path)
    }

    func testTimeoutStopsSleepWithSigterm() async {
        let started = Date()
        let result = await run(Script(name: "s", body: "sleep 30"), timeout: 0.3)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.terminationSignal, SIGTERM)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testSigtermIgnoringScriptIsKilledAfterGracePeriod() async {
        let started = Date()
        let result = await run(Script(name: "t", body: "trap '' TERM; sleep 30; echo unreachable"),
                               timeout: 0.3, grace: 0.3)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.terminationSignal, SIGKILL, "escalation to SIGKILL must end the group")
        XCTAssertFalse(result.stdout.contains("unreachable"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancelEscalatesAndReportsCancelled() async {
        let script = Script(name: "c", body: "trap '' TERM; sleep 30")
        let task = Task { await run(script, grace: 0.3) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertFalse(result.succeeded)
    }

    func testGrandchildInTheProcessGroupIsKilledWithTheScript() async {
        // The pid file proves the background child existed; it must be gone after the timeout.
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-pg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        _ = await run(Script(name: "g", body: "sleep 30 & echo $! > '\(pidFile.path)'; wait"), timeout: 0.5)
        let pid = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        XCTAssertGreaterThan(pid, 0)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotEqual(kill(pid, 0), 0, "grandchild should have been killed with the group")
    }

    func testArgumentsEnvironmentAndWorkingDirectoryArePassed() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-cwd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = Script(name: "a", body: "print -r -- \"$1|$2|$FOO|$PWD\"",
                            arguments: ["one two", "three"], workingDirectory: dir.path,
                            environment: ["FOO": "bar", "CLIPPY_CLIP": "spoofed"])
        let result = await run(script, input: "real")
        let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        XCTAssertEqual(Array(parts.prefix(3)), ["one two", "three", "bar"])
        // /var is a symlink to /private/var, so compare the unique leaf, not the prefix.
        XCTAssertTrue(parts.last?.hasSuffix(dir.lastPathComponent) ?? false, result.stdout)
    }

    func testReservedClipVariableCannotBeSpoofed() async {
        let script = Script(name: "e", body: "printf '%s' \"$CLIPPY_CLIP\"", environment: ["CLIPPY_CLIP": "spoofed"])
        let result = await run(script, input: "real")
        XCTAssertEqual(result.stdout, "real")
    }

    func testEachRunGetsItsOwnTempFileAndItIsRemoved() async {
        let script = Script(name: "p", body: "print -r -- $0")
        async let first = run(script)
        async let second = run(script)
        let firstOutput = await first.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondOutput = await second.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(firstOutput.isEmpty)
        XCTAssertNotEqual(firstOutput, secondOutput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstOutput))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondOutput))
        XCTAssertNotEqual(ScriptRunner.makeTempURL(for: script), ScriptRunner.makeTempURL(for: script))
    }

    func testLargeClipGoesByStdinAndFileWhileEnvironmentIsCapped() async {
        let big = String(repeating: "é", count: 100_000) // 200,000 bytes
        let body = """
        print -r -- "${#CLIPPY_CLIP} $CLIPPY_CLIP_TRUNCATED"
        wc -c < "$CLIPPY_CLIP_FILE"
        cat | wc -c
        """
        let result = await run(Script(name: "big", body: body), input: big)
        let lines = result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.count, 3, result.stderr)
        XCTAssertEqual(lines[0], "\(ScriptRunner.clipEnvironmentCap / 2) 1", "capped on a character boundary")
        XCTAssertEqual(lines[1], "200000")
        XCTAssertEqual(lines[2], "200000")
    }

    func testCappedUTF8NeverSplitsACharacter() {
        XCTAssertEqual(ScriptRunner.cappedUTF8("aé", maxBytes: 2), "a")
        XCTAssertEqual(ScriptRunner.cappedUTF8("abc", maxBytes: 10), "abc")
        XCTAssertEqual(ScriptRunner.cappedUTF8("😀😀", maxBytes: 5), "😀")
    }

    func testCustomStdinIsUsedWhenNoClipIsFed() async {
        let result = await run(Script(name: "i", body: "cat", stdinText: "typed"))
        XCTAssertEqual(result.stdout, "typed")
    }

    func testStreamingDeliversOutputBeforeExit() async {
        final class Box: @unchecked Sendable { var text = ""; let lock = NSLock() }
        let box = Box()
        let result = await ScriptRunner.run(Script(name: "st", body: "echo one; sleep 0.2; echo two"),
                                            searchPath: path) { stream, text in
            guard stream == .stdout else { return }
            box.lock.lock(); box.text += text; box.lock.unlock()
        }
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(box.text, "one\ntwo\n")
    }

    func testNonZeroExitIsFailedNotTimedOut() async {
        let result = await run(Script(name: "f", body: "exit 3"))
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.exitCode, 3)
    }

    func testMissingWorkingDirectoryIsALaunchFailureWithMessage() async {
        let result = await run(Script(name: "w", body: "true", workingDirectory: "/definitely/not/here"))
        XCTAssertTrue(result.launchFailed)
        XCTAssertTrue(result.stderr.contains("Working directory"))
    }

    // MARK: Interpreter resolution

    func testResolvesFromInjectedPathAndReportsMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("python3")
        try "#!/bin/sh\necho fake\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let script = Script(name: "py", interpreter: .python3)
        guard case .success(let plan) = ScriptRunner.resolveLaunch(for: script, searchPath: dir.path + ":/bin") else {
            return XCTFail("python3 should resolve from the injected PATH")
        }
        XCTAssertEqual(plan.executable, fake.path)
        XCTAssertTrue(plan.searchPath.hasPrefix(dir.path))

        guard case .failure(let error) = ScriptRunner.resolveLaunch(for: Script(name: "n", interpreter: .node),
                                                                    searchPath: dir.path) else {
            return XCTFail("node is not on the injected PATH")
        }
        XCTAssertTrue(error.message.contains("PATH"))
        XCTAssertNotNil(ScriptRunner.preflight(Script(name: "n", interpreter: .node), searchPath: dir.path))
        XCTAssertNil(ScriptRunner.preflight(script, searchPath: dir.path))
    }

    func testCustomInterpreterOverridesPathAndIsValidated() {
        let ok = Script(name: "c", interpreter: .python3, customInterpreterPath: "/bin/sh")
        guard case .success(let plan) = ScriptRunner.resolveLaunch(for: ok, searchPath: "/nonexistent") else {
            return XCTFail("custom path should win over PATH")
        }
        XCTAssertEqual(plan.executable, "/bin/sh")
        let bad = Script(name: "c", customInterpreterPath: "/no/such/interp")
        if case .success = ScriptRunner.resolveLaunch(for: bad, searchPath: path) { XCTFail("must reject missing path") }
    }

    func testPathMergeKeepsOrderAndDropsDuplicates() {
        XCTAssertEqual(LoginShellPath.merge(["/a:/b", "/b:/c::", "/a"]), "/a:/b:/c")
    }

    func testUTF8StreamDecoderHoldsBackSplitCharacters() {
        let decoder = UTF8StreamDecoder()
        let bytes = Array("é".utf8)
        XCTAssertEqual(decoder.decode(Data([0x61, bytes[0]])), "a")
        XCTAssertEqual(decoder.decode(Data([bytes[1]])), "é")
    }
}
