import Foundation
import os

/// Run an external executable and capture its output. Used by integrations that
/// shell out (the 1Password CLI, the Claude CLI, Node.js). stdout and stderr are
/// read concurrently so a chatty process cannot deadlock on a full pipe buffer,
/// with a timeout watchdog.
enum Subprocess {
    struct Output {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let launchFailed: Bool
        /// True when the watchdog killed the process because it exceeded the timeout.
        /// On timeout, stderr falls back to "Timed out" when the process produced none,
        /// so callers that read stderr for error messages still get a useful string.
        let timedOut: Bool
        /// True when a stream hit the size ceiling and the child was killed to
        /// drain the pipe. Output is valid up to the ceiling, so it is not a failure.
        var truncated: Bool = false
        // A truncation-kill produces a SIGTERM exit status (non-zero); treat it as
        // success since the captured output is complete up to the ceiling.
        var succeeded: Bool { (exitCode == 0 || truncated) && !launchFailed }
    }

    final class Flag {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Read from a pipe file handle in chunks, stopping once `ceiling` bytes
    /// have been accumulated. When truncated, the child process is terminated
    /// so both pipes drain to EOF quickly rather than blocking indefinitely.
    /// Returns the accumulated bytes with an optional truncation marker appended.
    static func readBounded(_ handle: FileHandle,
                            ceiling: Int,
                            truncationMarker: String,
                            process: Process,
                            truncatedFlag: Flag? = nil) -> Data {
        var accumulated = Data()
        var truncated = false

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                // availableData returns empty at EOF on a pipe whose write-end is closed.
                break
            }
            accumulated.append(chunk)
            if accumulated.count >= ceiling {
                // Ceiling hit: kill the child so we reach EOF quickly on both
                // streams instead of waiting for the process to finish naturally.
                if process.isRunning { process.terminate() }
                truncated = true
                truncatedFlag?.set()
                break
            }
            // Yield briefly so the OS can schedule the child to produce more data.
            Thread.sleep(forTimeInterval: 0.001)
        }

