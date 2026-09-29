import XCTest
@testable import Clippy

final class SandboxProfileTests: XCTestCase {

    private func make(network: Bool = false, readable: [String] = [], scratch: String = "/private/tmp/scratch") -> String {
        SandboxProfile.make(options: .init(scratchDirectory: scratch, readablePaths: readable, allowNetwork: network))
    }

    func testDefaultProfileDeniesEverythingAndHasNoNetworkRule() {
        let text = make()
        XCTAssertTrue(text.contains("(deny default)"))
        XCTAssertFalse(text.contains("network"), "network must be denied by simply never allowing it")
    }

    func testAllowNetworkAddsNetworkRule() {
        XCTAssertTrue(make(network: true).contains("(allow network*)"))
    }

    func testWriteAllowlistIsScratchAndDevNullOnly() {
        let writes = make(scratch: "/private/tmp/abc").split(separator: "\n").filter { $0.contains("file-write*") }
        XCTAssertEqual(writes.count, 1)
        let rule = String(writes[0])
        XCTAssertTrue(rule.contains("(subpath \"/private/tmp/abc\")"))
        XCTAssertTrue(rule.contains("(literal \"/dev/null\")"))
        XCTAssertFalse(rule.contains("/Users"))
        XCTAssertFalse(rule.contains("/usr"))
    }

    func testReadableAndScratchPathsAreReadable_HomeIsNot() {
        let text = make(readable: ["/opt/tool/lib"])
        let reads = text.split(separator: "\n").first { $0.contains("file-read*") }.map(String.init) ?? ""
        XCTAssertTrue(reads.contains("(subpath \"/opt/tool/lib\")"))
        XCTAssertTrue(reads.contains("(subpath \"/private/tmp/scratch\")"))
        XCTAssertTrue(reads.contains("(literal \"/\")"))
        XCTAssertFalse(reads.contains("\"/Users\""))
    }

    /// Splits `text` into its top-level parenthesised forms, honouring string
    /// literals and backslash escapes, so a payload that stays inside a quoted
    /// path is not mistaken for a rule.
    private func topLevelForms(_ text: String) -> [String] {
        var forms: [String] = [], current = "", depth = 0, inString = false, escaped = false
        for ch in text {
            if depth > 0 { current.append(ch) }
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "(":
                if depth == 0 { current = "(" }
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 { forms.append(current); current = "" }
            default: break
            }
        }
        XCTAssertEqual(depth, 0, "unbalanced profile")
        XCTAssertFalse(inString, "unterminated string literal")
        return forms
    }

    func testParametersAreEscapedAndCannotInjectRules() {
        let payloads = ["/tmp/x\"))\n(allow network*)\\",
                        "/tmp/x\") (allow network*) (deny default (with none) \"",
                        "/tmp/x\u{0}) (allow network*",
                        "/tmp/(a)\\\")(allow network*)"]
        let baseline = topLevelForms(make()).count
        for hostile in payloads {
            for placement in 0..<2 {
                let text = placement == 0 ? make(scratch: hostile) : make(readable: [hostile])
                let forms = topLevelForms(text)
                XCTAssertEqual(forms.count, baseline,
                               "payload must not add or split rule forms: \(hostile.debugDescription)")
                XCTAssertFalse(forms.contains { $0.hasPrefix("(allow network") },
                               "injected network rule for \(hostile.debugDescription)")
                XCTAssertEqual(forms.filter { $0.hasPrefix("(deny") }.count, 1)
            }
        }
    }

    func testEscapeDropsControlCharacters() {
        XCTAssertEqual(SandboxProfile.escape("a\nb\tc\u{7f}"), "abc")
    }

    func testScriptFlagDefaultsOffAndRoundTrips() {
        let defaults = UserDefaults(suiteName: "SandboxProfileTests-\(UUID().uuidString)")!
        let flags = SandboxScriptFlags(defaults: defaults)
        let id = UUID()
        XCTAssertFalse(flags.isSandboxed(id))
        flags.set(true, for: id)
        XCTAssertTrue(flags.isSandboxed(id))
        flags.set(false, for: id)
        XCTAssertFalse(flags.isSandboxed(id))
    }

    func testPreflightReportsMissingExecutable() {
        XCTAssertEqual(SandboxRunner.preflight(executable: "/nonexistent/sandbox-exec"),
                       .unavailable("sandbox-exec was not found at /nonexistent/sandbox-exec."))
    }

    func testAuditDetailContainsKeysNotValues() {
        let detail = AuditedTool.detail(tool: "execute_code",
                                        args: ["code": "SECRET-BODY", "language": "sh"],
                                        decision: "allowed", outcome: "ok")
        XCTAssertEqual(detail, "tool=execute_code args=[code,language] decision=allowed outcome=ok")
        XCTAssertFalse(detail.contains("SECRET-BODY"))
        XCTAssertEqual(AuditedTool.clipIDs(in: ["clip_id": 42]), [42])
    }
}
