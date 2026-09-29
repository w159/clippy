import XCTest
@testable import Clippy

final class McpInstallServiceTests: XCTestCase {
    private var root: URL!
    private var tokens: McpTokenProvider!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-mcp-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tokens = McpTokenProvider(store: InMemorySecretStore())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Environment rooted in the temp dir. `stdio` controls whether node + script resolve.
    private func makeEnv(stdio: Bool = false) -> McpInstallEnvironment {
        McpInstallEnvironment(home: root.appendingPathComponent("home"),
                              applicationSupport: root.appendingPathComponent("support"),
                              nodePath: stdio ? "/opt/test/node" : nil,
                              scriptPath: stdio ? "/opt/test/index.mjs" : nil,
                              npxPath: "/opt/test/npx", claudePath: nil,
                              databasePath: "/tmp/clippy-test.sqlite")
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func backups(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(url.lastPathComponent + ".clippy-backup-") }
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: MCP-02: never overwrite an unparseable config

    func testUnparseableConfigIsRefusedBackedUpAndLeftByteIdentical() async throws {
        let environment = makeEnv()
        let url = McpInstallService.configURL(for: .cursor, env: environment)
        let original = "{ // my servers\n \"mcpServers\": { \"keep\": {\"command\": \"x\"} },\n}"
        try write(original, to: url)

        let result = await McpInstallService.install(.cursor, port: 51764, env: environment, tokenProvider: tokens)

        guard case .failure(let error) = result,
              case McpInstallError.unparseableConfig(let file, let backup) = error else {
            return XCTFail("expected unparseableConfig, got \(result)")
        }
        XCTAssertEqual(file, url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        let saved = try XCTUnwrap(backup)
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), original)
    }