        if truncated, let marker = truncationMarker.data(using: .utf8) {
            accumulated.append(marker)
        }
        return accumulated
    }

    /// Locate a named binary by checking well-known paths first, then falling
    /// back to a login-shell `which` probe. GUI apps launched from Finder get a
    /// stripped PATH, so the candidate list covers common Homebrew / system
    /// prefixes; the shell fallback picks up nvm, volta, asdf, and similar
    /// version managers.
    static func findBinary(named name: String, candidates: [String]) -> String? {
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Login-shell fallback
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which \(name)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            // A login shell can hang on a broken rc file; bound the probe so callers
            // (Settings install rows, the 1Password view) never spin forever.
            let deadline = Date().addingTimeInterval(5)
            while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if proc.isRunning { proc.terminate(); return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }

    /// Launch a long-lived process and return it immediately. stderr is drained
    /// concurrently via readabilityHandler (line-buffered) so the write side of
    /// the pipe never blocks. stdout is discarded by default; callers that need
    /// it should attach their own pipe before calling launch.
    ///
    /// - Parameters:
    ///   - executable: Absolute path to the binary.
    ///   - arguments: Command-line arguments.
    ///   - environment: If nil, the current process environment is inherited.
    ///   - onStderrLine: Called on each complete stderr line as it arrives.
    ///   - onExit: Called with the termination status when the process exits.
    /// - Returns: The started Process (already running).
    @discardableResult
    static func launch(executable: String,
                       arguments: [String],
                       environment: [String: String]? = nil,
                       onStderrLine: @escaping @Sendable (String) -> Void,
                       onExit: @escaping @Sendable (Int32) -> Void) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let environment { proc.environment = environment }

        proc.standardOutput = Pipe()  // discard stdout; callers attach their own if needed

        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        // Line-buffer stderr: accumulate partial lines across handler calls.
        // The readabilityHandler and terminationHandler fire on different GCD
        // threads, so all access to stderrBuffer is serialised through a lock.
        let stderrBuffer = OSAllocatedUnfairLock(initialState: "")
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            guard let chunk = String(data: handle.availableData, encoding: .utf8),
                  !chunk.isEmpty else { return }
            // Deliver every complete line; hold the last partial fragment.
            let lines = stderrBuffer.withLock { buffer -> [String] in
                buffer += chunk
                var lines = buffer.components(separatedBy: "\n")
                buffer = lines.removeLast()
                return lines
            }
            for line in lines { onStderrLine(line) }
        }

        proc.terminationHandler = { process in
            // Flush any remaining buffered stderr that arrived without a trailing newline.
            let remaining = stderrBuffer.withLock { buffer -> String in
                defer { buffer = "" }
                return buffer
            }
            if !remaining.isEmpty { onStderrLine(remaining) }
            stderrHandle.readabilityHandler = nil
            onExit(process.terminationStatus)
        }

        try? proc.run()
        return proc
    }

    static func run(_ executable: String, _ arguments: [String],
                    input: String? = nil, environment: [String: String]? = nil,
                    timeout: TimeInterval = 20) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }

                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = inPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(
                        stdout: "", stderr: error.localizedDescription,
                        exitCode: -1, launchFailed: true, timedOut: false))
                    return
                }

                // Feed stdin on a background queue so the child can drain stdout
                // while we are still writing. A synchronous write here deadlocks
                // once the input exceeds the ~64KB pipe buffer and the child has
                // started producing output before consuming all of stdin.
                let inHandle = inPipe.fileHandleForWriting
                if let input {
                    DispatchQueue.global(qos: .userInitiated).async {
                        // write(contentsOf:) throws on EPIPE (child closed stdin
                        // early) instead of raising, so an early-exiting child
                        // cannot crash us.
                        try? inHandle.write(contentsOf: Data(input.utf8))
                        try? inHandle.close()
                    }
                } else {
                    try? inHandle.close()
                }

                let timedOut = Flag()
                let truncatedFlag = Flag()
                let watchdog = DispatchWorkItem {
                    if process.isRunning { timedOut.set(); process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Hard ceiling per stream: a runaway producer (e.g. an infinite
                // loop printing to stdout) would otherwise fill RAM before the
                // timeout fires, because readDataToEndOfFile blocks until EOF.
                // Instead we read in chunks and stop accumulating once the limit
                // is reached, then terminate the child so the pipes drain quickly.
                let outputCeiling = 5 * 1024 * 1024  // 5 MB per stream
                let truncationMarker = "\n[output truncated]"

                var errData = Data()
                let errDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    errData = Self.readBounded(errPipe.fileHandleForReading,
                                               ceiling: outputCeiling,
                                               truncationMarker: truncationMarker,
                                               process: process,
                                               truncatedFlag: truncatedFlag)
                    errDone.signal()
                }
                let outData = Self.readBounded(outPipe.fileHandleForReading,
                                               ceiling: outputCeiling,
                                               truncationMarker: truncationMarker,
                                               process: process,
                                               truncatedFlag: truncatedFlag)
                errDone.wait()
                process.waitUntilExit()
                watchdog.cancel()

                let didTimeOut = timedOut.isSet
                let rawStderr = String(decoding: errData, as: UTF8.self)
                continuation.resume(returning: Output(
                    stdout: String(decoding: outData, as: UTF8.self),
                    // Keep "Timed out" fallback when the process produced no stderr,
                    // so callers that surface stderr in error messages stay useful.
                    stderr: didTimeOut && rawStderr.isEmpty ? "Timed out" : rawStderr,
                    exitCode: process.terminationStatus,
                    launchFailed: false,
                    timedOut: didTimeOut,
                    truncated: truncatedFlag.isSet))
            }
        }
    }
}
