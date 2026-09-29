import Foundation
import os

// MARK: - MCP client targets

enum McpClient: String, CaseIterable, Identifiable {
    case claudeDesktop
    case claudeCode
    case vscode
    case cursor
    case windsurf
    case zed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .claudeCode:    return "Claude Code"
        case .vscode:        return "VS Code (GitHub Copilot)"
        case .cursor:        return "Cursor"
        case .windsurf:      return "Windsurf"
        case .zed:           return "Zed"
        }
    }

    /// JSON key that holds the server map in the client's config file.
    var serversKey: String {
        switch self {
        case .vscode: return "servers"
        case .zed:    return "context_servers"
        default:      return "mcpServers"
        }
    }

    /// What the user must do for the client to pick up a change.
    var applyHint: String {
        switch self {
        case .vscode: return "Reload VS Code to apply."
        default:      return "Restart \(displayName) to apply."
        }
    }
}

// MARK: - Transport, environment, preview

/// How a client talks to Clippy's MCP server.
enum McpTransport: String, Equatable {
    /// The client launches `node index.mjs` itself. No port, no token: the pipe is
    /// private to the client's process. Preferred wherever the client supports it.
    case stdio
    /// The client connects to the loopback endpoint with the bearer token.
    case http
}

/// Everything the install logic needs from the machine, injectable for tests.
struct McpInstallEnvironment {
    var home: URL
    var applicationSupport: URL
    var nodePath: String?
    var scriptPath: String?
    var npxPath: String?
    var claudePath: String?
    var databasePath: String

    private static let liveCache = OSAllocatedUnfairLock<(env: McpInstallEnvironment, at: Date)?>(initialState: nil)
    /// Binary lookups can spawn a login shell, so a resolved environment is reused briefly.
    private static let liveTTL: TimeInterval = 30

    /// Real machine paths. Binaries are resolved to absolute paths because GUI apps
    /// (Claude Desktop, Zed) launch with a stripped PATH where a bare `npx` fails.
    static func live() -> McpInstallEnvironment {
        if let cached = liveCache.withLock({ $0 }), Date().timeIntervalSince(cached.at) < liveTTL {
            return cached.env
        }
        let env = McpInstallEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            nodePath: McpServerController.findNodeBinary(),
            scriptPath: McpServerController.findServerScript(),
            npxPath: Subprocess.findBinary(named: "npx", candidates: [
                "/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"]),
            claudePath: Subprocess.findBinary(named: "claude", candidates: [
                "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude"]),
            databasePath: ClipDatabase.shared.databaseURL.path)
        liveCache.withLock { $0 = (env, Date()) }
        return env
    }
}

/// Dry-run result: exactly what installing would write, with the token masked so it
/// is safe to show in the UI. Producing one never touches the disk.
struct McpConfigPreview: Equatable {
    let client: McpClient
    let fileURL: URL
    let transport: McpTransport
    /// False when the file does not exist yet (it would be created).
    let fileExists: Bool
    /// Current file text, nil when it does not exist.
    let before: String?
    /// The full file text that would be written (token masked).
    let after: String
    /// Line diff of `before` -> `after`: "+ " added, "- " removed, unchanged omitted.
    let diff: String
    /// Other servers already in the file; all are preserved.
    let preservedServers: [String]
}

// MARK: - Install service

enum McpInstallService {

    /// Server name written into every client config.
    static let serverName = "clippy"
    /// Bound on any single CLI probe or command so Settings rows cannot spin forever (SET-03).
    static let cliTimeout: TimeInterval = 10

    // MARK: Config locations

