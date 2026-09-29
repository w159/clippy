import XCTest
@testable import Clippy

final class OCRWarmupPolicyTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var warmCount = 0

    private func makePolicy(interval: TimeInterval = 600) -> OCRWarmupPolicy {
        OCRWarmupPolicy(minimumInterval: interval, now: { self.clock }, warm: { self.warmCount += 1 })
    }

    func testRateLimitedToOncePerInterval() {
        let policy = makePolicy()
        XCTAssertTrue(policy.requestWarmup())
        clock.addTimeInterval(599)
        XCTAssertFalse(policy.requestWarmup())
        clock.addTimeInterval(1)
        XCTAssertTrue(policy.requestWarmup(), "exactly at the interval a new warm-up is allowed")
        XCTAssertEqual(warmCount, 2)
    }

    func testPanelDidShowIsNoOpWithoutImageClips() {
        let policy = makePolicy()
        policy.panelDidShow()
        XCTAssertEqual(warmCount, 0)
        policy.hasImageClips = { true }
        policy.panelDidShow()
        XCTAssertEqual(warmCount, 1)
    }

    func testNoteImageVisibleWarmsOnceThenThrottles() {
        let policy = makePolicy()
        policy.noteImageVisible()
        policy.noteImageVisible()
        XCTAssertEqual(warmCount, 1)
    }

    func testSkippedPanelShowDoesNotConsumeRateLimit() {
        let policy = makePolicy()
        policy.panelDidShow()
        policy.noteImageVisible()
        XCTAssertEqual(warmCount, 1)
    }

    func testResetAllowsImmediateWarmup() {
        let policy = makePolicy()
        policy.noteImageVisible()
        policy.reset()
        XCTAssertTrue(policy.requestWarmup())
    }
}
