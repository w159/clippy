import Foundation
import Combine
import Network
import os

// MARK: - Status

enum McpServerStatus {
    case stopped
    case starting
    case running(port: Int)
    case portInUse(port: Int)
    case failed(String)

    var description: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting..."
        case .running(let port):
            return "Running on http://127.0.0.1:\(port)"
        case .portInUse(let port):
            return "Port \(port) is already in use by another process"
        case .failed(let msg):
            return msg
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - Port status

/// What the Settings port row should say (SET-03). Derived from the running server
/// first, so it can never read "available" while our own server holds the port.
enum McpPortStatus: Equatable {
    /// Not a bindable port number.
    case invalid
    /// Nothing is listening; the server can bind it.
    case available
    /// Clippy's own MCP server is listening on it.
    case inUseByClippy
    /// Another process holds it.
    case inUseByOther

    /// Pure derivation: `serverPort` is the port our running server reports, if any.
    static func derive(port: Int, serverPort: Int?, isFree: Bool) -> McpPortStatus {
        guard (1...65535).contains(port) else { return .invalid }
        if serverPort == port { return .inUseByClippy }
        return isFree ? .available : .inUseByOther
    }

    var summary: String {
        switch self {
        case .invalid:       return "Enter a port between 1024 and 65535"
        case .available:     return "Available"
        case .inUseByClippy: return "In use by the Clippy server"
        case .inUseByOther:  return "In use by another process"
        }
    }
}

// MARK: - Controller

@MainActor
final class McpServerController: ObservableObject {
    static let shared = McpServerController()

    @Published var status: McpServerStatus = .stopped
    /// Status of the configured port, derived from the running server (SET-03).
    @Published private(set) var portStatus: McpPortStatus = .available

    private let lifecycle: McpLifecycle
    private let settings = AppSettings.shared
    private let tokenProvider: McpTokenProvider
    private var cancellables = Set<AnyCancellable>()

    // Commands run strictly in submission order: each awaits the one before it.
    // Without this, `stop()` followed by `start()` could reach the actor reversed.
    private var chain: Task<Void, Never>?

    // Pid of the live child, mirrored outside the lifecycle actor so `stop()` can
    // signal it synchronously. The app-terminate path cannot wait for an async hop.
    private var livePid: Int32?

    private init() {
        self.lifecycle = McpLifecycle(launcher: McpServerController.productionLauncher)
        self.tokenProvider = McpTokenProvider.shared
    }

    /// Test seam: build a controller with a fake launcher and token store.
    init(launcher: @escaping McpLauncher, tokenProvider: McpTokenProvider,
         terminationGrace: TimeInterval = 0.2) {
        self.lifecycle = McpLifecycle(launcher: launcher, terminationGrace: terminationGrace)
        self.tokenProvider = tokenProvider
    }

    /// Spawns the real node child.
    static let productionLauncher: McpLauncher = { spec, onStderrLine, onExit in
        var env = ProcessInfo.processInfo.environment
        for (key, value) in spec.environmentOverrides { env[key] = value }
        // node:sqlite is unflagged since Node 22.13 but still emits an
        // ExperimentalWarning; silence it so a clean stderr means a clean start.
        let proc = Subprocess.launch(
            executable: spec.nodePath,
            arguments: ["--disable-warning=ExperimentalWarning", spec.scriptPath],
            environment: env,
            onStderrLine: onStderrLine,
            onExit: onExit)
        return proc.isRunning ? McpProcessChild(proc) : nil
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await operation()
        }
    }

    private func setStatus(_ new: McpServerStatus) {
        status = new
        refreshPortStatus()
    }

    // MARK: - Node binary lookup

    /// Locate the node binary. GUI apps launched from Finder get a stripped PATH,
    /// so we check known Homebrew / system paths before falling back to a login shell
    /// (which picks up nvm, volta, asdf, etc.).
    nonisolated static func findNodeBinary() -> String? {
        Subprocess.findBinary(named: "node", candidates: [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ])
    }

    // MARK: - Script path resolution

