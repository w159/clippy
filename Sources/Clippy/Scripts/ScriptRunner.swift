import Foundation
import Darwin
import os

/// Which pipe a streamed chunk of output came from.
enum ScriptOutputStream: Equatable {
    case stdout
    case stderr
}

/// A resolved interpreter: the executable to spawn, the arguments that precede
/// the script path, and the PATH the child will see.
struct ScriptLaunchPlan: Equatable {
    var executable: String
    var leadingArgs: [String]
    var searchPath: String
}

/// A run that cannot start, described for the user. `message` is shown verbatim
/// in the editor's preflight row and in the run result.
struct ScriptPreflightError: Error, Equatable {
    var message: String
}

// MARK: - Interpreter lookup names

extension ScriptInterpreter {
    /// Absolute path for interpreters that ship with macOS and never move.
    var fixedExecutable: String? {
        switch self {
        case .zsh: return "/bin/zsh"
        case .bash: return "/bin/bash"
        case .sh: return "/bin/sh"
        case .applescript: return "/usr/bin/osascript"
        case .python3, .node, .ruby, .swift: return nil
        }
    }

    /// Binary name looked up on PATH for everything that is not fixed.
    var searchName: String? {
        switch self {
        case .python3: return "python3"
        case .node: return "node"
        case .ruby: return "ruby"
        case .swift: return "swift"
        case .zsh, .bash, .sh, .applescript: return nil
        }
    }
}

// MARK: - Login-shell PATH

