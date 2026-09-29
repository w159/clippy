import XCTest
@testable import Clippy

final class URLSchemeTests: XCTestCase {
    private func parse(_ string: String) -> Result<ClippyURL, ClippyURLError> {
        ClippyURL.parse(URL(string: string)!)
    }

    func testValidActions() {
        XCTAssertEqual(try parse("clippy://search?q=hello%20world").get(), .search(query: "hello world"))
        XCTAssertEqual(try parse("clippy://get?id=42").get(), .get(id: 42))
        XCTAssertEqual(try parse("clippy://add?text=a%26b%2Bc").get(), .add(text: "a&b+c"))
        XCTAssertEqual(try parse("CLIPPY://Open").get(), .open)
        XCTAssertEqual(try parse("clippy://paste-latest").get(), .pasteLatest)
        XCTAssertEqual(try parse("clippy://settings/").get(), .settings)
        XCTAssertEqual(try parse("clippy://palette").get(), .palette)
    }

    func testRejections() {
        XCTAssertEqual(parse("https://search?q=a"), .failure(.wrongScheme))
        XCTAssertEqual(parse("clippy://delete?id=1"), .failure(.unknownAction))
        XCTAssertEqual(parse("clippy://search"), .failure(.missingParameter("q")))
        XCTAssertEqual(parse("clippy://search?q=a&x=1"), .failure(.unknownParameter("x")))
        XCTAssertEqual(parse("clippy://search?q=a&q=b"), .failure(.duplicateParameter("q")))
        XCTAssertEqual(parse("clippy://open?q=a"), .failure(.unknownParameter("q")))
        XCTAssertEqual(parse("clippy://open#frag"), .failure(.unexpectedPathOrFragment))
        XCTAssertEqual(parse("clippy://open/extra"), .failure(.unexpectedPathOrFragment))
        XCTAssertEqual(parse("clippy://user:pw@open"), .failure(.invalidParameter("url")))
    }

    func testIdValidationAndInjection() {
        for bad in ["0", "-1", "1.5", "abc", "", "1%20OR%201=1", "99999999999999999999", "%EF%BC%91"] {
            XCTAssertEqual(parse("clippy://get?id=\(bad)"), .failure(.invalidParameter("id")), bad)
        }
        XCTAssertEqual(parse("clippy://search?q=a%0Ab"), .failure(.invalidParameter("q")))
        XCTAssertEqual(parse("clippy://add?text=a%00b"), .failure(.invalidParameter("text")))
        XCTAssertEqual(parse("clippy://add?text="), .failure(.invalidParameter("text")))
        // Shell/SQL/path payloads are just text; the parser never interprets them.
        XCTAssertEqual(try parse("clippy://add?text=%27%3B%20DROP%20TABLE%20clips%3B--").get(),
                       .add(text: "'; DROP TABLE clips;--"))
    }

    func testSizeCaps() {
        let longQuery = String(repeating: "a", count: ClippyURL.maxQueryLength + 1)
        XCTAssertEqual(parse("clippy://search?q=\(longQuery)"), .failure(.tooLarge("q")))
        let atCap = String(repeating: "a", count: ClippyURL.maxTextBytes)
        XCTAssertNoThrow(try parse("clippy://add?text=\(atCap)").get())
        XCTAssertEqual(parse("clippy://add?text=\(atCap)a"), .failure(.tooLarge("text")))
    }

    func testRoundTrip() {
        for value in [ClippyURL.search(query: "a&b=c d+e#f%"), .add(text: "line\nbreak & 100%"), .get(id: 7), .palette] {
            XCTAssertEqual(try ClippyURL.parse(value.url).get(), value)
        }
    }

    func testConfirmationPolicy() {
        for action in ClippyURL.Action.allCases where !ClippyURLPolicy.isMutating(action) {
            XCTAssertEqual(ClippyURLPolicy.decision(for: action, allowWrites: false, approvedThisSession: false), .allow)
        }
        XCTAssertEqual(ClippyURLPolicy.decision(for: .add, allowWrites: false, approvedThisSession: false), .promptOnce)
        XCTAssertEqual(ClippyURLPolicy.decision(for: .pasteLatest, allowWrites: false, approvedThisSession: false), .promptOnce)
        XCTAssertEqual(ClippyURLPolicy.decision(for: .add, allowWrites: true, approvedThisSession: false), .allow)
        XCTAssertEqual(ClippyURLPolicy.decision(for: .add, allowWrites: false, approvedThisSession: true), .allow)
    }

    func testAutomationSettingsDefaultsOff() {
        let suite = UserDefaults(suiteName: "automation-test-\(UUID().uuidString)")!
        let settings = AutomationSettings(defaults: suite)
        XCTAssertFalse(settings.allowURLSchemeWrites)
        XCTAssertFalse(settings.spotlightIndexingEnabled)
        settings.spotlightIndexingEnabled = true
        XCTAssertTrue(AutomationSettings(defaults: suite).spotlightIndexingEnabled)
    }
}
