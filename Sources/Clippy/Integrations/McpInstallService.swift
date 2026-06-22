import Foundation

// MARK: - MCP client targets

enum McpClient: String, CaseIterable, Identifiable {
    case claudeDesktop
    case claudeCode
    case vscode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .claudeCode:    return "Claude Code"
        case .vscode:        return "VS Code (GitHub Copilot)"
        }
    }
}

// MARK: - Install service

enum McpInstallService {

    // MARK: Install

    /// Write (or merge) the Clippy MCP entry for the given client.
    /// Idempotent: calling twice leaves one entry. Existing servers are preserved.
    /// Async so the caller can run it off the main thread (audit finding: the old
    /// sync path blocked a background thread on a DispatchSemaphore to bridge the
    /// async subprocess API; we now surface the async API directly).
    static func install(_ client: McpClient, port: Int) async -> Result<String, Error> {
        switch client {
        case .claudeDesktop: return installClaudeDesktop(port: port)
        case .claudeCode:    return await installClaudeCode(port: port)
        case .vscode:        return installVSCode(port: port)
        }
    }

    // MARK: Uninstall

    /// Remove the Clippy MCP entry for the given client. Idempotent: a missing
    /// entry is reported as success with a "not installed" note. Audit finding:
    /// there was no uninstall path.
    static func remove(_ client: McpClient) async -> Result<String, Error> {
        switch client {
        case .claudeDesktop: return removeServer(name: "clippy", topKey: "mcpServers",
                                                  fileURL: claudeDesktopConfigURL,
                                                  successMessage: "Removed from \(claudeDesktopConfigURL.path). Restart Claude Desktop to apply.")
        case .claudeCode:    return await removeClaudeCode()
        case .vscode:        return removeServer(name: "clippy", topKey: "servers",
                                                  fileURL: vscodeConfigURL,
                                                  successMessage: "Removed from \(vscodeConfigURL.path). Reload VS Code to apply.")
        }
    }

    // MARK: Is installed

    /// Best-effort check that a "clippy" entry already exists for the client.
    /// Async so the Claude Code probe can run `claude mcp list` through the
    /// async subprocess API without pinning a thread on a semaphore (audit
    /// finding). The SettingsView probe loop already runs in a Task.detached,
    /// so awaiting here is natural.
    static func isInstalled(_ client: McpClient) async -> Bool {
        switch client {
        case .claudeDesktop: return checkClaudeDesktop()
        case .claudeCode:    return await checkClaudeCode()
        case .vscode:        return checkVSCode()
        }
    }

    // MARK: - Claude Desktop