/// The PATH a Terminal session would have. A Finder-launched app gets a stripped
/// PATH, so Homebrew, asdf, volta and friends are invisible without this.
enum LoginShellPath {
    private static let cached = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Directories that commonly hold version-manager and Homebrew binaries,
    /// appended after the probed PATH so the user's own ordering wins.
    static var wellKnownDirectories: [String] {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
                "\(home)/.asdf/shims", "\(home)/.volta/bin", "\(home)/.local/bin",
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    /// Joins PATH strings, dropping empty and duplicate entries, keeping order.
    static func merge(_ paths: [String]) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
                let dirText = String(dir)
                if seen.insert(dirText).inserted { result.append(dirText) }
            }
        }
        return result.joined(separator: ":")
    }

    /// The merged search path, probing the login shell once per app run. Blocks
    /// for up to `timeout` seconds on the first call, so call it off the main
    /// thread.
    static func current(timeout: TimeInterval = 3) -> String {
        if let hit = cached.withLock({ $0 }) { return hit }
        let probed = probe(timeout: timeout) ?? ""
        let merged = merge([probed,
                            ProcessInfo.processInfo.environment["PATH"] ?? "",
                            wellKnownDirectories.joined(separator: ":")])
        cached.withLock { $0 = merged }
        return merged
    }

    /// Runs `zsh -l -c 'printf %s "$PATH"'` with a hard timeout.
    private static func probe(timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - Runner

/// Runs a stored script in its own process group and captures its output.
/// Executing a script is powerful; the UI confirms before calling this.
///
/// The child is spawned with `posix_spawn` as the leader of a new process group
/// so a timeout or cancel can signal the whole tree (`killpg`): SIGTERM first,
/// then SIGKILL after a grace period for anything that traps or ignores it.
enum ScriptRunner {

    /// Per-stream capture ceiling; the child is stopped when a stream hits it.
    static let outputCeiling = 5 * 1024 * 1024
    /// `CLIPPY_CLIP` carries at most this many bytes. The full clip always
    /// arrives on stdin, and via `CLIPPY_CLIP_FILE` when it exceeds the cap.
    static let clipEnvironmentCap = 32 * 1024
    /// Seconds between SIGTERM and SIGKILL.
    static let defaultGracePeriod: TimeInterval = 2

    // MARK: Public API

    /// - Parameters:
    ///   - input: text for stdin (the active clip); wins over `script.stdinText`.
    ///   - timeout: seconds; nil uses `script.timeoutSeconds`; 0 disables it.
    ///   - gracePeriod: seconds between SIGTERM and SIGKILL.
    ///   - searchPath: PATH override for interpreter lookup and the child; nil
    ///     probes the user's login shell (cached).
    ///   - onOutput: called from a background thread with each decoded chunk.
    static func run(_ script: Script,
                    input: String? = nil,
                    timeout: TimeInterval? = nil,
                    gracePeriod: TimeInterval = ScriptRunner.defaultGracePeriod,
                    searchPath: String? = nil,
                    sandbox: ScriptSandbox? = nil,
                    onOutput: (@Sendable (ScriptOutputStream, String) -> Void)? = nil) async -> ScriptResult {
        let result = await runUnaudited(script, input: input, timeout: timeout, gracePeriod: gracePeriod,
                                        searchPath: searchPath, sandbox: sandbox, onOutput: onOutput)
        auditRun(script, sandbox: sandbox, result: result)
        return result
    }

    /// SEC-08: one audit entry per run. Records the script id, whether it was
    /// sandboxed and the exit outcome; never the body, input or output.
    private static func auditRun(_ script: Script, sandbox: ScriptSandbox?, result: ScriptResult) {
        let outcome: String
        if result.launchFailed { outcome = "launch-failed" }
        else if result.cancelled { outcome = "cancelled" }
        else if result.timedOut { outcome = "timed-out" }
        else { outcome = "exit \(result.exitCode)" }
        let confined = sandbox != nil && !(sandbox?.confirmedUnsandboxedFallback ?? false)
        AuditLog.shared.record(actor: "script", action: "script.run",
                               detail: "id=\(script.id.uuidString) name=\(script.name) sandboxed=\(confined) "
                                   + "network=\(sandbox?.allowNetwork ?? true) outcome=\(outcome)",
                               clipIDs: [])
    }

    private static func runUnaudited(_ script: Script,
                                     input: String?,
                                     timeout: TimeInterval?,
                                     gracePeriod: TimeInterval,
                                     searchPath: String?,
                                     sandbox: ScriptSandbox?,
                                     onOutput: (@Sendable (ScriptOutputStream, String) -> Void)?) async -> ScriptResult {
        if Task.isCancelled {
            return ScriptResult(stdout: "", stderr: "Cancelled", exitCode: -1,
                                durationMs: 0, timedOut: false, cancelled: true)
        }

        // The single chokepoint for the disabled flag. Scripts can be created
        // over MCP by anything connected to it, so "can this run?" is enforced
        // here, where every caller (Settings, panel, AI tool) already funnels,
        // rather than in each of them.
        guard script.isEnabled else {
            ClippyLog.warning("Refused to run disabled script '\(script.name)'",
                              category: ClippyLog.scripts)
            return failedLaunch("This script is disabled. Enable it in Settings > Scripts to run it.")
        }

        let start = Date()
        let effectiveTimeout = timeout ?? TimeInterval(script.timeoutSeconds)
        let control = RunControl(grace: gracePeriod)

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<ScriptResult, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = execute(script, input: input, timeout: effectiveTimeout,
                                         searchPath: searchPath, sandbox: sandbox, control: control,
                                         start: start, onOutput: onOutput)
                    continuation.resume(returning: result)
                }
            }
        }, onCancel: {
            control.request(.cancelled)
        })
    }

    /// Checks everything that would stop a run from starting, without running
    /// anything. Returns a message for the editor's preflight row, or nil when
    /// the script is ready. Blocks on the first login-shell probe.
    static func preflight(_ script: Script, searchPath: String? = nil) -> String? {
        if case .failure(let error) = resolveLaunch(for: script, searchPath: searchPath) {
            return error.message
        }
        if let error = workingDirectoryError(script.workingDirectory) { return error.message }
        return nil
    }

    // MARK: Interpreter resolution (SCR-03)

    /// Resolves the executable for `script`: the per-script override, then a
    /// fixed system path, then PATH lookup (login-shell PATH unless injected),
    /// then `Subprocess.findBinary` as the last resort.
    static func resolveLaunch(for script: Script, searchPath: String? = nil)
        -> Result<ScriptLaunchPlan, ScriptPreflightError> {
        let custom = script.customInterpreterPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = searchPath ?? LoginShellPath.current()

        if !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            guard isExecutableFile(expanded) else {
                return .failure(.init(message: "Custom interpreter not found or not executable: \(custom)"))
            }
            return .success(.init(executable: expanded, leadingArgs: [], searchPath: path))
        }

        if let fixed = script.interpreter.fixedExecutable {
            guard isExecutableFile(fixed) else {
                return .failure(.init(message: "\(script.interpreter.displayName) is not available at \(fixed)."))
            }
            return .success(.init(executable: fixed, leadingArgs: [], searchPath: path))
        }

        let name = script.interpreter.searchName ?? script.interpreter.rawValue
        if let found = find(name, in: path) {
            return .success(.init(executable: found, leadingArgs: [], searchPath: path))
        }
        // Only the real environment falls back to the shell-based lookup; an
        // injected PATH means the caller wants a closed-world answer.
        if searchPath == nil,
           let found = Subprocess.findBinary(named: name, candidates: []) {
            return .success(.init(executable: found, leadingArgs: [], searchPath: path))
        }
        return .failure(.init(message: "\(script.interpreter.displayName) (\(name)) was not found on your PATH. "
            + "Install it, or set a custom interpreter path in the script's options."))
    }

    /// First executable regular file called `name` in the colon-separated `path`.
    static func find(_ name: String, in path: String) -> String? {
        for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = String(dir) + "/" + name
            if isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && !isDir.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    /// nil when `directory` is empty (home is used) or an existing directory.
    static func workingDirectoryError(_ directory: String) -> ScriptPreflightError? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var isDir: ObjCBool = false
        let expanded = (trimmed as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue { return nil }
        return .init(message: "Working directory does not exist: \(trimmed)")
    }

    // MARK: Temp files and input (SCR-11)

    /// A fresh path per run, so concurrent runs of one script never collide.
    static func makeTempURL(for script: Script, pathExtension: String? = nil) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "clippy-\(script.id.uuidString)-\(UUID().uuidString).\(pathExtension ?? script.interpreter.fileExtension)")
    }

    /// Writes `contents` with owner-only permissions.
    private static func writePrivateFile(_ contents: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: contents,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// `text` cut to at most `maxBytes` of UTF-8 without splitting a character.
    static func cappedUTF8(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var end = maxBytes
        let bytes = Array(text.utf8)
        // Step back over continuation bytes so the cut lands on a boundary.
        while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }

    // MARK: Execution

    private static func failedLaunch(_ message: String, start: Date? = nil) -> ScriptResult {
        ScriptResult(stdout: "", stderr: message, exitCode: -1,
                     durationMs: start.map { ms(since: $0) } ?? 0, timedOut: false, launchFailed: true)
    }

    /// Blocking body of a run; always called on a background queue.
    private static func execute(_ script: Script, input: String?, timeout: TimeInterval,
                                searchPath: String?, sandbox: ScriptSandbox?,
                                control: RunControl, start: Date,
                                onOutput: (@Sendable (ScriptOutputStream, String) -> Void)?) -> ScriptResult {
        let plan: ScriptLaunchPlan
        switch resolveLaunch(for: script, searchPath: searchPath) {
        case .success(let resolved): plan = resolved
        case .failure(let error): return failedLaunch(error.message, start: start)
        }
        if let error = workingDirectoryError(script.workingDirectory) {
            return failedLaunch(error.message, start: start)
        }
        if control.reason == .cancelled {
            return ScriptResult(stdout: "", stderr: "Cancelled", exitCode: -1,
                                durationMs: ms(since: start), timedOut: false, cancelled: true)
        }

        // Script body -> unique 0600 file, removed when the run ends.
        let scriptURL = makeTempURL(for: script)
        do {
            try writePrivateFile(Data(script.body.utf8), to: scriptURL)
        } catch {
            return failedLaunch("Could not write script file: \(error.localizedDescription)", start: start)
        }
        var cleanup = [scriptURL]
        defer { for url in cleanup { try? FileManager.default.removeItem(at: url) } }

        // stdin: the clip when given, else the script's own custom stdin.
        let stdinText = input ?? (script.stdinText.isEmpty ? nil : script.stdinText)

        // Environment: inherited, then PATH, then user variables, then the
        // reserved CLIPPY_* names (which a script's own variables cannot spoof).
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = plan.searchPath
        for (key, value) in script.environment where !key.hasPrefix("CLIPPY_") { env[key] = value }
        if let input {
            env["CLIPPY_CLIP"] = cappedUTF8(input, maxBytes: clipEnvironmentCap)
            if input.utf8.count > clipEnvironmentCap {
                env["CLIPPY_CLIP_TRUNCATED"] = "1"
                let clipURL = makeTempURL(for: script, pathExtension: "clip")
                do {
                    try writePrivateFile(Data(input.utf8), to: clipURL)
                    cleanup.append(clipURL)
                    env["CLIPPY_CLIP_FILE"] = clipURL.path
                } catch {
                    return failedLaunch("Could not write clip file: \(error.localizedDescription)", start: start)
                }
            }
        }

        let cwdSetting = script.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        var cwd = cwdSetting.isEmpty ? NSHomeDirectory() : (cwdSetting as NSString).expandingTildeInPath

        // SEC-07: confine the child with sandbox-exec. An unavailable sandbox
        // refuses the run unless the caller carries explicit confirmation.
        var launchExecutable = plan.executable
        var launchArguments = plan.leadingArgs + [scriptURL.path] + script.arguments
        if let sandbox {
            switch SandboxRunner.preflight() {
            case .unavailable(let reason):
                guard sandbox.confirmedUnsandboxedFallback else {
                    return failedLaunch(SandboxRunner.refusalMessage(reason: reason), start: start)
                }
            case .available:
                let scratch: String
                do { scratch = try SandboxRunner.makeScratchDirectory() } catch {
                    return failedLaunch("Could not create sandbox scratch directory: \(error.localizedDescription)",
                                        start: start)
                }
                defer { try? FileManager.default.removeItem(atPath: scratch) }
                var readable = SandboxRunner.readablePaths(interpreter: plan.executable, scriptPath: scriptURL.path)
                if let clipFile = env["CLIPPY_CLIP_FILE"] { readable.append(clipFile) }
                let profile = SandboxProfile.make(options: .init(scratchDirectory: scratch,
                                                                 readablePaths: readable,
                                                                 allowNetwork: sandbox.allowNetwork))
                launchArguments = SandboxRunner.wrappedArguments(profile: profile, executable: plan.executable,
                                                                 arguments: launchArguments)
                launchExecutable = SandboxRunner.executablePath
                env["TMPDIR"] = scratch + "/"
                cwd = scratch
                let launch = ChildLaunch(executable: launchExecutable, arguments: launchArguments, env: env,
                                         cwd: cwd, stdinText: stdinText, timeout: timeout)
                return runChild(launch, control: control, start: start, onOutput: onOutput)
            }
        }
        let launch = ChildLaunch(executable: launchExecutable, arguments: launchArguments, env: env,
                                 cwd: cwd, stdinText: stdinText, timeout: timeout)
        return runChild(launch, control: control, start: start, onOutput: onOutput)
    }

    /// Everything needed to launch one child process.
    private struct ChildLaunch {
        let executable: String
        let arguments: [String]
        let env: [String: String]
        let cwd: String
        let stdinText: String?
        let timeout: TimeInterval
    }

    /// Spawns and supervises one child: streams, timeout, reaping, result.
    private static func runChild(_ launch: ChildLaunch, control: RunControl, start: Date,
                                 onOutput: (@Sendable (ScriptOutputStream, String) -> Void)?) -> ScriptResult {
        let executable = launch.executable
        let timeout = launch.timeout
        let stdinText = launch.stdinText
        let child: SpawnedChild
        do {
            child = try spawn(executable: executable, arguments: launch.arguments,
                              environment: launch.env, directory: launch.cwd)
        } catch {
            return failedLaunch("Could not start \(executable): \(error.localizedDescription)", start: start)
        }
        control.attach(pid: child.pid)

        if timeout > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { control.request(.timedOut) }
        }

        // stdin writer: off-thread so the child can drain stdout meanwhile.
        if let text = stdinText {
            DispatchQueue.global(qos: .userInitiated).async {
                writeAll(Data(text.utf8), to: child.stdinFD)
                close(child.stdinFD)
            }
        } else {
            close(child.stdinFD)
        }

        let stop = RunFlag()
        let readers = DispatchGroup()
        var outData = Data(), errData = Data()
        let outDecoder = UTF8StreamDecoder(), errDecoder = UTF8StreamDecoder()
        for (descriptor, stream) in [(child.stdoutFD, ScriptOutputStream.stdout), (child.stderrFD, .stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pump(fd: descriptor, ceiling: outputCeiling, control: control, stop: stop) { chunk in
                    guard let onOutput else { return }
                    let decoder = stream == .stdout ? outDecoder : errDecoder
                    let text = decoder.decode(chunk)
                    if !text.isEmpty { onOutput(stream, text) }
                }
                // Distinct variables per stream; written once, read after wait.
                if stream == .stdout { outData = data } else { errData = data }
                readers.leave()
            }
        }

        // Reap the leader, then let the readers finish what is already in the
        // pipes. A backgrounded grandchild that keeps a pipe open cannot hang us.
        var status: Int32 = 0
        while waitpid(child.pid, &status, 0) == -1 {
            if errno != EINTR { status = 0; break }
        }
        control.markExited()
        stop.set()
        readers.wait()

        let truncated = control.truncated
        let reason = control.reason
        let signal = status & 0x7f
        let exitCode: Int32 = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        var stderrText = String(decoding: errData, as: UTF8.self)
        if stderrText.isEmpty {
            if reason == .cancelled { stderrText = "Cancelled" }
            else if reason == .timedOut { stderrText = "Timed out" }
        }
        return ScriptResult(stdout: String(decoding: outData, as: UTF8.self),
                            stderr: stderrText,
                            exitCode: exitCode,
                            durationMs: ms(since: start),
                            timedOut: reason == .timedOut,
                            truncated: truncated,
                            cancelled: reason == .cancelled,
                            launchFailed: false,
                            terminationSignal: signal == 0 ? nil : signal)
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - Termination control (SCR-05)

/// Owns the "stop this run" state: why it was stopped, and the SIGTERM ->
/// SIGKILL escalation against the child's process group. Every signal is sent
/// under the lock and only while the leader is unreaped, so a recycled pid is
/// never signalled.
final class RunControl: @unchecked Sendable {
    enum Reason: Equatable { case cancelled, timedOut, truncated }

    private let lock = NSLock()
    private let grace: TimeInterval
    private var pid: pid_t = 0
    private var exited = false
    private var signalled = false
    private var storedReason: Reason?
    private var storedTruncated = false

    init(grace: TimeInterval) { self.grace = grace }

    /// First cause wins; output truncation is tracked separately so it never
    /// masks a timeout or cancel.
    var reason: Reason? {
        lock.lock(); defer { lock.unlock() }
        return storedReason == .truncated ? nil : storedReason
    }

    var truncated: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedTruncated
    }

    /// Called right after spawn; delivers a stop request that arrived earlier.
    func attach(pid: pid_t) {
        lock.lock()
        self.pid = pid
        let pending = storedReason != nil
        lock.unlock()
        if pending { signalGroup() }
    }

    /// Called once the leader has been reaped. If the run was being stopped,
    /// sweep any stragglers in the group right away (the pgid is still ours).
    func markExited() {
        lock.lock()
        exited = true
        let sweep = signalled && pid > 0
        let group = pid
        lock.unlock()
        if sweep { killpg(group, SIGKILL) }
    }

    func request(_ reason: Reason) {
        lock.lock()
        if reason == .truncated {
            storedTruncated = true
        } else if storedReason == nil || storedReason == .truncated {
            storedReason = reason
        }
        let attached = pid > 0
        lock.unlock()
        if attached { signalGroup() }
    }

    private func signalGroup() {
        lock.lock()
        guard !signalled, !exited, pid > 0 else { lock.unlock(); return }
        signalled = true
        let group = pid
        killpg(group, SIGTERM)
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            lock.lock()
            if !exited { killpg(group, SIGKILL) }
            lock.unlock()
        }
    }
}

// MARK: - Small helpers

/// A thread-safe boolean latch.
final class RunFlag {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Decodes UTF-8 arriving in arbitrary chunks, holding back an incomplete
/// trailing character until its remaining bytes arrive.
final class UTF8StreamDecoder {
    private var pending = Data()

    func decode(_ chunk: Data) -> String {
        pending.append(chunk)
        var end = pending.count
        // Back up to before an incomplete multi-byte sequence at the tail.
        var back = 0
        while back < 4, end - back > 0 {
            let byte = pending[pending.startIndex + end - back - 1]
            if byte & 0xC0 == 0x80 { back += 1; continue }        // continuation
            if byte >= 0xC0 {
                let needed = byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : 2)
                if back + 1 < needed { end -= back + 1 }
            }
            break
        }
        let complete = pending.prefix(end)
        pending = Data(pending.dropFirst(end))
        return String(decoding: complete, as: UTF8.self)
    }
}
