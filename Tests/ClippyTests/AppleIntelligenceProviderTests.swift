import XCTest
@testable import Clippy

/// Covers the pure parts of the Apple Intelligence bridge. The model itself is
/// not exercised: availability is a property of the machine (and of whether the
/// user has Apple Intelligence switched on), so a test that called it would pass
/// or fail for reasons unrelated to this code.
final class AppleIntelligenceProviderTests: XCTestCase {

    // MARK: - Prompt flattening

    /// Foundation Models takes one prompt string, not a role-tagged array. A
    /// single user turn must pass through untouched, or every one-shot call
    /// (titles, AI actions) picks up a stray "User:" prefix.
    func testSingleTurnIsPassedThroughVerbatim() {
        let flat = AppleIntelligenceProvider.flatten([
            AIMessage(role: .user, content: "swift build -c release")
        ])
        XCTAssertEqual(flat, "swift build -c release")
    }

    /// Multi-turn history has to stay labelled: without the labels the model
    /// cannot tell its own previous answers from the user's messages.
    func testMultiTurnHistoryIsLabelled() {
        let flat = AppleIntelligenceProvider.flatten([
            AIMessage(role: .user, content: "first"),
            AIMessage(role: .assistant, content: "second"),
            AIMessage(role: .user, content: "third"),
        ])
        XCTAssertEqual(flat, "User: first\n\nAssistant: second\n\nUser: third")
    }

    func testEmptyHistoryFlattensToEmptyString() {
        XCTAssertEqual(AppleIntelligenceProvider.flatten([]), "")
    }
}
