import Foundation

// MARK: - Child process abstraction

/// The node child as the lifecycle actor sees it. Production wraps `Process`;
/// tests substitute a fake so ordering can be asserted without spawning node.
protocol McpChild: AnyObject {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    /// Ask the child to exit (SIGTERM).
    func terminate()
    /// Force the child to exit (SIGKILL).
    func kill()
}

/// `Process` adapter. Signals go to the stored pid, not through the `Process`
/// object, so they still work if the object has been released elsewhere.
final class McpProcessChild: McpChild {
    private let process: Process
    let pid: Int32

    init(_ process: Process) {
        self.process = process
        self.pid = process.processIdentifier
    }

    var isRunning: Bool { process.isRunning }
    func terminate() { if pid > 0 { Darwin.kill(pid, SIGTERM) } }
    func kill() { if pid > 0 { Darwin.kill(pid, SIGKILL) } }
}

/// What to launch.
struct McpLaunchSpec: Equatable, CustomStringConvertible {
    let nodePath: String
    let scriptPath: String
    let port: Int
    let databasePath: String
    /// Bearer token handed to the server as `CLIPPY_MCP_TOKEN`. Excluded from
    /// `description` so a logged spec never leaks it.
    let token: String

    /// Never includes the token.
    var description: String { "McpLaunchSpec(node: \(nodePath), script: \(scriptPath), port: \(port))" }

    var environmentOverrides: [String: String] {
        ["CLIPPY_MCP_PORT": "\(port)", "CLIPPY_DB_PATH": databasePath, "CLIPPY_MCP_TOKEN": token]
    }
}

/// Launches a child. `onStderrLine` and `onExit` may be called from any thread.
typealias McpLauncher = @Sendable (_ spec: McpLaunchSpec,
                                   _ onStderrLine: @escaping @Sendable (String) -> Void,
                                   _ onExit: @escaping @Sendable (Int32) -> Void) -> McpChild?

// MARK: - Lifecycle actor

/// Serializes start / stop / restart of the node child (MCP-01). Every mutation of
/// the child slot happens inside this actor, so:
///  - a stop can never run "before" the publish of a child that a start already
///    launched (the launch and the slot write are one actor-isolated step);
///  - stop kills by the stored pid and waits for exit, so a restart re-binds cleanly;
///  - each start/stop advances `generation`, which health polling checks before it
///    reports anything, so a stopped server can never be reported as running.
actor McpLifecycle {
    enum StartOutcome: Equatable {
        case started(generation: Int)
        case alreadyRunning(generation: Int)
        case launchFailed
    }

    private let launcher: McpLauncher
    private let terminationGrace: TimeInterval
    private var child: McpChild?
    private(set) var generation = 0

    init(launcher: @escaping McpLauncher, terminationGrace: TimeInterval = 2.0) {
        self.launcher = launcher
        self.terminationGrace = terminationGrace
    }

    /// Launch unless a live child already exists.
    func start(_ spec: McpLaunchSpec,
               onStderrLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int) -> Void) -> StartOutcome {
        if let child, child.isRunning { return .alreadyRunning(generation: generation) }
        child = nil
        generation += 1
        let mine = generation
        guard let launched = launcher(spec, onStderrLine, { [weak self] _ in
            // Hop back into the actor so the slot is only ever touched here.
            Task { await self?.childExited(generation: mine); onExit(mine) }
        }) else {
            return .launchFailed
        }
        child = launched
        return .started(generation: mine)
    }

    /// Terminate the child (SIGTERM, then SIGKILL after the grace period) and wait
    /// until it is gone. Always advances the generation, even with no child, so
    /// in-flight health polls are invalidated.
    func stop() async {
        generation += 1
        guard let dying = child else { return }
        child = nil
        dying.terminate()
        let deadline = Date().addingTimeInterval(terminationGrace)
        while dying.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if dying.isRunning {
            dying.kill()
            // Give the kernel a moment to reap so the port is released.
            for _ in 0..<50 where dying.isRunning {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    /// Stop, wait for exit, then start. Runs as one actor turn boundary pair: no
    /// other lifecycle call can interleave between the stop finishing and the launch
    /// unless it was already queued ahead.
    func restart(_ spec: McpLaunchSpec,
                 onStderrLine: @escaping @Sendable (String) -> Void,
                 onExit: @escaping @Sendable (Int) -> Void) async -> StartOutcome {
        await stop()
        return start(spec, onStderrLine: onStderrLine, onExit: onExit)
    }

    /// True while `generation` is the current one, i.e. no stop/start has superseded it.
    func isCurrent(_ candidate: Int) -> Bool { candidate == generation }

    /// The live child's pid, if any.
    var runningPid: Int32? {
        if let child, child.isRunning { return child.pid }
        return nil
    }

    private func childExited(generation exited: Int) {
        // Only clear when the exiting child is still the one in the slot.
        if exited == generation { child = nil }
    }
}
