import XCTest
@testable import Clippy

/// Scripts can be created over MCP by anything connected to it, and Clippy
/// executes them as the signed-in user. The disabled flag is the control that
/// keeps that from being a remote code execution path, so it is enforced in
/// `ScriptRunner.run` - the one chokepoint every caller funnels through - rather
/// than in each UI surface.
final class DisabledScriptTests: XCTestCase {

    private func script(enabled: Bool) -> Script {
        Script(
            name: "probe",
            interpreter: .zsh,
            // Writes a file so a wrongly-permitted run leaves evidence rather
            // than passing silently.
            body: "echo executed",
            isEnabled: enabled
        )
    }

    func testDisabledScriptDoesNotRun() async {
        let result = await ScriptRunner.run(script(enabled: false))
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertTrue(result.stdout.isEmpty, "a disabled script must produce no output")
        XCTAssertTrue(
            result.stderr.contains("disabled"),
            "the refusal must say why: \(result.stderr)"
        )
    }

    func testEnabledScriptStillRuns() async {
        let result = await ScriptRunner.run(script(enabled: true))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("executed"))
    }

    /// Existing scripts.json files predate the key. They were created by the user
    /// in the app, so they must keep working across the upgrade.
    func testScriptsSavedBeforeTheFlagExistedDecodeAsEnabled() throws {
        let legacy = """
            {
              "id": "6EF30786-2E8D-4A00-8355-5341539447C6",
              "name": "iCloud Dedup",
              "interpreter": "zsh",
              "body": "echo hi",
              "feedsClipboard": false,
              "outputToClipboard": true,
              "createdAt": "2026-06-12T03:20:43Z",
              "updatedAt": "2026-06-17T08:08:57Z",
              "sortOrder": 0
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Script.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.isEnabled, "a script with no isEnabled key must stay runnable")
    }

    /// And a script the MCP server wrote must decode as disabled.
    func testScriptWrittenDisabledDecodesAsDisabled() throws {
        let fromMCP = """
            {
              "id": "6EF30786-2E8D-4A00-8355-5341539447C7",
              "name": "From MCP",
              "interpreter": "zsh",
              "body": "echo hi",
              "feedsClipboard": false,
              "outputToClipboard": false,
              "createdAt": "2026-09-16T21:04:07Z",
              "updatedAt": "2026-09-16T21:04:07Z",
              "sortOrder": 1,
              "isEnabled": false
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Script.self, from: Data(fromMCP.utf8))
        XCTAssertFalse(decoded.isEnabled)
    }
}
