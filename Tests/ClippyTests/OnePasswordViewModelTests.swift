import XCTest
@testable import Clippy

/// Scripted `op`: the handler decides the result per call; every call is recorded.
private final class ScriptedRunner: OpCommandRunner {
    struct Call { let args: [String]; let input: String? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var installed = true
    var handler: ([String]) async -> Subprocess.Output

    init(_ handler: @escaping ([String]) async -> Subprocess.Output) { self.handler = handler }

    var isAvailable: Bool { installed }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }

    func run(_ args: [String], input: String?, timeout: TimeInterval) async -> Subprocess.Output {
        lock.lock(); recorded.append(Call(args: args, input: input)); lock.unlock()
        return await handler(args)
    }

    static func ok(_ stdout: String) -> Subprocess.Output {
        Subprocess.Output(stdout: stdout, stderr: "", exitCode: 0, launchFailed: false, timedOut: false)
    }
    static func fail(_ stderr: String) -> Subprocess.Output {
        Subprocess.Output(stdout: "", stderr: stderr, exitCode: 1, launchFailed: false, timedOut: false)
    }
}

@MainActor
final class OnePasswordViewModelTests: XCTestCase {
    private let listJSON = #"[{"id":"a","title":"A","category":"LOGIN"},{"id":"b","title":"B","category":"LOGIN"}]"#

    private func detailJSON(_ id: String) -> String {
        #"{"id":"\#(id)","title":"\#(id.uppercased())","category":"LOGIN","fields":[]}"#
    }

