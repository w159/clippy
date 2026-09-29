import XCTest
@testable import Clippy

private final class RecordingStage: SuggestionSecondStage {
    private let lock = NSLock()
    private(set) var invocations = 0
    private(set) var lastInput: SecondStageInput?
    var output: SecondStageOutput?
    var delay: TimeInterval = 0

    private func record(_ input: SecondStageInput) {
        lock.lock(); invocations += 1; lastInput = input; lock.unlock()
    }

    func refine(_ input: SecondStageInput) async throws -> SecondStageOutput? {
        record(input)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return output
    }
}

final class SuggestionSecondStageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private lazy var clips = [
        makeIntelClip(1, "quarterly invoice payment terms", age: 60, now: now),
        makeIntelClip(2, "quarterly invoice payment overdue", age: 120, now: now),
        makeIntelClip(3, "quarterly invoice payment reference", age: 180, now: now),
    ]
    private var context: ScreenContext {
        ScreenContext(
            appName: "Mail", bundleID: "com.apple.mail", windowTitle: "Re: invoice",
            text: "quarterly invoice payment", capturedAt: now)
    }

    func testStageNeverInvokedWhenDisabled() {
        let stage = RecordingStage()
        stage.output = SecondStageOutput(orderedIDs: [3], reasons: [:])
        let engine = SuggestionEngine(
            embedder: LanguageStubEmbedder(), secondStage: stage, isSecondStageEnabled: { false })
        let base = SuggestionEngine(embedder: LanguageStubEmbedder())
            .rank(context: context, clips: clips, limit: 5, now: now)
        XCTAssertEqual(engine.rank(context: context, clips: clips, limit: 5, now: now), base)
        XCTAssertEqual(stage.invocations, 0)
    }

    func testFlagDefaultsToOff() {
        let saved = UserDefaults.standard.object(forKey: SuggestionTuning.useFoundationModelsKey)
        defer { UserDefaults.standard.set(saved, forKey: SuggestionTuning.useFoundationModelsKey) }
        UserDefaults.standard.removeObject(forKey: SuggestionTuning.useFoundationModelsKey)
        XCTAssertFalse(SuggestionTuning.useFoundationModels)
    }

    func testEnabledStageReordersAndRewritesReason() {
        let stage = RecordingStage()
        stage.output = SecondStageOutput(orderedIDs: [3, 99], reasons: [3: "Has the payment\nreference"])
        let engine = SuggestionEngine(
            embedder: LanguageStubEmbedder(), secondStage: stage, isSecondStageEnabled: { true })
        let ranked = engine.rank(context: context, clips: clips, limit: 5, now: now)
        XCTAssertEqual(ranked.first?.id, 3, "unknown id 99 is ignored")
        XCTAssertEqual(ranked.first?.reason, "Has the payment reference")
        XCTAssertEqual(Set(ranked.map(\.id)), [1, 2, 3], "nothing lost")
        XCTAssertEqual(stage.invocations, 1)
        // Prompt input holds only truncated previews and the app/title summary.
        XCTAssertEqual(stage.lastInput?.contextSummary, "Mail — Re: invoice")
        XCTAssertTrue(stage.lastInput?.items.allSatisfy { $0.preview.count <= SecondStageRunner.previewChars } ?? false)
    }

    func testTimeoutFallsBackToBaseRanking() {
        let stage = RecordingStage()
        stage.delay = 5
        stage.output = SecondStageOutput(orderedIDs: [3], reasons: [:])
        let base = SuggestionEngine(embedder: LanguageStubEmbedder())
            .rank(context: context, clips: clips, limit: 5, now: now)
        let started = Date()
        let result = SecondStageRunner.apply(
            to: base, contextSummary: "Mail", stage: stage, timeout: 0.2)
        XCTAssertEqual(result, base)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testStageErrorOrNilFallsBack() {
        struct Failing: SuggestionSecondStage {
            func refine(_ input: SecondStageInput) async throws -> SecondStageOutput? {
                throw CancellationError()
            }
        }
        let base = SuggestionEngine(embedder: LanguageStubEmbedder())
            .rank(context: context, clips: clips, limit: 5, now: now)
        XCTAssertEqual(SecondStageRunner.apply(to: base, contextSummary: "", stage: Failing()), base)
        let empty = RecordingStage()
        XCTAssertEqual(SecondStageRunner.apply(to: base, contextSummary: "", stage: empty), base)
    }

    func testSensitiveClipsAreNotSentToStage() {
        let stage = RecordingStage()
        let secret = makeIntelClip(4, "quarterly invoice payment card 4111 1111 1111 1111", age: 30, now: now)
        let pool = clips + [secret]
        let engine = SuggestionEngine(
            embedder: LanguageStubEmbedder(), secondStage: stage, isSecondStageEnabled: { true })
        _ = engine.rank(context: context, clips: pool, limit: 5, now: now)
        let sent = stage.lastInput?.items.map(\.id) ?? []
        if SensitiveContent.isSensitive(text: secret.contentText) {
            XCTAssertFalse(sent.contains(4))
        }
    }

    #if canImport(FoundationModels)
        func testFoundationModelsResponseParsing() {
            let text = "[2]: best match\n`1`: also relevant\nnonsense line\n2: duplicate\n7: unknown id"
            let output = FoundationModelsSecondStage.parse(text, allowed: [1, 2, 3])
            XCTAssertEqual(output?.orderedIDs, [2, 1])
            XCTAssertEqual(output?.reasons[2], "best match")
            XCTAssertNil(FoundationModelsSecondStage.parse("nothing useful", allowed: [1]))
        }
    #endif
}
