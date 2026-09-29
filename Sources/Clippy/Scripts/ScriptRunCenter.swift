import AppKit
import Foundation

/// One script run as the UI sees it: live streamed output while it works, then
/// the final result. Shared by the panel and Settings so both surfaces show the
/// same state, and it survives either view being rebuilt.
@MainActor
final class ScriptRun: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case running
        case finished(ScriptResult)
    }

    let id = UUID()
    /// The script as it was when the run started (later edits do not affect it).
    let script: Script
    let startedAt = Date()

    @Published fileprivate(set) var phase: Phase = .running
    /// Output streamed so far, capped to the last `ScriptResult.viewCap` characters.
    @Published fileprivate(set) var liveStdout = ""
    @Published fileprivate(set) var liveStderr = ""
    /// Transient "Saved as clip" / "Could not save clip" feedback.
    @Published var saveStatus: String?

    fileprivate var task: Task<Void, Never>?

    init(script: Script) { self.script = script }

    var isRunning: Bool { phase == .running }

    var result: ScriptResult? {
        if case .finished(let result) = phase { return result }
        return nil
    }

    /// Stops the run: SIGTERM to the process group, SIGKILL after the grace period.
    func cancel() { task?.cancel() }

    /// Suspends until the run has finished and its result is recorded.
    func waitUntilFinished() async { await task?.value }

    fileprivate func append(_ stream: ScriptOutputStream, _ text: String) {
        let cap = ScriptResult.viewCap
        switch stream {
        case .stdout: liveStdout = String((liveStdout + text).suffix(cap))
        case .stderr: liveStderr = String((liveStderr + text).suffix(cap))
        }
    }
}

/// Starts and tracks script runs. The single place that turns a `Script` into a
/// running process for UI surfaces, applying the shared post-run behavior:
/// `outputToClipboard`, run history, and finishing state.
@MainActor
final class ScriptRunCenter: ObservableObject {
    static let shared = ScriptRunCenter()

    /// Latest run per script id (running or finished, until dismissed).
    @Published private(set) var runs: [UUID: ScriptRun] = [:]
    /// (finished, total) while a batch is running.
    @Published private(set) var batchProgress: (done: Int, total: Int)?

    private var batchTask: Task<Void, Never>?

    init() {}

    func run(for scriptID: UUID) -> ScriptRun? { runs[scriptID] }

    func isRunning(_ scriptID: UUID) -> Bool { runs[scriptID]?.isRunning ?? false }

    /// Starts `script` unless it is already running. `clipboardText` is read only
    /// when the script feeds the clipboard. Returns the run, or nil when one is
    /// already in flight for this script.
    @discardableResult
    func start(_ script: Script,
               sandbox: ScriptSandbox? = nil,
               history: ScriptStore = .shared,
               clipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) }) -> ScriptRun? {
        guard !isRunning(script.id) else { return nil }
        let run = ScriptRun(script: script)
        runs[script.id] = run
        let input = script.feedsClipboard ? clipboardText() : nil
        run.task = Task { [weak run] in
            let result = await ScriptRunner.run(script, input: input, sandbox: sandbox, onOutput: { stream, text in
                Task { @MainActor in run?.append(stream, text) }
            })
            guard let run else { return }
            // Behavior every surface shares, applied before the UI shows the result.
            if script.outputToClipboard, result.succeeded, !result.stdout.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(result.stdout, forType: .string)
            }
            history.recordRun(scriptID: script.id, startedAt: run.startedAt, result: result)
            run.phase = .finished(result)
        }
        return run
    }

    /// Runs `scripts` one after another (each still goes through `start`, so
    /// output, history and clipboard behavior are identical). Cancelling the
    /// batch stops the current run and skips the rest.
    func startBatch(_ scripts: [Script], history: ScriptStore = .shared) {
        guard batchTask == nil, !scripts.isEmpty else { return }
        batchProgress = (0, scripts.count)
        batchTask = Task { [weak self] in
            for (index, script) in scripts.enumerated() {
                if Task.isCancelled { break }
                guard let self else { return }
                let sandbox = ScriptSandboxPolicy().sandbox(for: script.id)
                if let run = self.start(script, sandbox: sandbox, history: history) {
                    await withTaskCancellationHandler(
                        operation: { await run.waitUntilFinished() },
                        onCancel: { Task { @MainActor in run.cancel() } })
                }
                self.batchProgress = (index + 1, scripts.count)
            }
            self?.batchProgress = nil
            self?.batchTask = nil
        }
    }

    func cancelBatch() { batchTask?.cancel() }

    var isBatchRunning: Bool { batchTask != nil }

    /// Forgets a finished run (the Dismiss button).
    func dismiss(_ scriptID: UUID) {
        guard let run = runs[scriptID], !run.isRunning else { return }
        runs[scriptID] = nil
    }
}