    /// Resolve the bundled server script. Prefers the copy shipped inside the
    /// .app (Contents/Resources/clippy-mcp/index.mjs, written by make-app.sh),
    /// then falls back to the dev/SwiftPM source tree so `swift run` works
    /// without a packaged app. make-app.sh bundles a single esbuild .mjs that
    /// uses Node's built-in node:sqlite, so there is no node_modules to ship.
    nonisolated static func findServerScript() -> String? {
        // Production: bundled inside the app's Resources directory.
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("clippy-mcp/index.mjs")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled.path
            }
        }

        // Dev/SwiftPM: the executable sits at .build/debug/Clippy or similar.
        // Walk up looking for the freshly built bundle in the source tree.
        let execPath = Bundle.main.executablePath ?? ""
        var candidate = URL(fileURLWithPath: execPath).deletingLastPathComponent()
        for _ in 0..<8 {
            let script = candidate.appendingPathComponent("integrations/clippy-mcp/build/index.mjs")
            if FileManager.default.fileExists(atPath: script.path) {
                return script.path
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Port availability

    /// Returns true when nothing is bound to 127.0.0.1:\(port) yet.
    func isPortFree(_ port: Int) -> Bool {
        // If our own process is already holding it, report free so start() can no-op.
        if case .running(let runningPort) = status, runningPort == port { return true }

        // Out-of-range ports cannot be bound; report not-free rather than letting
        // UInt16(port) below trap on an integer overflow and crash the app.
        guard (1...65535).contains(port) else { return false }

        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock != -1 else { return false }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        Darwin.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    // MARK: - Lifecycle

    /// Start the server (no-op when running or starting).
    func start() {
        enqueue { [weak self] in await self?.startNow() }
    }

    /// Stop the server. Kills by pid and waits for exit before the status flips.
    func stop() {
        ClippyLog.info("MCP server stopping", category: ClippyLog.mcp)
        // Signal the stored pid right now (synchronously), then let the actor wait
        // for exit and escalate to SIGKILL if needed.
        let pid = livePid
        livePid = nil
        if let pid, pid > 0 { Darwin.kill(pid, SIGTERM) }
        enqueue { [weak self] in await self?.stopNow() }
    }

    /// Stop, wait for the port to be released, start again.
    func restart() {
        enqueue { [weak self] in
            await self?.stopNow()
            await self?.startNow()
        }
    }

    private func stopNow() async {
        await lifecycle.stop()
        setStatus(.stopped)
    }

    private func startNow() async {
        if status.isRunning { return }
        let port = settings.mcpPort

        // Binary lookups can spawn a login shell (seconds on a slow rc file), so they
        // run off the main actor.
        guard let nodePath = await Self.locateNodeBinary() else {
            fail("Node.js not found. Install Node to run the MCP server.")
            return
        }
        guard let scriptPath = await Self.locateServerScript() else {
            fail("MCP server script not found in the app bundle. "
                + "(Dev builds: run npm run build in integrations/clippy-mcp.)")
            return
        }
        let token: String
        do {
            token = try await Self.readToken(tokenProvider)
        } catch {
            // The server refuses to run unauthenticated, so a Keychain failure is fatal to start.
            fail("Could not read the MCP access token from the Keychain.")
            return
        }
        guard isPortFree(port) else {
            setStatus(.portInUse(port: port))
            return
        }
        setStatus(.starting)

        let spec = McpLaunchSpec(nodePath: nodePath, scriptPath: scriptPath, port: port,
                                 databasePath: ClipDatabase.shared.databaseURL.path, token: token)
        // stderr arrives on the launch drain thread; the health poll reads it from
        // another. Guard both sides.
        let stderrLines = OSAllocatedUnfairLock<[String]>(initialState: [])
        let outcome = await lifecycle.start(
            spec,
            onStderrLine: { line in
                stderrLines.withLock { $0.append(line) }
            },
            onExit: { [weak self] generation in
                Task { await self?.childExited(generation: generation) }
            })

        switch outcome {
        case .alreadyRunning:
            return
        case .launchFailed:
            fail("Could not launch the MCP server process.")
        case .started(let generation):
            livePid = await lifecycle.runningPid
            await pollHealth(port: port, token: token, generation: generation, stderrSnapshot: {
                stderrLines.withLock { $0 }
            })
        }
    }

    private nonisolated static func locateNodeBinary() async -> String? { findNodeBinary() }
    private nonisolated static func locateServerScript() async -> String? { findServerScript() }
    private nonisolated static func readToken(_ provider: McpTokenProvider) async throws -> String {
        try provider.token()
    }

    private func fail(_ message: String) {
        ClippyLog.error("MCP start failed: \(message)", category: ClippyLog.mcp)
        setStatus(.failed(message))
    }

    /// The child exited on its own. Ignored when a stop/start already superseded it.
    private func childExited(generation: Int) async {
        guard await lifecycle.isCurrent(generation) else { return }
        switch status {
        case .running: setStatus(.stopped)
        case .starting: setStatus(.failed("The MCP server exited during startup."))
        default: break
        }
    }

    /// Poll /health until the server answers 200 (max ~5s). Every step re-checks the
    /// generation, so once `stop()` runs nothing here can report `.running`.
    private func pollHealth(port: Int, token: String, generation: Int,
                            stderrSnapshot: @escaping @Sendable () -> [String]) async {
        for attempt in 0..<10 {
            guard await lifecycle.isCurrent(generation) else { return }
            if await Self.healthOK(port: port, token: token) {
                // Re-check after the network hop: stop() may have run meanwhile.
                guard await lifecycle.isCurrent(generation) else { return }
                let startupStderr = stderrSnapshot().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !startupStderr.isEmpty {
                    ClippyLog.info("MCP server startup stderr: \(startupStderr)", category: ClippyLog.mcp)
                }
                ClippyLog.info("MCP server running on port \(port)", category: ClippyLog.mcp)
                setStatus(.running(port: port))
                return
            }
            if attempt < 9 { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        guard await lifecycle.isCurrent(generation) else { return }
        let detail = stderrSnapshot().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        fail(detail.isEmpty ? "Server did not respond to /health after launch." : detail)
    }

    /// GET /health with the bearer token; true only for HTTP 200.
    nonisolated static func healthOK(port: Int, token: String) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Port status (SET-03)

    /// Recompute `portStatus` for the configured port from the running server. Cheap
    /// (one bind probe); call from the port field's change handler and on appear.
    func refreshPortStatus() {
        let port = settings.mcpPort
        var serverPort: Int?
        if case .running(let live) = status { serverPort = live }
        portStatus = McpPortStatus.derive(port: port, serverPort: serverPort,
                                          isFree: isPortFree(port))
    }

    // MARK: - Token rotation (SEC-03)

    /// Replace the bearer token, restart the server with it, and re-write every
    /// installed client config. The old token stops working immediately.
    func rotateToken() {
        enqueue { [weak self] in
            guard let self else { return }
            do {
                try self.tokenProvider.rotate()
            } catch {
                self.fail("Could not rotate the MCP access token.")
                return
            }
            await self.stopNow()
            if self.settings.mcpEnabled { await self.startNow() }
            await McpInstallService.resyncInstalledClients(port: self.settings.mcpPort,
                                                           tokenProvider: self.tokenProvider)
        }
    }

    // MARK: - Settings observation

    /// Call once from AppDelegate after launch. Starts the server if enabled,
    /// and wires up Combine sinks so future settings changes take effect live.
    func syncWithSettings() {
        if settings.mcpEnabled { start() }

        settings.$mcpEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled { self?.start() } else { self?.stop() }
            }
            .store(in: &cancellables)

        // A port change restarts the server and re-points every installed client
        // at the new URL; without the re-sync their configs go stale (MCP-03).
        settings.$mcpPort
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] port in
                guard let self else { return }
                self.refreshPortStatus()
                guard self.settings.mcpEnabled else { return }
                self.enqueue { [weak self] in
                    guard let self else { return }
                    await self.stopNow()
                    await self.startNow()
                    await McpInstallService.resyncInstalledClients(port: port,
                                                                   tokenProvider: self.tokenProvider)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Test connection

    /// Hits /health, then MCP tools/list, both with the bearer token, and reports the
    /// tool count. A non-200 anywhere is a failure, never "0 tools". Completion runs on main.
    func testConnection(completion: @escaping @MainActor (Result<Int, Error>) -> Void) {
        guard case .running(let port) = status else {
            completion(.failure(McpError.serverNotRunning))
            return
        }
        let provider = tokenProvider
        Task {
            let result: Result<Int, Error>
            do {
                let token = try await Self.readToken(provider)
                guard await Self.healthOK(port: port, token: token) else {
                    throw McpError.healthCheckFailed
                }
                result = .success(try await Self.fetchToolCount(port: port, token: token))
            } catch {
                result = .failure(error)
            }
            completion(result)
        }
    }

    nonisolated static func fetchToolCount(port: Int, token: String) async throws -> Int {
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else { return 0 }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The streamable-HTTP transport requires both types in Accept.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [String: Any]()] as [String: Any])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw McpError.httpStatus(code) }
        return parseToolCount(from: data)
    }

    /// Tool count from a tools/list body, which is plain JSON or a single SSE `data:` frame.
    nonisolated static func parseToolCount(from data: Data?) -> Int {
        guard var data else { return 0 }
        if let text = String(data: data, encoding: .utf8), text.hasPrefix("event:") || text.hasPrefix("data:"),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("data:") }) {
            data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { return 0 }
        return tools.count
    }
}

// MARK: - Errors

enum McpError: LocalizedError {
    case serverNotRunning
    case healthCheckFailed
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return "MCP server is not running. Enable it in Settings first."
        case .healthCheckFailed:
            return "Server responded but /health returned an unexpected status."
        case .httpStatus(let code):
            return code == 401
                ? "The server rejected the access token (HTTP 401). Rotate the token and reinstall the client."
                : "The server returned HTTP \(code) for tools/list."
        }
    }
}
