import Foundation

/// Generates the Seatbelt (`sandbox-exec`) profile text for a sandboxed run (SEC-07).
///
/// The profile is a pure function of its options so its text can be unit tested.
/// Policy: everything is denied by default; the child may execute programs, read
/// system locations and the interpreter's own tree, and write only inside the
/// per-run scratch directory. Network access is denied unless `allowNetwork` is set.
enum SandboxProfile {

    /// Inputs to `make(options:)`.
    struct Options: Equatable {
        /// Per-run scratch directory: the only writable location (besides /dev/null).
        var scratchDirectory: String
        /// Extra read-only locations: the interpreter's install tree, the script file.
        var readablePaths: [String] = []
        /// When false (the default) the profile contains no network rule at all.
        var allowNetwork: Bool = false
    }

    /// System locations every interpreter needs to read. Deliberately excludes
    /// `/Users` so a sandboxed run cannot read the user's documents or keys.
    static let systemReadPaths = [
        "/usr", "/bin", "/sbin", "/System", "/Library", "/private/etc",
        "/private/var/db", "/private/var/select", "/dev", "/opt/homebrew", "/usr/local",
        "/Applications/Xcode.app",
    ]

    /// Escapes `value` for use inside a Seatbelt double-quoted string. Control
    /// characters (which could break out of the rule line) are dropped.
    static func escape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The Seatbelt profile text for `options`.
    static func make(options: Options) -> String {
        func subpath(_ path: String) -> String { "(subpath \"\(escape(path))\")" }
        let reads = (systemReadPaths + options.readablePaths + [options.scratchDirectory])
            .map(subpath).joined(separator: " ")

        var lines = [
            "(version 1)",
            "(deny default)",
            "(allow process-exec*)",
            "(allow process-fork)",
            "(allow signal (target self))",
            "(allow sysctl-read)",
            "(allow mach-lookup)",
            "(allow file-read-metadata)",
            // The root directory itself must be readable or dyld aborts the child.
            "(allow file-read* (literal \"/\") \(reads))",
            "(allow file-write* (literal \"/dev/null\") (literal \"/dev/dtracehelper\") \(subpath(options.scratchDirectory)))",
        ]
        if options.allowNetwork {
            lines.append("(allow network*)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
