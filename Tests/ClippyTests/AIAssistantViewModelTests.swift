import XCTest
@testable import Clippy

/// Scripted provider: each round is a list of events; `gate` lets a test hold a
/// round open mid-stream.
private final class ScriptedProvider: AIAgentProvider, @unchecked Sendable {
    var rounds: [[AIStreamEvent]]
    var seenMessages: [[AIMessage]] = []
    var hold = false
    var failures: [AIError?] = []
    private var index = 0
    init(rounds: [[AIStreamEvent]]) { self.rounds = rounds }

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String { "summary" }
    func completeWithTools(_ messages: [AIMessage], tools: [AITool], options: AICompletionOptions) async throws -> AIAgentTurn { .text("x") }

    func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                         options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
        seenMessages.append(messages)
        let events = index < rounds.count ? rounds[index] : []
        let failure = index < failures.count ? failures[index] : nil
        index += 1
        let hold = self.hold
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    continuation.yield(event)
                    if hold { try? await Task.sleep(for: .milliseconds(400)) }
                }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.yield(.done)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct EchoTool: AITool {
    let name: String
    let description = "echo"
    let parametersSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]
    func execute(args: [String: Any]) async throws -> String { "echoed" }
}

@MainActor
final class AIAssistantViewModelTests: XCTestCase {
    private func makeEnv(provider: AIAgentProvider, supportsTools: Bool = true,
                         tools: [AITool] = [], store: AIConversationStore? = nil) -> AIAssistantEnvironment {
        let defaults = UserDefaults(suiteName: "ai-vm-tests-\(UUID().uuidString)")!
        return AIAssistantEnvironment(
            makeProvider: { .success(provider) },
            supportsTools: { supportsTools },
            providerName: { "Test" },
            baseTools: { tools },
            policyStore: AIToolPolicyStore(defaults: defaults),
            conversationStore: store)
    }

    private func call(_ id: String = "c1") -> AIToolCall {
        AIToolCall(id: id, toolName: "echo", arguments: ["k": "v"])
    }

    func testClearDuringStreamDoesNotCrashAndLeavesCleanState() async {
        let provider = ScriptedProvider(rounds: [[.textDelta("one "), .textDelta("two "), .textDelta("three")]])
        provider.hold = true
        let vm = AIAssistantViewModel(env: makeEnv(provider: provider))
        vm.inputText = "hello"
        vm.send()
        try? await Task.sleep(for: .milliseconds(100))
        vm.clearConversation()
        await vm.waitForTurn()
        try? await Task.sleep(for: .milliseconds(900))   // stale task unwinds
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(vm.transcript.count, 0)
        XCTAssertEqual(vm.state, .ready)
    }

    func testStaleTurnDoesNotCorruptNextConversation() async {
        let provider = ScriptedProvider(rounds: [[.textDelta("old"), .textDelta(" old")], [.textDelta("fresh")]])
        provider.hold = true
        let vm = AIAssistantViewModel(env: makeEnv(provider: provider))
        vm.inputText = "first"
        vm.send()
        try? await Task.sleep(for: .milliseconds(100))
        vm.clearConversation()
        provider.hold = false
        vm.inputText = "second"
        vm.send()
        await vm.waitForTurn()
        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(vm.messages.map(\.text), ["second", "fresh"])
        XCTAssertEqual(vm.transcript.entries, [.user("second"), .assistant("fresh")])
    }

    func testToolTurnIsRecordedStructurallyAndReplayed() async {
        let provider = ScriptedProvider(rounds: [[.toolCalls([call()])], [.textDelta("done")], [.textDelta("ok")]])
        let vm = AIAssistantViewModel(env: makeEnv(provider: provider, tools: [EchoTool(name: "echo")]))
        vm.inputText = "go"
        vm.send()
        await vm.waitForTurn()
        XCTAssertEqual(vm.transcript.entries.count, 4)
        guard case .toolCall(let recorded) = vm.transcript.entries[1] else { return XCTFail("expected tool call") }
        XCTAssertEqual(recorded.id, "c1")
        XCTAssertEqual(vm.transcript.entries[2], .toolResult(id: "c1", name: "echo", result: "echoed"))
        XCTAssertEqual(vm.transcript.entries[3], .assistant("done"))
        XCTAssertEqual(vm.messages[1].toolSteps.first?.result, "echoed")

        vm.inputText = "again"
        vm.send()
        await vm.waitForTurn()
        let replay = provider.seenMessages.last ?? []
        XCTAssertTrue(replay.contains { AIToolCallsSentinel.decode($0.content) != nil })
        XCTAssertTrue(replay.contains { AIToolResultSentinel.decode($0.content)?.result == "echoed" })
        XCTAssertFalse(replay.contains { $0.content.hasPrefix("Ran ") })
    }

