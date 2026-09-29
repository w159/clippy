import XCTest

@testable import Clippy

/// FEAT-13: copy-twice-to-append decision and merge separators.
final class ClipAppendPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var previous: ClipAppendPolicy.Previous {
        .init(clipID: 7, date: start, bundleID: "com.app.a", text: "one")
    }

    private func decide(_ text: String = "two", bundle: String? = "com.app.a", sensitive: Bool = false, after: TimeInterval = 1,
                        enabled: Bool = true, prior: ClipAppendPolicy.Previous? = nil, merged: @escaping (String) -> Bool = { _ in false }) -> ClipAppendPolicy.Decision {
        ClipAppendPolicy.decide(previous: prior ?? previous, incomingText: text, incomingBundleID: bundle, incomingIsSensitive: sensitive,
                                now: start.addingTimeInterval(after), window: 1.5, separator: "\n", enabled: enabled, mergedIsSensitive: merged)
    }

    func testAppendsInsideWindowFromSameApp() {
        XCTAssertEqual(decide(), .append(clipID: 7, merged: "one\ntwo"))
        XCTAssertEqual(decide(after: 1.5), .append(clipID: 7, merged: "one\ntwo"))
    }

    func testInsertsNewOutsideWindowOrClockSkew() {
        XCTAssertEqual(decide(after: 1.6), .insertNew)
        XCTAssertEqual(decide(after: -1), .insertNew)
    }

    func testDifferentOrUnknownAppInserts() {
        XCTAssertEqual(decide(bundle: "com.app.b"), .insertNew)
        XCTAssertEqual(decide(bundle: nil), .insertNew)
        let unknownPrev = ClipAppendPolicy.Previous(clipID: 1, date: start, bundleID: nil, text: "one")
        XCTAssertEqual(decide(bundle: nil, prior: unknownPrev), .insertNew)
    }

    func testSensitiveAndDisabledAndRecopyInsert() {
        XCTAssertEqual(decide(sensitive: true), .insertNew)
        XCTAssertEqual(decide(merged: { _ in true }), .insertNew)
        XCTAssertEqual(decide(enabled: false), .insertNew)
        XCTAssertEqual(decide("one"), .insertNew)
        XCTAssertEqual(decide("  \n"), .insertNew)
    }

    func testNoPreviousInserts() {
        XCTAssertEqual(ClipAppendPolicy.decide(previous: nil, incomingText: "x", incomingBundleID: "a", incomingIsSensitive: false,
                                               now: start, window: 1.5, separator: "\n", enabled: true), .insertNew)
    }

    func testMergeSeparatorsAndSensitiveFiltering() {
        func clip(_ text: String) -> Clip {
            Clip(id: 1, contentText: text, contentRTF: nil, contentHTML: nil, typeIdentifier: "public.utf8-plain-text",
                 sourceAppBundleID: nil, sourceAppName: nil, createdAt: Date())
        }
        let clips = [clip("a"), clip("  "), clip("b"), clip("secret")]
        let safe = ClipMergeActions.eligible(clips, isSensitive: { $0.contentText == "secret" })
        XCTAssertEqual(ClipMerge.mergedText(safe, separator: MergeSeparator.comma.text), "a, b")
        XCTAssertEqual(ClipMerge.mergedText(safe, separator: MergeSeparator.blankLine.text), "a\n\nb")
        XCTAssertEqual(ClipMerge.mergedText(safe, separator: MergeSeparator.tab.text), "a\tb")
        XCTAssertNil(ClipMerge.mergedText([clip(" ")]))
    }

    func testTrackerChainsAppendsAndForgetsOnSensitive() {
        let suite = UserDefaults(suiteName: "append-tests-\(UUID().uuidString)")!
        let saved = CapturePreferences.defaults
        CapturePreferences.defaults = suite
        defer { CapturePreferences.defaults = saved }
        AppendPreferences.isEnabled = true
        let tracker = ClipAppendTracker()
        tracker.recordSaved(clipID: 3, text: "a", bundleID: "x", date: start, sensitive: false)
        XCTAssertEqual(tracker.evaluate(text: "b", bundleID: "x", sensitive: false, now: start.addingTimeInterval(1)),
                       .append(clipID: 3, merged: "a\nb"))
        XCTAssertEqual(tracker.evaluate(text: "c", bundleID: "x", sensitive: false, now: start.addingTimeInterval(2)),
                       .append(clipID: 3, merged: "a\nb\nc"))
        tracker.recordSaved(clipID: 4, text: "s", bundleID: "x", date: start, sensitive: true)
        XCTAssertEqual(tracker.evaluate(text: "d", bundleID: "x", sensitive: false, now: start.addingTimeInterval(1)), .insertNew)
    }
}
