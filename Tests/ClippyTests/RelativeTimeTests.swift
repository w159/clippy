import XCTest
@testable import Clippy

/// `Date.RelativeFormatStyle` renders a just-created timestamp as "in 0s",
/// future tense, which is what every fresh clip card showed.
final class RelativeTimeTests: XCTestCase {
    func testJustCreatedReadsAsNow() {
        let now = Date()
        XCTAssertEqual(RelativeTime.string(for: now, relativeTo: now), "now")
        XCTAssertEqual(RelativeTime.string(for: now.addingTimeInterval(-0.4), relativeTo: now), "now")
        XCTAssertEqual(RelativeTime.string(for: now.addingTimeInterval(-59), relativeTo: now), "now")
    }

    /// Clock skew between two Macs sharing an iCloud archive can hand us a
    /// createdAt in the future. That must read as "now", never count down.
    func testFutureTimestampReadsAsNow() {
        let now = Date()
        XCTAssertEqual(RelativeTime.string(for: now.addingTimeInterval(120), relativeTo: now), "now")
    }

    func testOlderThanAMinuteUsesTheRelativeStyle() {
        let now = Date()
        let rendered = RelativeTime.string(for: now.addingTimeInterval(-3600), relativeTo: now)
        XCTAssertNotEqual(rendered, "now")
        XCTAssertFalse(rendered.contains("0s"), "the 'in 0s' shape must not come back")
    }
}
