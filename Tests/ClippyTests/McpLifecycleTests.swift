import XCTest
@testable import Clippy

/// Controllable stand-in for the node child.
private final class FakeChild: McpChild {
    let pid: Int32
    private let lock = NSLock()
    private var running = true
    private(set) var terminateCount = 0
    private(set) var killCount = 0
    /// When false the child ignores SIGTERM and only dies on kill (a wedged node).
    let diesOnTerminate: Bool

    init(pid: Int32, diesOnTerminate: Bool = true) {
        self.pid = pid
        self.diesOnTerminate = diesOnTerminate
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func terminate() { lock.lock(); terminateCount += 1; if diesOnTerminate { running = false }; lock.unlock() }
    func kill() { lock.lock(); killCount += 1; running = false; lock.unlock() }
}

private final class LaunchLog {
    private let lock = NSLock()
    private(set) var children: [FakeChild] = []
    var diesOnTerminate = true
    func launch(_ spec: McpLaunchSpec) -> McpChild? {
        lock.lock(); defer { lock.unlock() }
        let child = FakeChild(pid: Int32(1000 + children.count), diesOnTerminate: diesOnTerminate)
        children.append(child)
        return child
    }
}

final class McpLifecycleTests: XCTestCase {
    private let spec = McpLaunchSpec(nodePath: "/n", scriptPath: "/s", port: 51764,
                                     databasePath: "/d", token: String(repeating: "t", count: 43))

    private func makeLifecycle(_ log: LaunchLog, grace: TimeInterval = 0.1) -> McpLifecycle {
        McpLifecycle(launcher: { spec, _, _ in log.launch(spec) }, terminationGrace: grace)
    }

    func testStartLaunchesOnceAndSecondStartIsANoOp() async {
        let log = LaunchLog()
        let lifecycle = makeLifecycle(log)
        let first = await lifecycle.start(spec, onStderrLine: { _ in }, onExit: { _ in })
        let second = await lifecycle.start(spec, onStderrLine: { _ in }, onExit: { _ in })

        guard case .started(let gen) = first, case .alreadyRunning(let gen2) = second else {
            return XCTFail("\(first) \(second)")
        }
        XCTAssertEqual(gen, gen2)
        XCTAssertEqual(log.children.count, 1)
    }

    func testStopTerminatesTheStoredChildAndInvalidatesItsGeneration() async {
        let log = LaunchLog()
        let lifecycle = makeLifecycle(log)
        guard case .started(let gen) = await lifecycle.start(spec, onStderrLine: { _ in }, onExit: { _ in }) else {
            return XCTFail()
        }
        let currentBefore = await lifecycle.isCurrent(gen)
        XCTAssertTrue(currentBefore)

        await lifecycle.stop()

        XCTAssertEqual(log.children[0].terminateCount, 1)
        XCTAssertFalse(log.children[0].isRunning)
        // A health poll holding `gen` must now see itself as stale and stay silent.
        let currentAfter = await lifecycle.isCurrent(gen)
        XCTAssertFalse(currentAfter)
        let pid = await lifecycle.runningPid
        XCTAssertNil(pid)
    }

    func testStopEscalatesToKillWhenTheChildIgnoresTerminate() async {
        let log = LaunchLog()
        log.diesOnTerminate = false
        let lifecycle = makeLifecycle(log, grace: 0.05)
        _ = await lifecycle.start(spec, onStderrLine: { _ in }, onExit: { _ in })

        await lifecycle.stop()

        XCTAssertEqual(log.children[0].terminateCount, 1)
        XCTAssertEqual(log.children[0].killCount, 1)
        XCTAssertFalse(log.children[0].isRunning)
    }

    func testStopWithNoChildStillAdvancesTheGeneration() async {
        let lifecycle = makeLifecycle(LaunchLog())
        let before = await lifecycle.generation
        await lifecycle.stop()
        let after = await lifecycle.generation
        XCTAssertGreaterThan(after, before)
    }

    func testRestartStopsTheOldChildBeforeLaunchingTheNewOne() async {
        let log = LaunchLog()
        let lifecycle = makeLifecycle(log)
        _ = await lifecycle.start(spec, onStderrLine: { _ in }, onExit: { _ in })

        let outcome = await lifecycle.restart(spec, onStderrLine: { _ in }, onExit: { _ in })

        guard case .started = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(log.children.count, 2)
        XCTAssertFalse(log.children[0].isRunning, "old child gone before the new launch")
        XCTAssertTrue(log.children[1].isRunning)
        let pid = await lifecycle.runningPid
        XCTAssertEqual(pid, 1001)
    }

    func testConcurrentStartsLaunchExactlyOneChild() async {
        let log = LaunchLog()
        let lifecycle = makeLifecycle(log)
        let spec = self.spec
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = await lifecycle.start(spec, onStderrLine: { _ in }, onExit: { _ in }) }
            }
        }
        XCTAssertEqual(log.children.count, 1)
    }

    func testStopThenStartOrderingIsPreserved() async {
        let log = LaunchLog()
        let lifecycle = makeLifecycle(log)
        _ = await lifecycle.start(spec, onStderrLine: { _ in }, onExit: { _ in })
        await lifecycle.stop()
        _ = await lifecycle.start(spec, onStderrLine: { _ in }, onExit: { _ in })
        XCTAssertEqual(log.children.count, 2)
        let pid = await lifecycle.runningPid
        XCTAssertEqual(pid, 1001)
    }

    func testLauncherFailureReportsLaunchFailedAndLeavesNoChild() async {
        let lifecycle = McpLifecycle(launcher: { _, _, _ in nil }, terminationGrace: 0.05)
        let outcome = await lifecycle.start(spec, onStderrLine: { _ in }, onExit: { _ in })
        XCTAssertEqual(outcome, .launchFailed)
        let pid = await lifecycle.runningPid
        XCTAssertNil(pid)
    }

    // MARK: Port status (SET-03)

    func testPortStatusIsDerivedFromTheRunningServerFirst() {
        XCTAssertEqual(McpPortStatus.derive(port: 51764, serverPort: 51764, isFree: true), .inUseByClippy)
        XCTAssertEqual(McpPortStatus.derive(port: 51764, serverPort: 51764, isFree: false), .inUseByClippy)
        XCTAssertEqual(McpPortStatus.derive(port: 51764, serverPort: nil, isFree: true), .available)
        XCTAssertEqual(McpPortStatus.derive(port: 51764, serverPort: nil, isFree: false), .inUseByOther)
        XCTAssertEqual(McpPortStatus.derive(port: 51764, serverPort: 9999, isFree: false), .inUseByOther)
        XCTAssertEqual(McpPortStatus.derive(port: 70000, serverPort: nil, isFree: true), .invalid)
        XCTAssertEqual(McpPortStatus.derive(port: 0, serverPort: nil, isFree: true), .invalid)
    }

    // MARK: tools/list parsing

    func testParseToolCountAcceptsJSONAndSSEBodiesAndRejectsErrors() {
        let plain = #"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"a"},{"name":"b"}]}}"#
        XCTAssertEqual(McpServerController.parseToolCount(from: Data(plain.utf8)), 2)
        let sse = "event: message\ndata: \(plain)\n\n"
        XCTAssertEqual(McpServerController.parseToolCount(from: Data(sse.utf8)), 2)
        XCTAssertEqual(McpServerController.parseToolCount(from: Data(#"{"error":"Unauthorized"}"#.utf8)), 0)
        XCTAssertEqual(McpServerController.parseToolCount(from: nil), 0)
    }
}