    func testRootThatIsNotAnObjectIsRefused() async throws {
        let environment = makeEnv()
        let url = McpInstallService.configURL(for: .windsurf, env: environment)
        try write("[1, 2, 3]", to: url)
        let result = await McpInstallService.install(.windsurf, port: 51764, env: environment, tokenProvider: tokens)
        guard case .failure = result else { return XCTFail("array root must be refused") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[1, 2, 3]")
    }

    func testServersKeyOfWrongTypeIsRefusedWithoutWriting() async throws {
        let environment = makeEnv()
        let url = McpInstallService.configURL(for: .cursor, env: environment)
        try write(#"{"mcpServers": ["oops"]}"#, to: url)
        let result = await McpInstallService.install(.cursor, port: 51764, env: environment, tokenProvider: tokens)
        guard case .failure(let error) = result, case McpInstallError.unexpectedShape = error else {
            return XCTFail("expected unexpectedShape, got \(result)")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), #"{"mcpServers": ["oops"]}"#)
    }

    func testMergePreservesOtherServersAndUnrelatedKeys() async throws {
        let environment = makeEnv()
        let url = McpInstallService.configURL(for: .cursor, env: environment)
        try write(#"{"theme":"dark","mcpServers":{"other":{"command":"x","args":["a"]}}}"#, to: url)

        let result = await McpInstallService.install(.cursor, port: 51764, env: environment, tokenProvider: tokens)

        guard case .success = result else { return XCTFail("\(result)") }
        let root = try json(url)
        XCTAssertEqual(root["theme"] as? String, "dark")
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["other"] as? [String: Any])?["command"] as? String, "x")
        XCTAssertNotNil(servers["clippy"])
        XCTAssertTrue(backups(of: url).isEmpty, "a parseable file needs no backup")
    }

    func testInstallIsIdempotent() async throws {
        let environment = makeEnv()
        let url = McpInstallService.configURL(for: .vscode, env: environment)
        _ = await McpInstallService.install(.vscode, port: 51764, env: environment, tokenProvider: tokens)
        let first = try String(contentsOf: url, encoding: .utf8)
        _ = await McpInstallService.install(.vscode, port: 51764, env: environment, tokenProvider: tokens)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), first)
    }

    func testRemoveLeavesOtherServersAndRefusesUnparseableFiles() async throws {
        let environment = makeEnv()
        let url = McpInstallService.configURL(for: .cursor, env: environment)
        try write(#"{"mcpServers":{"other":{"command":"x"},"clippy":{"url":"u"}}}"#, to: url)
        guard case .success = await McpInstallService.remove(.cursor, env: environment) else { return XCTFail() }
        let servers = try XCTUnwrap(try json(url)["mcpServers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), ["other"])

        try write("{ nope", to: url)
        guard case .failure = await McpInstallService.remove(.cursor, env: environment) else { return XCTFail() }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ nope")
    }

    // MARK: Dry-run preview

    func testPreviewDoesNotWriteAndMasksTheToken() throws {
        let environment = makeEnv()
        let url = McpInstallService.configURL(for: .cursor, env: environment)
        try write(#"{"mcpServers":{"other":{"command":"x"}}}"#, to: url)
        let before = try String(contentsOf: url, encoding: .utf8)

        let preview = try McpInstallService.preview(.cursor, port: 51764, env: environment, tokenProvider: tokens)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
        XCTAssertEqual(preview.transport, .http)
        XCTAssertEqual(preview.preservedServers, ["other"])
        XCTAssertTrue(preview.after.contains("http://127.0.0.1:51764/mcp"))
        let token = try tokens.token()
        XCTAssertFalse(preview.after.contains(token))
        XCTAssertFalse(preview.diff.contains(token))
        XCTAssertTrue(preview.diff.contains("+ "))
    }

    func testPreviewOfMissingFileReportsCreationAndTouchesNothing() throws {
        let environment = makeEnv()
        let preview = try McpInstallService.preview(.zed, port: 51764, env: environment, tokenProvider: tokens)
        XCTAssertFalse(preview.fileExists)
        XCTAssertNil(preview.before)
        XCTAssertTrue(preview.after.contains("context_servers"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.fileURL.path))
    }

    func testPreviewOfUnparseableFileThrowsWithoutCreatingABackup() throws {
        let environment = makeEnv()
        let url = McpInstallService.configURL(for: .cursor, env: environment)
        try write("{ broken", to: url)
        XCTAssertThrowsError(try McpInstallService.preview(.cursor, port: 1, env: environment, tokenProvider: tokens))
        XCTAssertTrue(backups(of: url).isEmpty)
    }

    // MARK: Transport and client shapes

    func testStdioPreferredWhenNodeAndScriptResolveAndNoTokenIsWritten() async throws {
        let environment = makeEnv(stdio: true)
        let url = McpInstallService.configURL(for: .cursor, env: environment)
        _ = await McpInstallService.install(.cursor, port: 51764, env: environment, tokenProvider: tokens)

        let entry = try XCTUnwrap((try json(url)["mcpServers"] as? [String: Any])?["clippy"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, "/opt/test/node", "absolute node path")
        XCTAssertEqual((entry["args"] as? [String])?.last, "/opt/test/index.mjs")
        XCTAssertNil(entry["url"])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("Bearer"))
        XCTAssertFalse(text.contains(try tokens.token()))
    }

    func testHTTPFallbackWritesBearerHeaderAndOwnerOnlyPermissions() async throws {
        let environment = makeEnv()
        let url = McpInstallService.configURL(for: .cursor, env: environment)
        _ = await McpInstallService.install(.cursor, port: 51764, env: environment, tokenProvider: tokens)

        let entry = try XCTUnwrap((try json(url)["mcpServers"] as? [String: Any])?["clippy"] as? [String: Any])
        let headers = try XCTUnwrap(entry["headers"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Bearer \(try tokens.token())")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testEachClientUsesItsOwnKeysAndPaths() async throws {
        let environment = makeEnv()
        for (client, urlKey, serversKey) in [(McpClient.cursor, "url", "mcpServers"),
                                             (.windsurf, "serverUrl", "mcpServers"),
                                             (.zed, "url", "context_servers"),
                                             (.vscode, "url", "servers")] {
            _ = await McpInstallService.install(client, port: 4242, env: environment, tokenProvider: tokens)
            let url = McpInstallService.configURL(for: client, env: environment)
            let entry = try XCTUnwrap((try json(url)[serversKey] as? [String: Any])?["clippy"] as? [String: Any],
                                      "\(client)")
            XCTAssertEqual(entry[urlKey] as? String, "http://127.0.0.1:4242/mcp", "\(client)")
        }
        XCTAssertTrue(McpInstallService.configURL(for: .cursor, env: environment).path.hasSuffix("/.cursor/mcp.json"))
        XCTAssertTrue(McpInstallService.configURL(for: .windsurf, env: environment).path.hasSuffix("/.codeium/windsurf/mcp_config.json"))
        XCTAssertTrue(McpInstallService.configURL(for: .zed, env: environment).path.hasSuffix("/.config/zed/settings.json"))
    }

    func testClaudeDesktopHTTPUsesAbsoluteNpxAndKeepsTokenOutOfArgs() async throws {
        let environment = makeEnv()
        let url = McpInstallService.configURL(for: .claudeDesktop, env: environment)
        _ = await McpInstallService.install(.claudeDesktop, port: 51764, env: environment, tokenProvider: tokens)
        let entry = try XCTUnwrap((try json(url)["mcpServers"] as? [String: Any])?["clippy"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, "/opt/test/npx")
        let args = try XCTUnwrap(entry["args"] as? [String])
        let token = try tokens.token()
        XCTAssertFalse(args.contains { $0.contains(token) })
        XCTAssertEqual((entry["env"] as? [String: String])?["CLIPPY_MCP_AUTH"], "Bearer \(token)")
    }

    // MARK: Re-sync

    func testResyncRewritesOnlyInstalledClientsWithTheNewPort() async throws {
        let environment = makeEnv()
        _ = await McpInstallService.install(.cursor, port: 1111, env: environment, tokenProvider: tokens)

        let results = await McpInstallService.resyncInstalledClients(port: 2222, env: environment, tokenProvider: tokens)

        XCTAssertEqual(Set(results.keys), [.cursor])
        let url = McpInstallService.configURL(for: .cursor, env: environment)
        let entry = try XCTUnwrap((try json(url)["mcpServers"] as? [String: Any])?["clippy"] as? [String: Any])
        XCTAssertEqual(entry["url"] as? String, "http://127.0.0.1:2222/mcp")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: McpInstallService.configURL(for: .windsurf, env: environment).path))
    }

    func testIsInstalledReflectsTheFile() async throws {
        let environment = makeEnv()
        let before = await McpInstallService.isInstalled(.cursor, env: environment)
        XCTAssertFalse(before)
        _ = await McpInstallService.install(.cursor, port: 1, env: environment, tokenProvider: tokens)
        let after = await McpInstallService.isInstalled(.cursor, env: environment)
        XCTAssertTrue(after)
    }
}
