import Foundation

/// Runs a stored script in a subprocess and captures its output. Executing a
/// script is powerful; the UI confirms before calling this.
///
/// Cancellation: `run` is launched from a `Task` the UI holds a handle to, so a
/// Cancel button can call `task.cancel()`. We own the `Process` here (rather than
/// delegating to `Subprocess.run`) so cancellation can terminate the child
/// promptly instead of waiting for the 30s timeout. The bounded-read and Flag
/// helpers from `Subprocess` are reused to keep the pipe-handling logic single-
/// sourced; only the launch orchestration is mirrored here with a cancellation
/// watcher added.
enum ScriptRunner {

    static func run(_ script: Script, input: String? = nil,
                    timeout: TimeInterval = 30) async -> ScriptResult {
        // Honor a cancel that arrived before any work started.
        if Task.isCancelled {
            return ScriptResult(stdout: "", stderr: "Cancelled",
                                exitCode: -1, durationMs: 0, timedOut: false)
        }

        // Clock starts before the temp-file write so durationMs includes that
        // overhead, consistent with the original behavior.
        let start = Date()

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-\(script.id.uuidString).\(script.interpreter.fileExtension)")
        do {
            try script.body.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return ScriptResult(stdout: "", stderr: "Could not write script file: \(error.localizedDescription)",
                                exitCode: -1, durationMs: 0, timedOut: false)
        }

        defer { try? FileManager.default.removeItem(at: file) }

        // Build a fully-merged environment: inherit the parent process env so
        // the interpreter can locate system tools, then inject CLIPPY_CLIP.
        // Subprocess.run replaces the environment entirely when given a non-nil
        // dict, so the full merge must happen here rather than relying on
        // inheritance.
        var env = ProcessInfo.processInfo.environment
        if let input { env["CLIPPY_CLIP"] = input }

        let (exe, leadingArgs) = script.interpreter.launch

        // Cancellation bridge: withTaskCancellationHandler fires onCancel on the
        // Task that awaits this call. The watcher below polls this flag so a
        // Cancel click terminates the child without waiting for the timeout.
        let cancelFlag = Subprocess.Flag()

        return await withTaskCancellationHandler(operation: {
            await Self.launchAndCollect(
                executable: exe,
                arguments: leadingArgs + [file.path],
                environment: env,
                input: input,
                timeout: timeout,
                cancelFlag: cancelFlag,
                start: start
            )
        }, onCancel: {
            cancelFlag.set()
        })
    }

    /// Launches the process, reads stdout/stderr concurrently up to the size
    /// ceiling, and returns the result. Mirrors Subprocess.run but owns the
    /// Process so cancellation (via `cancelFlag`) can terminate it mid-run.
    private static func launchAndCollect(
        executable: String,
        arguments: [String],
        environment: [String: String],
        input: String?,
        timeout: TimeInterval,
        cancelFlag: Subprocess.Flag,
        start: Date
    ) async -> ScriptResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ScriptResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment

                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = inPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ScriptResult(
                        stdout: "", stderr: error.localizedDescription,
                        exitCode: -1, durationMs: Self.ms(since: start), timedOut: false))
                    return
                }

                // Feed stdin on a background queue so the child can drain stdout
                // while we are still writing (mirrors Subprocess.run).
                let inHandle = inPipe.fileHandleForWriting
                if let input {
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? inHandle.write(contentsOf: Data(input.utf8))
                        try? inHandle.close()
                    }
                } else {
                    try? inHandle.close()
                }

                let timedOut = Subprocess.Flag()
                let truncatedFlag = Subprocess.Flag()
                let outputCeiling = 5 * 1024 * 1024  // 5 MB per stream
                let truncationMarker = "\n[output truncated]"

                // Timeout watchdog: terminate the child if it exceeds the limit.
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut.set()
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Cancellation watcher: polls the cancel flag (set by the Task
                // cancellation handler) and terminates the child promptly. The
                // checked continuation Subprocess.run uses does not observe
                // Task.isCancelled, which is why we own the Process here.
                let watcher = DispatchWorkItem {
                    while process.isRunning {
                        if cancelFlag.isSet {
                            if process.isRunning { process.terminate() }
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
                DispatchQueue.global().async(execute: watcher)

                var errData = Data()
                let errDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    errData = Subprocess.readBounded(
                        errPipe.fileHandleForReading,
                        ceiling: outputCeiling,
                        truncationMarker: truncationMarker,
                        process: process,
                        truncatedFlag: truncatedFlag)
                    errDone.signal()
                }
                let outData = Subprocess.readBounded(
                    outPipe.fileHandleForReading,
                    ceiling: outputCeiling,
                    truncationMarker: truncationMarker,
                    process: process,
                    truncatedFlag: truncatedFlag)
                errDone.wait()
                process.waitUntilExit()
                watchdog.cancel()
                watcher.cancel()

                let didTimeOut = timedOut.isSet
                let didCancel = cancelFlag.isSet
                let rawStderr = String(decoding: errData, as: UTF8.self)
                let stderr = didCancel
                    ? "Cancelled"
                    : (didTimeOut && rawStderr.isEmpty ? "Timed out" : rawStderr)

                continuation.resume(returning: ScriptResult(
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: stderr,
                    exitCode: process.terminationStatus,
                    durationMs: Self.ms(since: start),
                    timedOut: didTimeOut,
                    truncated: truncatedFlag.isSet))
            }
        }
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}