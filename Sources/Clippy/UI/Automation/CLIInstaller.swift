import Foundation

/// Installs the bundled `clippy` CLI as a symlink. No admin prompt: tries
/// /usr/local/bin (works when writable) and falls back to ~/.local/bin.
enum CLIInstaller {
    /// Result of an install attempt.
    struct Outcome: Equatable {
        var path: String
        var onPath: Bool
        var message: String
    }

    /// The CLI inside the running app bundle.
    static var bundledCLI: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("bin/clippy")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// Candidate link locations in preference order.
    static func candidates(home: String = NSHomeDirectory()) -> [String] {
        ["/usr/local/bin/clippy", home + "/.local/bin/clippy"]
    }

    /// Whether `directory` appears in a colon-separated PATH.
    static func isOnPath(_ directory: String, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> Bool {
        path.split(separator: ":").contains { String($0) == directory }
    }

    static func install(source: URL? = bundledCLI, candidates: [String] = candidates()) -> Result<Outcome, Error> {
        guard let source else {
            return .failure(NSError(domain: "CLIInstaller", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This build does not include the command line tool (run scripts/make-app.sh)."]))
        }
        let manager = FileManager.default
        var lastError: Error?
        for target in candidates {
            let directory = (target as NSString).deletingLastPathComponent
            do {
                try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                if (try? manager.destinationOfSymbolicLink(atPath: target)) != nil { try manager.removeItem(atPath: target) }
                else if manager.fileExists(atPath: target) {
                    throw NSError(domain: "CLIInstaller", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "\(target) exists and is not a symlink; not overwriting."])
                }
                try manager.createSymbolicLink(atPath: target, withDestinationPath: source.path)
                let onPath = isOnPath(directory)
                let hint = onPath ? "Run: clippy --help"
                    : "Add to your shell profile: export PATH=\"\(directory):$PATH\""
                return .success(Outcome(path: target, onPath: onPath, message: "Installed \(target). \(hint)"))
            } catch { lastError = error }
        }
        return .failure(lastError ?? NSError(domain: "CLIInstaller", code: 3))
    }
}
