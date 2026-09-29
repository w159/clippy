import XCTest
@testable import Clippy

final class ClippyLogRedactionTests: XCTestCase {

    func testPlaceholderKeepsLengthAndDropsContent() {
        let out = ClippyLog.redact("123-45-6789")
        XCTAssertEqual(out, "<redacted 11 chars>")
        XCTAssertFalse(out.contains("6789"))
    }

    func testScrubMasksBearerTokensAndCredentialAssignments() {
        let token = "abcDEF0123456789abcDEF0123456789abcDEF01234"
        XCTAssertEqual(LogRedaction.scrub("Authorization: Bearer \(token)"), "Authorization: <redacted>")
        XCTAssertFalse(LogRedaction.scrub("sent Bearer \(token) ok").contains(token))
        XCTAssertFalse(LogRedaction.scrub("password=hunter2 next").contains("hunter2"))
        XCTAssertFalse(LogRedaction.scrub("api_key: sk_live_123").contains("sk_live_123"))
        XCTAssertFalse(LogRedaction.scrub("ref op://Vault/Item/password").contains("Vault/Item"))
    }

    func testScrubLeavesOrdinaryMessagesAlone() {
        let message = "MCP server running on port 51764"
        XCTAssertEqual(LogRedaction.scrub(message), message)
    }

    func testLogFileIsOwnerOnlyAndScrubbed() throws {
        let marker = UUID().uuidString
        ClippyLog.threshold = .info
        ClippyLog.info("probe \(marker) password=topsecret99", category: ClippyLog.mcp)
        ClippyLog.flushForTesting()

        let url = ClippyLog.logFileURL
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(marker))
        XCTAssertFalse(text.contains("topsecret99"))
    }
}
