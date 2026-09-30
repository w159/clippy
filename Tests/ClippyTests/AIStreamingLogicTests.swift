import XCTest
@testable import Clippy

final class AIStreamingLogicTests: XCTestCase {
    func testSnapshotDiffAppendsOnlySuffix() {
        XCTAssertEqual(AISnapshotDiff.step(emitted: "Hel", snapshot: "Hello"), .append("lo"))
        XCTAssertEqual(AISnapshotDiff.step(emitted: "", snapshot: "Hi"), .append("Hi"))
        XCTAssertEqual(AISnapshotDiff.step(emitted: "Hi", snapshot: "Hi"), .none)
    }

    func testRevisedSnapshotReplacesInsteadOfDuplicating() {
        XCTAssertEqual(AISnapshotDiff.step(emitted: "Hello wor", snapshot: "Hi there"),
                       .replace(old: "Hello wor", new: "Hi there"))
        // Shrinking snapshot is a revision too, not a no-op.
        XCTAssertEqual(AISnapshotDiff.step(emitted: "Hello", snapshot: "Hell"),
                       .replace(old: "Hello", new: "Hell"))
    }

    func testStreamedTextEqualsFinalSnapshotAfterRevision() {
        var text = ""
        var emitted = ""
        for snapshot in ["The", "The cat", "A dog", "A dog ran"] {
            switch AISnapshotDiff.step(emitted: emitted, snapshot: snapshot) {
            case .none: break
            case .append(let suffix): text += suffix
            case .replace(let old, let new): text = AITextReplace.apply(to: text, old: old, new: new)
            }
            emitted = snapshot
        }
        XCTAssertEqual(text, "A dog ran")
    }

    func testTextReplaceOnlySwapsTrailingSegment() {
        XCTAssertEqual(AITextReplace.apply(to: "Ran tool. Draft", old: "Draft", new: "Final"), "Ran tool. Final")
        XCTAssertEqual(AITextReplace.apply(to: "abc", old: "zzz", new: "new"), "abcnew")
    }

    func testOpenAIStreamReportsUsage() throws {
        var parser = AIResponseStreamParser(family: .openaiChat)
        var events = try parser.consume(line: "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}")
        events += try parser.consume(line: "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":5}}")
        events += try parser.consume(line: "")
        events += try parser.consume(line: "data: [DONE]")
        events += try parser.finish()
        let usage = events.compactMap { event -> AIUsage? in
            if case .usage(let usage) = event { return usage }
            return nil
        }
        XCTAssertEqual(usage, [AIUsage(promptTokens: 12, completionTokens: 5)])
    }

    func testOllamaStreamReportsUsageOnDoneLine() throws {
        var parser = AIResponseStreamParser(family: .ollamaChat)
        var events = try parser.consume(line: "{\"message\":{\"content\":\"Hello\"},\"done\":true,\"prompt_eval_count\":9,\"eval_count\":3}")
        events += try parser.finish()
        let usage = events.compactMap { event -> AIUsage? in
            if case .usage(let usage) = event { return usage }
            return nil
        }
        XCTAssertEqual(usage, [AIUsage(promptTokens: 9, completionTokens: 3)])
    }

    // MARK: Word diff

    func testWordDiffMarksOnlyChangedWords() {
        let spans = AIWordDiff.diff(old: "the quick brown fox", new: "the slow brown fox")
        XCTAssertEqual(spans, [
            .init(kind: .same, text: "the "),
            .init(kind: .removed, text: "quick"),
            .init(kind: .added, text: "slow"),
            .init(kind: .same, text: " brown fox"),
        ])
    }

    func testWordDiffReassemblesBothSides() {
        let old = "one two  three\nfour", new = "one three\nfour five"
        let spans = AIWordDiff.diff(old: old, new: new)
        XCTAssertEqual(spans.filter { $0.kind != .added }.map(\.text).joined(), old)
        XCTAssertEqual(spans.filter { $0.kind != .removed }.map(\.text).joined(), new)
    }

    func testWordDiffIdenticalAndEmpty() {
        XCTAssertEqual(AIWordDiff.diff(old: "same", new: "same"), [.init(kind: .same, text: "same")])
        XCTAssertEqual(AIWordDiff.diff(old: "", new: ""), [])
        XCTAssertEqual(AIWordDiff.diff(old: "", new: "new"), [.init(kind: .added, text: "new")])
    }

    // MARK: Proposal shaping (AI-10)

    func testDiffIsShownOnlyForInPlaceRewrites() {
        var action = AIAction.builtIns[0]
        for (disposition, expected) in [(AIActionOutputDisposition.proposeEdit, true),
                                        (.newClip, false), (.copyToClipboard, false)] {
            action.outputDisposition = disposition
            let proposal = AIService.proposal(for: action, clipText: "src", output: "out")
            XCTAssertEqual(proposal.showsDiff, expected, "\(disposition)")
            XCTAssertEqual(proposal.original, "src", "source text stays available")
            XCTAssertEqual(proposal.proposed, "out")
        }
        let summary = AIProposal(kind: .summary, label: "Summary", original: "src", proposed: "s")
        XCTAssertFalse(summary.showsDiff)
    }

    // MARK: Context budget

    func testContextBudgetDropsOldestTurnsButKeepsSystemAndNewest() {
        let messages = [
            AIMessage(role: .system, content: "sys"),
            AIMessage(role: .user, content: String(repeating: "a", count: 300)),
            AIMessage(role: .assistant, content: String(repeating: "b", count: 300)),
            AIMessage(role: .user, content: "latest"),
        ]
        let fitted = AIContextBudget.fit(messages, budgetTokens: 50)
        XCTAssertEqual(fitted.first?.content, "sys")
        XCTAssertEqual(fitted.last?.content, "latest")
        XCTAssertEqual(fitted.count, 2)
    }

    func testContextBudgetElidesOversizedSingleMessage() {
        let big = String(repeating: "x", count: 3000)
        let fitted = AIContextBudget.fit([AIMessage(role: .user, content: big)], budgetTokens: 200)
        XCTAssertLessThanOrEqual(AIContextBudget.estimateTokens(fitted[0].content), 260)
        XCTAssertTrue(fitted[0].content.contains("omitted"))
    }

    func testContextBudgetLeavesSmallConversationsAlone() {
        let messages = [AIMessage(role: .user, content: "hi")]
        XCTAssertEqual(AIContextBudget.fit(messages, budgetTokens: 1000), messages)
    }
}