    func testErrorBubbleNeverEntersTranscriptAndRetryRollsBack() async {
        let provider = ScriptedProvider(rounds: [[], [.textDelta("recovered")]])
        let vm = AIAssistantViewModel(env: makeEnv(provider: provider))
        vm.inputText = "q"
        vm.send()
        await vm.waitForTurn()
        XCTAssertTrue(vm.messages[1].isError)
        XCTAssertEqual(vm.transcript.count, 0, "failed turn rolled back")

        vm.retryTurn(forError: vm.messages[1].id)
        await vm.waitForTurn()
        XCTAssertEqual(vm.messages.map(\.text), ["q", "recovered"])
        XCTAssertEqual(vm.transcript.entries, [.user("q"), .assistant("recovered")])
        XCTAssertFalse(provider.seenMessages.last!.contains { $0.content.contains("empty response") })
    }

    func testProviderFailureBeforeTextSurfacesWithoutAgentRetry() async {
        let provider = ScriptedProvider(rounds: [[], [.textDelta("Must not silently recover")]])
        provider.failures = [.http(503, "Unavailable"), nil]
        let vm = AIAssistantViewModel(env: makeEnv(provider: provider))
        vm.inputText = "question"
        vm.send()
        await vm.waitForTurn()

        XCTAssertTrue(vm.messages[1].isError)
        XCTAssertTrue(vm.messages[1].text.contains("503"))
        XCTAssertFalse(vm.messages[1].text.contains("Must not silently recover"))
        XCTAssertEqual(vm.transcript.entries, [])
    }

    func testInterruptedReplyPreservesPartialTextAndRetryDoesNotReplayIt() async {
        let provider = ScriptedProvider(rounds: [[.textDelta("Partial answer")], [.textDelta("Recovered answer")]])
        provider.failures = [.decoding("Connection lost"), nil]
        let vm = AIAssistantViewModel(env: makeEnv(provider: provider))
        vm.inputText = "question"
        vm.send()
        await vm.waitForTurn()

        XCTAssertTrue(vm.messages[1].text.hasPrefix("Partial answer\n\n[Interrupted]"))
        XCTAssertTrue(vm.messages[1].text.contains("Connection lost"))
        XCTAssertTrue(vm.messages[1].isError)
        XCTAssertEqual(vm.transcript.entries, [])

        vm.retryTurn(forError: vm.messages[1].id)
        await vm.waitForTurn()
        XCTAssertEqual(vm.messages.map(\.text), ["question", "Recovered answer"])
        XCTAssertEqual(vm.transcript.entries, [.user("question"), .assistant("Recovered answer")])
        XCTAssertFalse(provider.seenMessages.last!.contains { $0.content.contains("Partial answer") })
    }

    func testInterruptedReplyKeepsCompletedToolResultButNotPartialFinalAnswer() async {
        let provider = ScriptedProvider(rounds: [[.toolCalls([call()])], [.textDelta("Incomplete final answer")]])
        provider.failures = [nil, .decoding("Connection lost")]
        let vm = AIAssistantViewModel(env: makeEnv(provider: provider, tools: [EchoTool(name: "echo")]))
        vm.inputText = "go"
        vm.send()
        await vm.waitForTurn()

        XCTAssertTrue(vm.messages[1].isError)
        XCTAssertTrue(vm.messages[1].text.hasPrefix("Incomplete final answer\n\n[Interrupted]"))
        XCTAssertEqual(vm.transcript.entries.count, 3)
        XCTAssertEqual(vm.transcript.entries.last, .toolResult(id: "c1", name: "echo", result: "echoed"))
        XCTAssertFalse(vm.messages[1].toolSteps.contains(where: \.isRunning))
    }

