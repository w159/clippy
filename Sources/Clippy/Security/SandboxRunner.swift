import Foundation
import os

/// Whether `/usr/bin/sandbox-exec` can actually confine a process on this Mac.
enum SandboxAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }
}

/// How a script run is confined (SEC-07).
struct ScriptSandbox: Equatable {
    /// Lets the child use the network. Off unless the user approved it for this call.
    var allowNetwork = false
    /// Set only after the user explicitly agreed to run WITHOUT a sandbox because
    /// the preflight failed. Without it an unavailable sandbox refuses the run.
    var confirmedUnsandboxedFallback = false
}

/// Launches interpreters under `sandbox-exec` with a generated Seatbelt profile.
enum SandboxRunner {
    static let executablePath = "/usr/bin/sandbox-exec"

    private static let cachedAvailability = OSAllocatedUnfairLock<SandboxAvailability?>(initialState: nil)

    // MARK: Preflight

    /// Verifies `sandbox-exec` exists and that a sandboxed `true` really runs.
    /// The default-path result is cached for the process lifetime.
    static func preflight(executable: String = executablePath) -> SandboxAvailability {
        if executable == executablePath {
            return cachedAvailability.withLock { slot in
                if let hit = slot { return hit }
                let result = probe(executable: executable)
                slot = result
                return result
            }
        }
        return probe(executable: executable)
    }

    private static func probe(executable: String) -> SandboxAvailability {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .unavailable("sandbox-exec was not found at \(executable).")
        }
        let scratch: String
        do { scratch = try makeScratchDirectory() } catch {
            return .unavailable("Could not create a scratch directory: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let profile = SandboxProfile.make(options: .init(scratchDirectory: scratch))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", profile, "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return .unavailable("sandbox-exec could not start: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .unavailable("A sandboxed test command failed (exit \(process.terminationStatus)).")
        }
        return .available
    }

    /// Forgets the cached preflight (tests).
    static func resetCache() {
        cachedAvailability.withLock { $0 = nil }
    }

    // MARK: Launch construction

    /// A fresh private scratch directory, returned with symlinks resolved so the
    /// profile's `subpath` rule matches what the kernel sees (`/tmp` -> `/private/tmp`).
    static func makeScratchDirectory() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clippy-sandbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return canonicalPath(url.path)
    }

    /// `realpath(3)` result, or `path` unchanged when it cannot be resolved.
    /// Foundation's `resolvingSymlinksInPath` maps `/private/var` back to `/var`,
    /// which is not the path the sandbox kernel matches against.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Read-only locations the interpreter needs beyond the system paths: its
    /// resolved install tree (the grandparent of the real binary, e.g. a Homebrew
    /// Cellar or a version-manager directory) and the script file itself.
    static func readablePaths(interpreter: String, scriptPath: String) -> [String] {
        let real = URL(fileURLWithPath: canonicalPath(interpreter))
        let tree = real.deletingLastPathComponent().deletingLastPathComponent().path
        var paths = [real.path, canonicalPath(scriptPath)]
        if tree != "/" && !tree.isEmpty { paths.append(tree) }
        return paths
    }

    /// The `sandbox-exec` argument list that wraps `executable arguments...`.
    static func wrappedArguments(profile: String, executable: String, arguments: [String]) -> [String] {
        ["-p", profile, executable] + arguments
    }

    /// Message shown when the sandbox is required but unavailable.
    static func refusalMessage(reason: String) -> String {
        "Refused to run: the sandbox is unavailable (\(reason)) and running without it needs your explicit "
            + "confirmation. Nothing was executed."
    }
}

// MARK: - Per-script flag

/// The per-script `sandboxed` opt-in for user scripts (default off). Stored beside
/// the script model, keyed by script id, so the script file format is unchanged.
/// AI-generated code is always sandboxed and never consults this.
struct SandboxScriptFlags {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static func key(_ id: UUID) -> String { "sandbox.script.\(id.uuidString)" }

    func isSandboxed(_ id: UUID) -> Bool { defaults.bool(forKey: Self.key(id)) }

    func set(_ sandboxed: Bool, for id: UUID) {
        if sandboxed { defaults.set(true, forKey: Self.key(id)) } else { defaults.removeObject(forKey: Self.key(id)) }
    }
}