    /// The config file for a client, or nil when the client is configured through its CLI only.
    static func configURL(for client: McpClient, env: McpInstallEnvironment) -> URL {
        switch client {
        case .claudeDesktop: return env.applicationSupport.appendingPathComponent("Claude/claude_desktop_config.json")
        case .claudeCode:    return env.home.appendingPathComponent(".claude.json")
        case .vscode:        return env.applicationSupport.appendingPathComponent("Code/User/mcp.json")
        case .cursor:        return env.home.appendingPathComponent(".cursor/mcp.json")
        // Windsurf's path is corroborated by secondary docs only; Cursor and Zed by official docs.
        case .windsurf:      return env.home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        // macOS location per Zed's docs. The file is JSONC: comments make it unparseable
        // here, in which case installation is refused rather than rewritten.
        case .zed:           return env.home.appendingPathComponent(".config/zed/settings.json")
        }
    }

    // MARK: Entry construction (pure)

    /// The server entry for `client`. stdio when node and the server script are
    /// resolvable, otherwise HTTP with the bearer token.
    static func makeEntry(for client: McpClient, port: Int, token: () throws -> String,
                      env: McpInstallEnvironment) throws -> (entry: [String: Any], transport: McpTransport) {
        if let node = env.nodePath, let script = env.scriptPath {
            var entry: [String: Any] = [
                "command": node,
                "args": ["--disable-warning=ExperimentalWarning", script],
                "env": ["CLIPPY_DB_PATH": env.databasePath],
            ]
            if client == .vscode { entry["type"] = "stdio" }
            return (entry, .stdio)
        }
        let url = "http://127.0.0.1:\(port)/mcp"
        let auth = "Bearer \(try token())"
        switch client {
        case .claudeDesktop:
            // Claude Desktop is stdio-only; mcp-remote bridges to the HTTP endpoint. The
            // header value travels in the environment, not the args, to keep it out of argv.
            return (["command": env.npxPath ?? "npx",
                     "args": ["-y", "mcp-remote", url, "--header", "Authorization:${CLIPPY_MCP_AUTH}"],
                     "env": ["CLIPPY_MCP_AUTH": auth]], .http)
        case .claudeCode, .vscode:
            return (["type": "http", "url": url, "headers": ["Authorization": auth]], .http)
        case .cursor, .zed:
            return (["url": url, "headers": ["Authorization": auth]], .http)
        case .windsurf:
            return (["serverUrl": url, "headers": ["Authorization": auth]], .http)
        }
    }

    // MARK: Config parsing / rendering (pure)

