import XCTest
@testable import Clippy

final class AssistantPresentationTests: XCTestCase {
    private func message(_ role: AssistantMessage.Role, _ text: String = "hi", error: Bool = false,
                         steps: [AssistantToolStep] = []) -> AssistantMessage {
        AssistantMessage(role: role, text: text, isError: error, toolSteps: steps)
    }

    func testErrorKindWinsOverRole() {
        XCTAssertEqual(AssistantPresentation.kind(of: message(.assistant, error: true)), .error)
        XCTAssertEqual(AssistantPresentation.kind(of: message(.user)), .user)
        XCTAssertEqual(AssistantPresentation.kind(of: message(.assistant)), .assistant)
    }

    func testGroupPositionsFollowRuns() {
        let list = [message(.user), message(.assistant), message(.assistant), message(.assistant), message(.user)]
        let positions = AssistantPresentation.groupPositions(list)
        XCTAssertEqual(positions[list[0].id], .single)
        XCTAssertEqual(positions[list[1].id], .first)
        XCTAssertEqual(positions[list[2].id], .middle)
        XCTAssertEqual(positions[list[3].id], .last)
        XCTAssertEqual(positions[list[4].id], .single)
    }

    func testErrorBreaksAssistantRun() {
        let list = [message(.assistant), message(.assistant, error: true)]
        let positions = AssistantPresentation.groupPositions(list)
        XCTAssertEqual(positions[list[0].id], .single)
        XCTAssertEqual(positions[list[1].id], .single)
    }

    func testAccessibilityLabelCountsToolSteps() {
        let step = AssistantToolStep(id: "1", name: "search_clips", isRunning: false)
        XCTAssertEqual(AssistantPresentation.accessibilityLabel(for: message(.assistant, "Found 2", steps: [step])),
                       "Assistant: Found 2. 1 tool step")
        XCTAssertEqual(AssistantPresentation.accessibilityLabel(for: message(.user, "find")), "You: find")
        XCTAssertEqual(AssistantPresentation.accessibilityLabel(for: message(.assistant, "Boom", error: true)), "Error: Boom")
    }

    func testArgumentKeysNeverExposeValues() {
        let json = "{\n  \"query\" : \"secret password\",\n  \"limit\" : 5\n}"
        XCTAssertEqual(AssistantPresentation.argumentKeys(from: json), ["limit", "query"])
        XCTAssertEqual(AssistantPresentation.argumentKeys(from: ""), [])
        XCTAssertEqual(AssistantPresentation.argumentKeys(from: "not json"), [])
    }

    func testResultSummaryDescribesSizeOnly() {
        XCTAssertEqual(AssistantPresentation.resultSummary(nil), "No result yet")
        XCTAssertEqual(AssistantPresentation.resultSummary("  \n"), "Empty result")
        XCTAssertEqual(AssistantPresentation.resultSummary("one"), "1 line, 3 characters")
        XCTAssertEqual(AssistantPresentation.resultSummary("a\n\nb"), "2 lines, 4 characters")
    }

    func testStepSubtitleFallsBackWhenNoArguments() {
        var step = AssistantToolStep(id: "1", name: "list", isRunning: true)
        XCTAssertEqual(AssistantPresentation.stepSubtitle(step), "no arguments")
        XCTAssertEqual(AssistantPresentation.stepTitle(step), "Running list")
        step.arguments = "{\"b\":1,\"a\":2}"
        step.isRunning = false
        XCTAssertEqual(AssistantPresentation.stepSubtitle(step), "a, b")
        XCTAssertEqual(AssistantPresentation.stepTitle(step), "Ran list")
    }

    func testUsageLabelsHideEmptyUsage() {
        XCTAssertNil(AssistantPresentation.turnUsageLabel(nil))
        XCTAssertNil(AssistantPresentation.turnUsageLabel(AIUsage()))
        XCTAssertNil(AssistantPresentation.conversationUsageLabel(AIUsage()))
        let usage = AIUsage(promptTokens: 1000, completionTokens: 292)
        XCTAssertEqual(AssistantPresentation.conversationUsageLabel(usage), "1,292 tokens")
        XCTAssertEqual(AssistantPresentation.turnUsageLabel(usage), usage.summary)
    }

    func testSuggestionsRespectProviderCapability() {
        let noTools = AssistantPresentation.suggestions(toolsSupported: false, hasAttachedClip: false)
        XCTAssertFalse(noTools.contains { $0.localizedCaseInsensitiveContains("search") || $0.localizedCaseInsensitiveContains("create") })
        XCTAssertFalse(noTools.isEmpty)
        let withClip = AssistantPresentation.suggestions(toolsSupported: false, hasAttachedClip: true)
        XCTAssertTrue(withClip.contains("Summarize the attached clip"))
        let full = AssistantPresentation.suggestions(toolsSupported: true, hasAttachedClip: false)
        XCTAssertTrue(full.contains("Search my clips for meeting notes"))
        XCTAssertFalse(full.contains("Summarize the attached clip"))
    }

    func testCompletionAnnouncementNeverEchoesReplyText() {
        let step = AssistantToolStep(id: "1", name: "x", isRunning: false)
        XCTAssertEqual(AssistantPresentation.completionAnnouncement(for: message(.assistant, "secret", steps: [step])),
                       "Assistant replied after 1 tool step")
        XCTAssertEqual(AssistantPresentation.completionAnnouncement(for: message(.assistant, "secret")), "Assistant replied")
        XCTAssertEqual(AssistantPresentation.completionAnnouncement(for: nil), "Assistant finished responding")
    }

    func testCanSendRejectsWhitespace() {
        XCTAssertFalse(AssistantPresentation.canSend(" \n "))
        XCTAssertTrue(AssistantPresentation.canSend(" hi "))
    }

    func testStepStatusFromLoopResult() {
        func step(_ result: String?, running: Bool = false) -> AssistantToolStep {
            AssistantToolStep(id: "s", name: "t", result: result, isRunning: running)
        }
        XCTAssertEqual(AssistantPresentation.status(of: step(nil, running: true)), .running)
        XCTAssertEqual(AssistantPresentation.status(of: step("ok")), .done)
        XCTAssertEqual(AssistantPresentation.status(of: step("Tool error: boom")), .failed)
        XCTAssertEqual(AssistantPresentation.status(of: step("Error: unknown tool \"x\".")), .failed)
    }

    func testChecklistMarksFirstRunningStep() {
        let steps = [AssistantToolStep(id: "a", name: "a", result: "x", isRunning: false),
                     AssistantToolStep(id: "b", name: "b", isRunning: true),
                     AssistantToolStep(id: "c", name: "c", isRunning: true)]
        XCTAssertEqual(AssistantPresentation.activeStepIndex(steps), 1)
        XCTAssertEqual(AssistantPresentation.checklistHeader(steps), "1 of 3 steps")
        XCTAssertNil(AssistantPresentation.activeStepIndex([steps[0]]))
    }

    func testApprovalKeysMapToChoices() {
        XCTAssertEqual(AssistantPresentation.ApprovalChoice.choice(forKey: "1"), .allowOnce)
        XCTAssertEqual(AssistantPresentation.ApprovalChoice.choice(forKey: "2"), .allowAlways)
        XCTAssertEqual(AssistantPresentation.ApprovalChoice.choice(forKey: "3"), .deny)
        XCTAssertNil(AssistantPresentation.ApprovalChoice.choice(forKey: "4"))
    }
}
