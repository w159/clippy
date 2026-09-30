import XCTest
@testable import Clippy

/// Records the messages it was asked to complete and returns a canned reply, so
/// AIService's prompt construction and response handling are tested without a
/// network or any real provider.
final class MockAIProvider: AIProvider {
    var response: String
    var error: Error?
    private(set) var lastMessages: [AIMessage] = []
    private(set) var lastOptions: AICompletionOptions?

    init(response: String = "", error: Error? = nil) {
        self.response = response
        self.error = error
    }

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        lastMessages = messages
        lastOptions = options
        if let error { throw error }
        return response
    }
}

@MainActor
final class AITests: XCTestCase {

    // MARK: - Pure response shaping

    func testSanitizeTitleStripsQuotesAndTrailingPunctuation() {
        XCTAssertEqual(AIService.sanitizeTitle("\"Quarterly Report\""), "Quarterly Report")
        XCTAssertEqual(AIService.sanitizeTitle("Build the app."), "Build the app")
        XCTAssertEqual(AIService.sanitizeTitle("  Spaces around  "), "Spaces around")
        XCTAssertEqual(AIService.sanitizeTitle("Line one\nLine two"), "Line one Line two")
    }

    func testSanitizeTitleTruncatesToEightyChars() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(AIService.sanitizeTitle(long).count, 80)
    }

    func testMatchCategoryExactCaseInsensitiveAndNone() {
        let cats = ["Work", "Personal", "Code Snippets"]
        XCTAssertEqual(AIService.matchCategory("Work", to: cats), "Work")
        XCTAssertEqual(AIService.matchCategory("personal", to: cats), "Personal")
        XCTAssertEqual(AIService.matchCategory("the Code Snippets bucket", to: cats), "Code Snippets")
        XCTAssertNil(AIService.matchCategory("NONE", to: cats))
        XCTAssertNil(AIService.matchCategory("   ", to: cats))
        XCTAssertNil(AIService.matchCategory("Finance", to: cats))
    }

    // MARK: - Provider-driven actions

    func testSuggestTitleSendsSystemAndUserAndSanitizes() async throws {
        let mock = MockAIProvider(response: "  \"My Snippet\".  ")
        let service = AIService(provider: mock)
        let proposal = try await service.suggestTitle(forText: "some clipboard text")

        XCTAssertEqual(proposal.kind, .title)
        XCTAssertEqual(proposal.proposed, "My Snippet")
        XCTAssertEqual(mock.lastMessages.first?.role, .system)
        XCTAssertEqual(mock.lastMessages.last?.role, .user)
        XCTAssertEqual(mock.lastMessages.last?.content, "some clipboard text")
    }

    func testRewriteIncludesInstructionInPrompt() async throws {
        let mock = MockAIProvider(response: "rewritten output")
        let service = AIService(provider: mock)
        let proposal = try await service.rewrite("hello world", instruction: "make it formal")

        XCTAssertEqual(proposal.kind, .rewrite)
        XCTAssertEqual(proposal.original, "hello world")
        XCTAssertEqual(proposal.proposed, "rewritten output")
        XCTAssertTrue(mock.lastMessages.last?.content.contains("make it formal") ?? false)
        XCTAssertTrue(mock.lastMessages.last?.content.contains("hello world") ?? false)
    }

    func testSuggestCategoryReturnsNilForEmptyListWithoutCallingProvider() async throws {
        let mock = MockAIProvider(response: "Work")
        let service = AIService(provider: mock)
        let proposal = try await service.suggestCategory(forText: "x", categories: [])
        XCTAssertNil(proposal)
        XCTAssertTrue(mock.lastMessages.isEmpty, "must not call the provider when there are no categories")
    }

    func testSuggestCategoryMapsBackToProvidedName() async throws {
        let mock = MockAIProvider(response: "work")
        let service = AIService(provider: mock)
        let proposal = try await service.suggestCategory(forText: "git commit", categories: ["Work", "Home"])
        XCTAssertEqual(proposal?.proposed, "Work")
    }

    func testSuggestCategoryReturnsNilOnNone() async throws {
        let mock = MockAIProvider(response: "NONE")
        let service = AIService(provider: mock)
        let proposal = try await service.suggestCategory(forText: "x", categories: ["Work"])
        XCTAssertNil(proposal)
    }

    // MARK: - Settings wiring

    func testFromSettingsFailsWhenDisabled() {
        let settings = AppSettings.shared
        let previous = settings.aiEnabled
        defer { settings.aiEnabled = previous }
        settings.aiEnabled = false

        switch AIService.fromSettings(settings) {
        case .success: XCTFail("AI should be unavailable when disabled")
        case .failure(let error):
            if case .notConfigured = error {} else { XCTFail("expected notConfigured, got \(error)") }
        }
    }

    func testFromSettingsSucceedsForLocalOllamaWithoutKey() {
        let settings = AppSettings.shared
        let prevEnabled = settings.aiEnabled
        defer { settings.aiEnabled = prevEnabled }
        settings.aiEnabled = true
        let suiteName = "test.aitests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = AIProviderStore(defaults: suite,
                                    secrets: .inMemory(), isForced: { _ in false })
        suite.set(true, forKey: "aiEnabled")
        store.setActive(store.add(descriptorID: "ollama-local").id)

        switch AIService.fromSettings(settings, store: store) {
        case .success: break // Ollama is local and needs no key
        case .failure(let error): XCTFail("local Ollama should configure without a key: \(error)")
        }
    }

    func testLeakedReasoningIsNotSavedAsTitle() async throws {
        let leaked = "The user has sent me a message that appears to be a pangram. I should title it."
        let provider = MockAIProvider(response: leaked)
        do {
            _ = try await AIService(provider: provider).suggestTitle(forText: "The quick brown fox")
            XCTFail("Leaked reasoning must not become a title")
        } catch { XCTAssertTrue(error is AIError) }
        let good = MockAIProvider(response: "Quick Brown Fox Story")
        let proposal = try await AIService(provider: good).suggestTitle(forText: "The quick brown fox")
        XCTAssertEqual(proposal.proposed, "Quick Brown Fox Story")
        XCTAssertFalse(AIService.isPlausibleTitle("One. Two sentences here"))
    }

}