    /// Parse config text into a root object. Empty (or whitespace-only) text is an empty
    /// root. Anything else that is not a JSON object is a failure and MUST NOT be replaced.
    static func parseRoot(_ text: String) -> [String: Any]? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func render(_ root: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Merge `entry` under `serversKey`. Throws `unexpectedShape` if that key holds a non-object.
    static func merged(root: [String: Any], serversKey: String, entry: [String: Any],
                       file: URL) throws -> [String: Any] {
        var root = root
        var servers: [String: Any] = [:]
        if let existing = root[serversKey] {
            guard let dict = existing as? [String: Any] else {
                throw McpInstallError.unexpectedShape(file: file, detail: "\"\(serversKey)\" is not an object")
            }
            servers = dict
        }
        servers[serverName] = entry
        root[serversKey] = servers
        return root
    }

    static func lineDiff(before: String?, after: String) -> String {
        let old = (before ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        for change in new.difference(from: old) {
            switch change {
            case .remove(_, let line, _): out.append("- \(line)")
            case .insert(_, let line, _): out.append("+ \(line)")
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Preview (dry run)

    /// What `install` would write for a file-based client. Never writes or backs up
    /// anything. Throws `unparseableConfig` when the existing file cannot be parsed.
    static func preview(_ client: McpClient, port: Int, env: McpInstallEnvironment = .live(),
                        tokenProvider: McpTokenProvider = .shared) throws -> McpConfigPreview {
        let url = configURL(for: client, env: env)
        let (entry, transport) = try makeEntry(for: client, port: port,
                                               token: { try tokenOrThrow(tokenProvider) }, env: env)
        let existingText = try? String(contentsOf: url, encoding: .utf8)
        let root: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let text = existingText, let parsed = parseRoot(text) else {
                throw McpInstallError.unparseableConfig(file: url, backup: nil)
            }
            root = parsed
        } else {
            root = [:]
        }
        let mergedRoot = try merged(root: root, serversKey: client.serversKey, entry: entry, file: url)
        var after = try render(mergedRoot)
        if transport == .http, let token = try? tokenProvider.token() {
            after = after.replacingOccurrences(of: token, with: "<token>")
        }
        let others = ((root[client.serversKey] as? [String: Any]) ?? [:]).keys
            .filter { $0 != serverName }.sorted()
        return McpConfigPreview(client: client, fileURL: url, transport: transport,
                                fileExists: existingText != nil, before: existingText, after: after,
                                diff: lineDiff(before: existingText, after: after), preservedServers: others)
    }

    private static func tokenOrThrow(_ provider: McpTokenProvider) throws -> String {
        do { return try provider.token() } catch { throw McpInstallError.tokenUnavailable }
    }

    // MARK: Install

    /// Write (or merge) the Clippy MCP entry for the given client. Idempotent. Other
    /// servers are preserved; a config that fails to parse is backed up and left
    /// untouched (never overwritten).
    static func install(_ client: McpClient, port: Int, env: McpInstallEnvironment = .live(),
                        tokenProvider: McpTokenProvider = .shared) async -> Result<String, Error> {
        if client == .claudeCode, let claude = env.claudePath,
           let node = env.nodePath, let script = env.scriptPath {
            // The CLI takes no secrets here: stdio needs none. An HTTP install would put the
            // token in argv, so it always goes through the JSON file instead.
            _ = await runCLI(claude, args: ["mcp", "remove", serverName, "-s", "user"])
            let result = await runCLI(claude, args: [
                "mcp", "add", "--transport", "stdio", "-s", "user",
                "-e", "CLIPPY_DB_PATH=\(env.databasePath)",
                serverName, "--", node, "--disable-warning=ExperimentalWarning", script])
            if case .success(let output) = result {
                let msg = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return .success(msg.isEmpty ? "Registered with Claude Code (user scope)." : msg)
            }
        }
        return writeConfig(client, port: port, env: env, tokenProvider: tokenProvider)
    }

    private static func writeConfig(_ client: McpClient, port: Int, env: McpInstallEnvironment,
                                    tokenProvider: McpTokenProvider) -> Result<String, Error> {
        let url = configURL(for: client, env: env)
        do {
            let (entry, _) = try makeEntry(for: client, port: port,
                                           token: { try tokenOrThrow(tokenProvider) }, env: env)
            var root: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: url.path) {
                let text = try String(contentsOf: url, encoding: .utf8)
                guard let parsed = parseRoot(text) else {
                    // Refuse: keep a copy for the user and leave the original alone.
                    let backup = try? backUp(url)
                    ClippyLog.error("MCP install refused: \(url.lastPathComponent) is not valid JSON",
                                    category: ClippyLog.mcp)
                    throw McpInstallError.unparseableConfig(file: url, backup: backup)
                }
                root = parsed
            }
            let out = try render(try merged(root: root, serversKey: client.serversKey, entry: entry, file: url))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(out.utf8).write(to: url, options: .atomic)
            // The file can now hold a bearer token: owner-only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return .success("Registered in \(url.path). \(client.applyHint)")
        } catch {
            return .failure(error)
        }
    }

    /// Copy `url` to `<name>.clippy-backup-<timestamp>` beside it.
    @discardableResult
    static func backUp(_ url: URL) throws -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var backup = url.appendingPathExtension("clippy-backup-\(stamp.string(from: Date()))")
        var attempt = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = url.appendingPathExtension("clippy-backup-\(stamp.string(from: Date()))-\(attempt)")
            attempt += 1
        }
        try FileManager.default.copyItem(at: url, to: backup)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup
    }

    // MARK: Re-sync

    /// Re-write the entry for every client that already has one, so a port change or
    /// token rotation does not leave stale configs behind. Returns per-client results.
    @discardableResult
    static func resyncInstalledClients(port: Int, env: McpInstallEnvironment = .live(),
                                       tokenProvider: McpTokenProvider = .shared)
        async -> [McpClient: Result<String, Error>] {
        var results: [McpClient: Result<String, Error>] = [:]
        for client in McpClient.allCases where await isInstalled(client, env: env) {
            results[client] = await install(client, port: port, env: env, tokenProvider: tokenProvider)
        }
        return results
    }

    // MARK: Uninstall

    /// Remove the Clippy entry. Idempotent. A config that fails to parse is left alone.
    static func remove(_ client: McpClient, env: McpInstallEnvironment = .live()) async -> Result<String, Error> {
        if client == .claudeCode, let claude = env.claudePath,
           case .success(let output) = await runCLI(claude, args: ["mcp", "remove", serverName, "-s", "user"]) {
            let msg = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(msg.isEmpty ? "Removed from Claude Code (user scope)." : msg)
        }
        let url = configURL(for: client, env: env)
        return removeServer(topKey: client.serversKey, fileURL: url,
                            successMessage: "Removed from \(url.path). \(client.applyHint)")
    }

    // MARK: Is installed

    /// Best-effort check that a "clippy" entry exists. CLI probes are bounded by `cliTimeout`.
    static func isInstalled(_ client: McpClient, env: McpInstallEnvironment = .live()) async -> Bool {
        if client == .claudeCode, let claude = env.claudePath,
           case .success(let output) = await runCLI(claude, args: ["mcp", "list"]),
           output.contains(serverName) {
            return true
        }
        return hasMcpEntry(topKey: client.serversKey, fileURL: configURL(for: client, env: env))
    }

    // MARK: - CLI runner

    private static func runCLI(_ path: String, args: [String]) async -> Result<String, Error> {
        let output = await Subprocess.run(path, args, timeout: cliTimeout)
        if output.succeeded { return .success(output.stdout) }
        return .failure(McpInstallError.cliFailed(output.timedOut ? "Timed out" : output.stderr))
    }

    // MARK: - JSON helpers

    /// Remove the entry. Succeeds when the file or entry is absent; fails without writing
    /// when the file exists but is not valid JSON.
    static func removeServer(topKey: String, fileURL: URL, successMessage: String) -> Result<String, Error> {
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return .success(successMessage) }
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            guard var root = parseRoot(text) else {
                throw McpInstallError.unparseableConfig(file: fileURL, backup: nil)
            }
            guard var servers = root[topKey] as? [String: Any], servers[serverName] != nil else {
                return .success(successMessage)
            }
            servers.removeValue(forKey: serverName)
            root[topKey] = servers
            try Data(try render(root).utf8).write(to: fileURL, options: .atomic)
            return .success(successMessage)
        } catch {
            return .failure(error)
        }
    }

    static func hasMcpEntry(topKey: String, fileURL: URL) -> Bool {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              let root = parseRoot(text),
              let servers = root[topKey] as? [String: Any] else { return false }
        return servers[serverName] != nil
    }
}

// MARK: - Errors

enum McpInstallError: LocalizedError {
    case cliFailed(String)
    /// The existing config is not valid JSON. It was not modified; `backup` is a copy.
    case unparseableConfig(file: URL, backup: URL?)
    case unexpectedShape(file: URL, detail: String)
    case tokenUnavailable

    var errorDescription: String? {
        switch self {
        case .cliFailed(let msg):
            return "CLI error: \(msg)"
        case .unparseableConfig(let file, let backup):
            let saved = backup.map { " A copy was saved to \($0.path)." } ?? ""
            return "\(file.path) is not valid JSON, so Clippy left it unchanged.\(saved) Fix or remove the file, then try again."
        case .unexpectedShape(let file, let detail):
            return "\(file.path) has an unexpected layout (\(detail)); Clippy left it unchanged."
        case .tokenUnavailable:
            return "The MCP access token could not be read from the Keychain."
        }
    }
}
