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

    // MARK: - Provider metadata

    /// Auto-titling runs on every copy, so it is gated on `runsLocally`. If a
    /// hosted provider ever answers true here, every password and client record
    /// that passes through the clipboard gets posted to a third party.
    func testOnlyLocalProvidersReportRunningLocally() {
        XCTAssertTrue(AIProviderKind.appleIntelligence.runsLocally)
        XCTAssertTrue(AIProviderKind.ollama.runsLocally)
        for hosted in [AIProviderKind.openai, .anthropic, .azureFoundry] {
            XCTAssertFalse(hosted.runsLocally, "\(hosted) is hosted and must not count as local")
        }
    }

    func testAppleIntelligenceNeedsNoKeyOrEndpoint() {
        XCTAssertFalse(AIProviderKind.appleIntelligence.needsAPIKey)
        XCTAssertFalse(AIProviderKind.appleIntelligence.needsEndpointConfiguration)
        XCTAssertTrue(AIProviderKind.openai.needsAPIKey)
        XCTAssertTrue(AIProviderKind.openai.needsEndpointConfiguration)
    }

    /// The factories switch exhaustively over the kind; a new case that is not
    /// wired up would compile but hand back the wrong provider.
    func testFactoriesReturnTheAppleIntelligenceProvider() {
        let config = AIProviderConfig(baseURL: "", apiKey: "", model: "system")
        XCTAssertTrue(
            AIProviderFactory.make(kind: .appleIntelligence, config: config)
                is AppleIntelligenceProvider
        )
        XCTAssertTrue(
            AIAgentProviderFactory.make(kind: .appleIntelligence, config: config)
                is AppleIntelligenceProvider
        )
    }

    /// `endpointConfigError` is what Settings and AIService.fromSettings use to
    /// refuse a misconfigured provider. For Apple Intelligence it reports the
    /// machine's availability, so it must agree with it in both directions.
    func testEndpointConfigErrorTracksAvailability() {
        let reported = AIProviderKind.appleIntelligence.endpointConfigError("")
        XCTAssertEqual(reported, AppleIntelligence.availability.reason)
        if AppleIntelligence.availability.isAvailable {
            XCTAssertNil(reported)
        } else {
            XCTAssertNotNil(reported)
        }
    }
}