    func testNoticeIsVisibleWithoutExposingReasoningOrEnteringTranscript() async {
        let provider = ScriptedProvider(rounds: [[.thinkingDelta("Private reasoning"), .notice("Output limit reached"), .textDelta("Answer")]])
        let vm = AIAssistantViewModel(env: makeEnv(provider: provider))
        vm.inputText = "question"
        vm.send()
        await vm.waitForTurn()

        XCTAssertEqual(vm.messages[1].text, "Answer")
        XCTAssertEqual(vm.messages[1].toolSteps.first?.name, "Output limit reached")
        XCTAssertEqual(vm.messages[1].toolSteps.first?.isRunning, false)
        XCTAssertEqual(vm.transcript.entries, [.user("question"), .assistant("Answer")])
    }

    func testPendingConfirmationIsDeniedOnStop() async {
        let provider = ScriptedProvider(rounds: [[.toolCalls([call()])], [.textDelta("after")]])
        let store = AIToolPolicyStore(defaults: UserDefaults(suiteName: "ai-vm-\(UUID().uuidString)")!)
        store.set(.ask, for: "echo")
        var env = makeEnv(provider: provider, tools: [EchoTool(name: "echo")])
        env.policyStore = store
        let vm = AIAssistantViewModel(env: env)
        vm.inputText = "go"
        vm.send()
        for _ in 0..<50 where vm.pendingConfirmation == nil { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(vm.pendingConfirmation)
        XCTAssertTrue(vm.pendingConfirmation!.detail.contains("Tool: echo"))
        vm.stop()
        XCTAssertNil(vm.pendingConfirmation)
        await vm.waitForTurn()
        XCTAssertEqual(vm.state, .ready)
    }

    func testAskedToolRunsOnlyWhenAllowed() async {
        let provider = ScriptedProvider(rounds: [[.toolCalls([call()])], [.textDelta("fin")]])
        let store = AIToolPolicyStore(defaults: UserDefaults(suiteName: "ai-vm-\(UUID().uuidString)")!)
        store.set(.ask, for: "echo")
        var env = makeEnv(provider: provider, tools: [EchoTool(name: "echo")])
        env.policyStore = store
        let vm = AIAssistantViewModel(env: env)
        vm.inputText = "go"
        vm.send()
        for _ in 0..<50 where vm.pendingConfirmation == nil { try? await Task.sleep(for: .milliseconds(20)) }
        vm.resolveConfirmation(false)
        await vm.waitForTurn()
        guard case .toolResult(_, _, let result) = vm.transcript.entries[2] else { return XCTFail() }
        XCTAssertTrue(result.contains("declined"))
    }

    func testNoToolsProviderGetsNoToolsAndNoInfos() async {
        let provider = ScriptedProvider(rounds: [[.textDelta("hi")]])
        let vm = AIAssistantViewModel(env: makeEnv(provider: provider, supportsTools: false, tools: [EchoTool(name: "echo")]))
        XCTAssertFalse(vm.toolsSupported)
        XCTAssertTrue(vm.toolInfos.isEmpty)
        XCTAssertNil(vm.contextClip, "nothing is attached automatically")
    }

    func testConversationPersistsAndClearDeletesFile() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString).json")
        let store = AIConversationStore(fileURL: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let provider = ScriptedProvider(rounds: [[.textDelta("stored")]])
        let vm = AIAssistantViewModel(env: makeEnv(provider: provider, store: store))
        vm.inputText = "remember"
        vm.send()
        await vm.waitForTurn()
        let reloaded = AIAssistantViewModel(env: makeEnv(provider: provider, store: store))
        XCTAssertEqual(reloaded.messages.map(\.text), ["remember", "stored"])
        XCTAssertEqual(reloaded.transcript.entries, [.user("remember"), .assistant("stored")])
        reloaded.clearConversation()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
final class AIToolPolicyTests: XCTestCase {
    private func store() -> AIToolPolicyStore {
        AIToolPolicyStore(defaults: UserDefaults(suiteName: "ai-policy-\(UUID().uuidString)")!)
    }

    func testDefaults() {
        for name in ["create_clip", "set_clip_category", "execute_code"] {
            XCTAssertEqual(AIToolPolicy.defaultPolicy(for: name), .ask)
        }
        XCTAssertEqual(AIToolPolicy.defaultPolicy(for: "search_clips"), .always)
        XCTAssertEqual(AIToolPolicy.defaultPolicy(for: "get_clip"), .always)
    }

    func testStorePersistsOverrides() {
        let policies = store()
        XCTAssertEqual(policies.policy(for: "create_clip"), .ask)
        policies.set(.never, for: "create_clip")
        XCTAssertEqual(policies.policy(for: "create_clip"), .never)
    }

    func testNeverToolsAreNotOfferedToTheModel() {
        let policies = store()
        policies.set(.never, for: "b")
        let tools = AIToolPolicy.apply(to: [EchoTool(name: "b"), EchoTool(name: "a")], store: policies) { _, _ in true }
        XCTAssertEqual(tools.map(\.name), ["a"])
    }

    func testGatedToolBehaviourPerPolicy() async throws {
        let base = EchoTool(name: "t")
        var asked = 0
        let deny = PolicyGatedTool(base: base, policy: .ask) { _, _ in asked += 1; return false }
        let denied = try await deny.execute(args: [:])
        XCTAssertTrue(denied.contains("declined"))
        let allow = PolicyGatedTool(base: base, policy: .ask) { _, _ in asked += 1; return true }
        let allowed = try await allow.execute(args: [:])
        XCTAssertEqual(allowed, "echoed")
        let always = PolicyGatedTool(base: base, policy: .always) { _, _ in asked += 1; return false }
        let ran = try await always.execute(args: [:])
        XCTAssertEqual(ran, "echoed")
        let never = PolicyGatedTool(base: base, policy: .never) { _, _ in asked += 1; return true }
        let refused = try await never.execute(args: [:])
        XCTAssertTrue(refused.contains("disabled"))
        XCTAssertEqual(asked, 2)
    }

    func testConfirmationDetailShowsFullCode() {
        let code = (1...50).map { "echo line \($0)" }.joined(separator: "\n")
        let detail = PolicyGatedTool.describe(toolName: "execute_code", args: ["language": "bash", "code": code])
        XCTAssertTrue(detail.contains("echo line 50"))
        XCTAssertTrue(detail.contains("language: bash"))
    }
}

@MainActor
final class AIActionSupportTests: XCTestCase {
    func testTemplateValidation() {
        XCTAssertTrue(AIActionTemplateValidator.hasErrors(AIActionTemplateValidator.validate("  ")))
        XCTAssertTrue(AIActionTemplateValidator.validate("Summarize {clip}").isEmpty)
        let typo = AIActionTemplateValidator.validate("Do {Clip} now")
        XCTAssertTrue(typo.contains { $0.message.contains("Did you mean {clip}") })
        XCTAssertTrue(AIActionTemplateValidator.validate("no placeholder").contains { $0.message.contains("no {clip}") })
    }

    func testExportImportRoundTripSanitizes() throws {
        var action = AIAction.builtIns[1]
        action.temperature = 9
        let data = try AIActionTransfer.export([action])
        let result = try AIActionTransfer.importActions(from: data)
        XCTAssertEqual(result.actions.count, 1)
        XCTAssertNotEqual(result.actions[0].id, action.id)
        XCTAssertFalse(result.actions[0].isBuiltIn)
        XCTAssertEqual(result.actions[0].temperature, 1)
    }

    func testImportSkipsInvalidAndRejectsGarbage() throws {
        var bad = AIAction.builtIns[0]
        bad.promptTemplate = " "
        let result = try AIActionTransfer.importActions(from: AIActionTransfer.export([bad]))
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertThrowsError(try AIActionTransfer.importActions(from: Data("nope".utf8)))
    }

    func testEditingPreservesSortOrderThroughStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = AIActionStore(fileURL: url)
        var edited = store.actions[3]
        let order = edited.sortOrder
        edited.name = "Renamed"
        store.update(edited)
        XCTAssertEqual(store.action(id: edited.id)?.sortOrder, order)
    }
}