    private static var claudeDesktopConfigURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Claude/claude_desktop_config.json")
    }

    private static func installClaudeDesktop(port: Int) -> Result<String, Error> {
        let url = claudeDesktopConfigURL
        // Claude Desktop is stdio-only; mcp-remote bridges to our HTTP endpoint.
        let entry: [String: Any] = [
            "command": "npx",
            "args": ["-y", "mcp-remote", "http://127.0.0.1:\(port)/mcp"]
        ]
        return mergeServer(name: "clippy", entry: entry, topKey: "mcpServers", fileURL: url,
                           successMessage: "Registered in \(url.path). Restart Claude Desktop to apply.")
    }

    private static func checkClaudeDesktop() -> Bool {
        hasMcpEntry(name: "clippy", topKey: "mcpServers", fileURL: claudeDesktopConfigURL)
    }

    // MARK: - VS Code

    private static var vscodeConfigURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Code/User/mcp.json")
    }

    private static func installVSCode(port: Int) -> Result<String, Error> {
        let url = vscodeConfigURL
        // VS Code Copilot uses type/url shape under "servers" (not mcpServers)
        let entry: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/mcp"
        ]
        return mergeServer(name: "clippy", entry: entry, topKey: "servers", fileURL: url,
                           successMessage: "Registered in \(url.path). Reload VS Code to apply.")
    }

    private static func checkVSCode() -> Bool {
        hasMcpEntry(name: "clippy", topKey: "servers", fileURL: vscodeConfigURL)
    }

    // MARK: - Claude Code

    private static var claudeCodeConfigURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude.json")
    }

    private static func installClaudeCode(port: Int) async -> Result<String, Error> {
        // Prefer the CLI: claude mcp add --transport http clippy <url> -s user
        if let claudePath = findClaudeBinary() {
            let result = await runCLI(claudePath, args: [
                "mcp", "add",
                "--transport", "http",
                "clippy",
                "http://127.0.0.1:\(port)/mcp",
                "-s", "user"
            ])
            switch result {
            case .success(let output):
                let msg = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return .success(msg.isEmpty ? "Registered with Claude Code (user scope)." : msg)
            case .failure:
                break // fall through to JSON fallback
            }
        }

        // Fallback: merge directly into ~/.claude.json
        let url = claudeCodeConfigURL
        let entry: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/mcp"
        ]
        return mergeServer(name: "clippy", entry: entry, topKey: "mcpServers", fileURL: url,
                           successMessage: "Registered in \(url.path). Restart Claude Code to apply.")
    }

    private static func removeClaudeCode() async -> Result<String, Error> {
        // Prefer the CLI: claude mcp remove clippy -s user
        if let claudePath = findClaudeBinary() {
            let result = await runCLI(claudePath, args: ["mcp", "remove", "clippy", "-s", "user"])
            switch result {
            case .success(let output):
                let msg = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return .success(msg.isEmpty ? "Removed from Claude Code (user scope)." : msg)
            case .failure:
                break // fall through to JSON fallback
            }
        }
        return removeServer(name: "clippy", topKey: "mcpServers", fileURL: claudeCodeConfigURL,
                            successMessage: "Removed from \(claudeCodeConfigURL.path). Restart Claude Code to apply.")
    }

    private static func checkClaudeCode() async -> Bool {
        // Try claude mcp list first through the async subprocess API.
        if let claudePath = findClaudeBinary(),
           case .success(let output) = await runCLI(claudePath, args: ["mcp", "list"]),
           output.contains("clippy") {
            return true
        }
        return hasMcpEntry(name: "clippy", topKey: "mcpServers", fileURL: claudeCodeConfigURL)
    }

    // MARK: - Claude binary lookup

    private static func findClaudeBinary() -> String? {
        Subprocess.findBinary(named: "claude", candidates: [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ])
    }

    // MARK: - CLI runner

    /// Async subprocess runner. Audit finding: the old runCLI blocked a thread
    /// on a DispatchSemaphore to bridge the async Subprocess.run into a sync
    /// Result; we now expose the async API directly so install/uninstall callers
    /// can await it without pinning a thread.
    private static func runCLI(_ path: String, args: [String]) async -> Result<String, Error> {
        let output = await Subprocess.run(path, args)
        if output.succeeded {
            return .success(output.stdout)
        }
        return .failure(McpInstallError.cliFailed(output.stderr))
    }

    // MARK: - JSON merge/remove helpers

    /// Read the file (or start with empty dict), merge serverName under topKey,
    /// write back as pretty-printed JSON.
    private static func mergeServer(
        name: String,
        entry: [String: Any],
        topKey: String,
        fileURL: URL,
        successMessage: String
    ) -> Result<String, Error> {
        do {
            // Ensure parent directory exists
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var root: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: fileURL.path),
               let data = try? Data(contentsOf: fileURL),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = parsed
            }

            var servers = (root[topKey] as? [String: Any]) ?? [:]
            servers[name] = entry
            root[topKey] = servers

            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            return .success(successMessage)
        } catch {
            return .failure(error)
        }
    }

    /// Remove serverName from topKey in the file. Succeeds (with successMessage)
    /// even when the entry was not present, so uninstall is idempotent.
    private static func removeServer(
        name: String,
        topKey: String,
        fileURL: URL,
        successMessage: String
    ) -> Result<String, Error> {
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return .success(successMessage)
            }
            var root = parsed
            if var servers = root[topKey] as? [String: Any] {
                servers.removeValue(forKey: name)
                root[topKey] = servers
            }
            let out = try JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: fileURL, options: .atomic)
            return .success(successMessage)
        } catch {
            return .failure(error)
        }
    }

    /// Returns true when the named server key exists under topKey in the file.
    private static func hasMcpEntry(name: String, topKey: String, fileURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root[topKey] as? [String: Any] else { return false }
        return servers[name] != nil
    }
}

// MARK: - Errors

enum McpInstallError: LocalizedError {
    case cliFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliFailed(let msg):
            return "CLI error: \(msg)"
        }
    }
}