    private func makeModel(_ runner: ScriptedRunner, deadline: TimeInterval = 5) -> OnePasswordViewModel {
        OnePasswordViewModel(makeService: { OnePasswordService(vault: "Clippy", runner: runner) },
                             probeInstalled: { runner.installed }, deadline: deadline)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    func testReadyWhenItemsReturned() async {
        let model = makeModel(ScriptedRunner { _ in ScriptedRunner.ok(self.listJSON) })
        model.reload()
        XCTAssertEqual(model.state, .loading)
        await waitUntil("ready") { model.state == .ready }
        XCTAssertEqual(model.items.map(\.id), ["a", "b"])
    }

    func testEmptyVault() async {
        let model = makeModel(ScriptedRunner { _ in ScriptedRunner.ok("[]") })
        model.reload()
        await waitUntil("empty") { model.state == .empty }
    }

    func testNotInstalled() async {
        let runner = ScriptedRunner { _ in ScriptedRunner.ok("[]") }
        runner.installed = false
        let model = makeModel(runner)
        model.reload()
        XCTAssertEqual(model.state, .notInstalled)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testReprobeAfterInstall() async {
        let runner = ScriptedRunner { _ in ScriptedRunner.ok(self.listJSON) }
        runner.installed = false
        let model = makeModel(runner)
        model.reload()
        XCTAssertEqual(model.state, .notInstalled)
        runner.installed = true
        model.reload()
        await waitUntil("ready after install") { model.state == .ready }
    }

    func testNotSignedInMapsToNeedsSignInAndSignInThenReloads() async {
        let signedIn = LockedFlag()
        let runner = ScriptedRunner { args in
            switch args.first {
            case "signin": signedIn.set(); return ScriptedRunner.ok("")
            case "whoami": return ScriptedRunner.ok("{}")
            default:
                return signedIn.isSet ? ScriptedRunner.ok(self.listJSON)
                    : ScriptedRunner.fail("[ERROR] account is not signed in")
            }
        }
        let model = makeModel(runner)
        model.reload()
        await waitUntil("needsSignIn") { if case .needsSignIn = model.state { return true }; return false }

        model.signIn()
        await waitUntil("ready after signin") { model.state == .ready }
        XCTAssertTrue(runner.calls.contains { $0.args == ["signin"] })
        XCTAssertFalse(model.signingIn)
    }

    func testFailureMapsToErrorWithMessage() async {
        let model = makeModel(ScriptedRunner { _ in ScriptedRunner.fail("vault not found") })
        model.reload()
        await waitUntil("error") { model.state == .error("vault not found") }
    }

    func testRunnerTimeoutMapsToError() async {
        let model = makeModel(ScriptedRunner { _ in
            Subprocess.Output(stdout: "", stderr: "Timed out", exitCode: 15, launchFailed: false, timedOut: true)
        })
        model.reload()
        await waitUntil("timeout error") { model.state == .error(OnePasswordError.timedOut.localizedDescription) }
    }

    func testRunnerThatNeverReturnsStillEndsInErrorNotAnInfiniteSpinner() async {
        let model = makeModel(ScriptedRunner { _ in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return ScriptedRunner.ok("[]")
        }, deadline: 0.2)
        model.reload()
        XCTAssertEqual(model.state, .loading)
        await waitUntil("deadline error") { model.state == .error(OnePasswordError.timedOut.localizedDescription) }
    }

    func testStaleDetailResultIsDroppedAndDoesNotClearLoading() async {
        let runner = ScriptedRunner { args in
            if args.first == "item", args.count > 2, args[1] == "get" {
                if args[2] == "a" {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    return ScriptedRunner.ok(self.detailJSON("a"))
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                return ScriptedRunner.ok(self.detailJSON("b"))
            }
            return ScriptedRunner.ok(self.listJSON)
        }
        let model = makeModel(runner)
        model.reload()
        await waitUntil("ready") { model.state == .ready }

        model.toggleExpand(model.items[0])   // slow "a"
        model.toggleExpand(model.items[1])   // replaces it with "b"
        // "a" finishes at ~0.3s: it must not clear loading or set detail while "b" is pending.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(model.detailLoading, "stale task must not clear detailLoading")
        XCTAssertNil(model.detail)

        await waitUntil("b detail") { model.detail?.id == "b" }
        XCTAssertFalse(model.detailLoading)
        XCTAssertEqual(model.expandedItemID, "b")
    }

    func testCollapseDuringLoadDiscardsTheLateResult() async {
        let runner = ScriptedRunner { args in
            if args.count > 1, args[1] == "get" {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return ScriptedRunner.ok(self.detailJSON("a"))
            }
            return ScriptedRunner.ok(self.listJSON)
        }
        let model = makeModel(runner)
        model.reload()
        await waitUntil("ready") { model.state == .ready }
        model.toggleExpand(model.items[0])
        model.collapse()
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertNil(model.detail)
        XCTAssertFalse(model.detailLoading)
        XCTAssertNil(model.expandedItemID)
    }

    func testReloadUsesTheCurrentVaultAndCollapsesTheExpandedItem() async {
        let vault = LockedString("One")
        let runner = ScriptedRunner { _ in ScriptedRunner.ok(self.listJSON) }
        let model = OnePasswordViewModel(
            makeService: { OnePasswordService(vault: vault.value, runner: runner) },
            probeInstalled: { true })
        model.reload()
        await waitUntil("ready") { model.state == .ready }
        model.toggleExpand(model.items[0])
        vault.value = "Two"
        model.reload()
        XCTAssertNil(model.expandedItemID)
        await waitUntil("second list") { runner.calls.filter { $0.args.first == "item" && $0.args[1] == "list" }.count == 2 }
        XCTAssertTrue(runner.calls.contains { $0.args.contains("Two") })
    }

    // MARK: SEC-04

    func testCreateSecretSendsValueOnStdinNeverInArgv() async throws {
        let runner = ScriptedRunner { _ in ScriptedRunner.ok("") }
        let secret = "s3cr3t-VALUE-9f2"
        try await OnePasswordService(vault: "Clippy", runner: runner).createSecret(title: "Prod DB", value: secret)

        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.args, ["item", "create", "--vault", "Clippy"])
        XCTAssertFalse(call.args.joined(separator: " ").contains(secret))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(call.input).utf8)) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Prod DB")
        let fields = try XCTUnwrap(object["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.first?["value"] as? String, secret)
        XCTAssertEqual(fields.first?["type"] as? String, "CONCEALED")
    }
}

private final class LockedFlag {
    private let lock = NSLock(); private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

private final class LockedString {
    private let lock = NSLock(); private var stored: String
    init(_ value: String) { stored = value }
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
