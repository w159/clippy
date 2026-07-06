import XCTest
@testable import Clippy

// MARK: - Shared test support

/// An AIAgentProvider driven by a script: returns items from `turns` in order.
/// Each element is either a `String` (final text) or `[AIToolCall]` (tool calls).
final class ScriptedAgentProvider: AIAgentProvider {
    enum Step {
        case text(String)
        case calls([AIToolCall])
    }
    var steps: [Step]
    private var index = 0
    private(set) var callCount = 0

    init(steps: [Step]) { self.steps = steps }

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        defer { index += 1; callCount += 1 }
        guard index < steps.count else { return "done" }
        if case .text(let t) = steps[index] { return t }
        return "done"
    }

    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn {
        defer { index += 1; callCount += 1 }
        guard index < steps.count else { return .text("done") }
        switch steps[index] {
        case .text(let t):  return .text(t)
        case .calls(let c): return .toolCalls(c)
        }
    }

    func streamWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                defer {
                    index += 1
                    callCount += 1
                    continuation.finish()
                }

                guard index < steps.count else {
                    continuation.yield(.done)
                    return
                }

                switch steps[index] {
                case .text(let t):
                    if !t.isEmpty { continuation.yield(.textDelta(t)) }
                case .calls(let c):
                    continuation.yield(.toolCalls(c))
                }

                continuation.yield(.done)
            }
        }
    }
}

/// A tool that records invocations and returns a canned string.
final class RecordingTool: AITool {
    let name: String
    let description = "A test tool."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": ["input": ["type": "string"] as [String: Any]] as [String: Any],
        "required": [] as [String],
    ]
    let response: String
    private(set) var invocations: [[String: Any]] = []

    init(name: String, response: String = "tool-result") {
        self.name = name
        self.response = response
    }

    func execute(args: [String: Any]) async throws -> String {
        invocations.append(args)
        return response
    }
}

// MARK: - AIAction template tests

final class AIActionTemplateTests: XCTestCase {

    func testBuildPromptSubstitutesClipAndInstruction() {
        let action = AIAction(
            id: UUID(), name: "Test", symbolName: "star",
            promptTemplate: "Translate {clip} to {instruction}.",
            temperature: 0.3, maxTokens: 256,
            outputDisposition: .proposeEdit, isBuiltIn: false
        )
        let result = action.buildPrompt(clip: "Hello", instruction: "Spanish")
        XCTAssertEqual(result, "Translate Hello to Spanish.")
    }

    func testBuildPromptWithMissingInstructionPlaceholder() {
        let action = AIAction(
            id: UUID(), name: "Summarize", symbolName: "doc",
            promptTemplate: "Summarize: {clip}",
            temperature: 0.3, maxTokens: 256,
            outputDisposition: .proposeEdit, isBuiltIn: false
        )
        let result = action.buildPrompt(clip: "Some long text")
        XCTAssertEqual(result, "Summarize: Some long text")
        XCTAssertFalse(result.contains("{clip}"))
        XCTAssertFalse(result.contains("{instruction}"))
    }

    func testBuildPromptTrimsWhitespace() {
        let action = AIAction(
            id: UUID(), name: "Trim", symbolName: "scissors",
            promptTemplate: "  {clip}  ",
            temperature: 0.3, maxTokens: 128,
            outputDisposition: .copyToClipboard, isBuiltIn: false
        )
        XCTAssertEqual(action.buildPrompt(clip: "hello"), "hello")
    }
}

// MARK: - AIActionStore tests

final class AIActionStoreTests: XCTestCase {

    private func tempStore() -> AIActionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-actions-test-\(UUID().uuidString).json")
        return AIActionStore(fileURL: url)
    }

    func testSeedDefaultsOnFirstLoad() {
        let store = tempStore()
        // Each built-in id must be present.
        for builtIn in AIAction.builtIns {
            XCTAssertTrue(store.actions.contains(where: { $0.id == builtIn.id }),
                          "Missing built-in: \(builtIn.name)")
        }
    }

    func testSeedIsIdempotent() {
        let store = tempStore()
        let countAfterFirstSeed = store.actions.count
        store.seedDefaults()
        XCTAssertEqual(store.actions.count, countAfterFirstSeed,
                       "Re-seeding must not add duplicates.")
    }

    func testAddAndDeleteCustomAction() {
        let store = tempStore()
        let custom = AIAction(
            id: UUID(), name: "My Action", symbolName: "bolt",
            promptTemplate: "Do something with {clip}",
            temperature: 0.5, maxTokens: 512,
            outputDisposition: .newClip, isBuiltIn: false
        )
        store.add(custom)
        XCTAssertNotNil(store.action(id: custom.id))

        store.delete(id: custom.id)
        XCTAssertNil(store.action(id: custom.id))
    }

    func testDeleteBuiltInIsIgnored() {
        let store = tempStore()
        let builtInID = AIAction.builtIns[0].id
        store.delete(id: builtInID)
        XCTAssertNotNil(store.action(id: builtInID), "Built-in actions must not be deletable.")
    }

    func testPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-actions-rt-\(UUID().uuidString).json")
        let store1 = AIActionStore(fileURL: url)
        let custom = AIAction(
            id: UUID(), name: "Persist Me", symbolName: "icloud",
            promptTemplate: "{clip}",
            temperature: 0.4, maxTokens: 100,
            outputDisposition: .copyToClipboard, isBuiltIn: false
        )
        store1.add(custom)

        let store2 = AIActionStore(fileURL: url)
        XCTAssertNotNil(store2.action(id: custom.id), "Action must survive a reload.")
        XCTAssertEqual(store2.action(id: custom.id)?.name, "Persist Me")
    }

    func testUpdateAction() {
        let store = tempStore()
        var custom = AIAction(
            id: UUID(), name: "Original", symbolName: "star",
            promptTemplate: "{clip}",
            temperature: 0.3, maxTokens: 256,
            outputDisposition: .proposeEdit, isBuiltIn: false
        )
        store.add(custom)
        custom.name = "Updated"
        store.update(custom)
        XCTAssertEqual(store.action(id: custom.id)?.name, "Updated")
    }
}

// MARK: - AIService.run(action:on:) tests

final class AIServiceRunActionTests: XCTestCase {

    func testRunActionSendsRenderedPromptToProvider() async throws {
        let mock = MockAIProvider(response: "result text")
        let service = AIService(provider: mock)
        let action = AIAction(
            id: UUID(), name: "Echo", symbolName: "speaker",
            promptTemplate: "Repeat this: {clip}",
            temperature: 0.3, maxTokens: 256,
            outputDisposition: .proposeEdit, isBuiltIn: false
        )
        let proposal = try await service.run(action: action, on: "hello world")
        XCTAssertEqual(proposal.proposed, "result text")
        XCTAssertEqual(proposal.label, "Echo")
        XCTAssertTrue(mock.lastMessages.last?.content.contains("hello world") ?? false,
                      "Clip text must appear in the sent message.")
    }

    func testRunActionOutputDispositionNewClipMapsToNewClipKind() async throws {
        let mock = MockAIProvider(response: "new content")
        let service = AIService(provider: mock)
        let action = AIAction(
            id: UUID(), name: "Generator", symbolName: "sparkles",
            promptTemplate: "{clip} {instruction}",
            temperature: 0.5, maxTokens: 512,
            outputDisposition: .newClip, isBuiltIn: false
        )
        let proposal = try await service.run(action: action, on: "ctx", instruction: "req")
        XCTAssertEqual(proposal.kind, .newClip)
    }

    func testRunActionProposeEditMapsToRewriteKind() async throws {
        let mock = MockAIProvider(response: "edited")
        let service = AIService(provider: mock)
        let action = AIAction(
            id: UUID(), name: "Edit", symbolName: "pencil",
            promptTemplate: "{clip}",
            temperature: 0.3, maxTokens: 256,
            outputDisposition: .proposeEdit, isBuiltIn: false
        )
        let proposal = try await service.run(action: action, on: "original")
        XCTAssertEqual(proposal.kind, .rewrite)
        XCTAssertEqual(proposal.original, "original")
    }

    func testRunActionCopyToClipboardMapsToCorrectKind() async throws {
        let mock = MockAIProvider(response: "clipboard result")
        let service = AIService(provider: mock)
        let action = AIAction(
            id: UUID(), name: "Translate", symbolName: "globe",
            promptTemplate: "Translate {clip} to French.",
            temperature: 0.3, maxTokens: 512,
            outputDisposition: .copyToClipboard, isBuiltIn: false
        )
        let proposal = try await service.run(action: action, on: "hello world")
        XCTAssertEqual(proposal.kind, .copyToClipboard,
                       "copyToClipboard disposition must produce .copyToClipboard kind, not .rewrite")
        XCTAssertEqual(proposal.proposed, "clipboard result")
        // Source clip reference is still populated so callers can inspect it.
        XCTAssertEqual(proposal.original, "hello world")
    }

    func testRunActionCopyToClipboardNeverProducesRewriteKind() async throws {
        let mock = MockAIProvider(response: "output")
        let service = AIService(provider: mock)
        let action = AIAction(
            id: UUID(), name: "Copy Action", symbolName: "doc.on.doc",
            promptTemplate: "{clip}",
            temperature: 0.5, maxTokens: 256,
            outputDisposition: .copyToClipboard, isBuiltIn: false
        )
        let proposal = try await service.run(action: action, on: "source text")
        XCTAssertNotEqual(proposal.kind, .rewrite,
                          "copyToClipboard must never collapse to .rewrite (data-loss bug guard)")
        XCTAssertNotEqual(proposal.kind, .newClip,
                          "copyToClipboard must never collapse to .newClip")
    }

    func testAllThreeDispositionsMappedDistinctly() async throws {
        // Proves each AIActionOutputDisposition maps to its own unique AIProposal.Kind.
        let mock = MockAIProvider(response: "x")
        let service = AIService(provider: mock)

        func proposal(for disposition: AIActionOutputDisposition) async throws -> AIProposal.Kind {
            let action = AIAction(id: UUID(), name: "A", symbolName: "star",
                                  promptTemplate: "{clip}", temperature: 0.3, maxTokens: 64,
                                  outputDisposition: disposition, isBuiltIn: false)
            return try await service.run(action: action, on: "text").kind
        }

        let proposeKind = try await proposal(for: .proposeEdit)
        let newClipKind  = try await proposal(for: .newClip)
        let copyKind     = try await proposal(for: .copyToClipboard)

        XCTAssertEqual(proposeKind, .rewrite)
        XCTAssertEqual(newClipKind,  .newClip)
        XCTAssertEqual(copyKind,     .copyToClipboard)

        // All three are distinct — no two dispositions collapse to the same kind.
        XCTAssertNotEqual(proposeKind, newClipKind)
        XCTAssertNotEqual(proposeKind, copyKind)
        XCTAssertNotEqual(newClipKind,  copyKind)
    }
}

// MARK: - Tool registry serialization tests

final class AIToolRegistryTests: XCTestCase {

    func testOpenAIFunctionSpecShape() {
        let tool = RecordingTool(name: "my_tool")
        let spec = tool.openAIFunctionSpec
        XCTAssertEqual(spec["type"] as? String, "function")
        let fn = spec["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "my_tool")
        XCTAssertNotNil(fn?["description"])
        XCTAssertNotNil(fn?["parameters"])
    }

    func testAnthropicToolSpecShape() {
        let tool = RecordingTool(name: "my_tool")
        let spec = tool.anthropicToolSpec
        XCTAssertEqual(spec["name"] as? String, "my_tool")
        XCTAssertNotNil(spec["description"])
        XCTAssertNotNil(spec["input_schema"])
    }

    func testRegistryLookupByName() {
        let registry = AIToolRegistry()
        let tool = RecordingTool(name: "lookup_test")
        registry.register(tool)
        XCTAssertNotNil(registry.tool(named: "lookup_test"))
        XCTAssertNil(registry.tool(named: "nonexistent"))
    }

    func testParametersSchemaIsSerializable() throws {
        let tool = SearchClipsTool()
        // Must not throw — required for provider wire serialization.
        let data = try JSONSerialization.data(withJSONObject: tool.parametersSchema)
        XCTAssertFalse(data.isEmpty)
        // Round-trip: must deserialize back to a dict with "type" == "object".
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "object")
    }

    func testGetClipSchemaIsSerializable() throws {
        let tool = GetClipTool()
        XCTAssertEqual(tool.name, "get_clip")
        let data = try JSONSerialization.data(withJSONObject: tool.parametersSchema)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "object")
        XCTAssertEqual(obj?["required"] as? [String], ["clip_id"])
    }

    func testSetClipCategorySchemaIsSerializable() throws {
        let tool = SetClipCategoryTool()
        XCTAssertEqual(tool.name, "set_clip_category")
        let data = try JSONSerialization.data(withJSONObject: tool.parametersSchema)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "object")
        XCTAssertEqual(obj?["required"] as? [String], ["clip_id", "category"])
        let props = obj?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["create_if_missing"], "Category creation must be opt-in via a schema flag.")
    }

    func testFilteredRegistryIncludesClipTools() {
        // Clip tools are the same risk class as search/create: always registered,
        // even with every safety toggle off.
        let registry = AIToolRegistry.makeFiltered(
            allowScripts: false,
            allowCodeExecution: false,
            allowWebSearch: false,
            confirmHook: { _ in false }
        )
        XCTAssertNotNil(registry.tool(named: "get_clip"))
        XCTAssertNotNil(registry.tool(named: "set_clip_category"))
        XCTAssertNotNil(registry.tool(named: "search_clips"))
        XCTAssertNotNil(registry.tool(named: "create_clip"))
        XCTAssertNil(registry.tool(named: "run_script"))
        XCTAssertNil(registry.tool(named: "execute_code"))
        XCTAssertNil(registry.tool(named: "web_search"))
    }

    func testInt64ValueDecodesCommonJSONNumberShapes() {
        XCTAssertEqual(AIToolHelpers.int64Value(7), 7)
        XCTAssertEqual(AIToolHelpers.int64Value(Int64(9_000_000_000)), 9_000_000_000)
        XCTAssertEqual(AIToolHelpers.int64Value(42.0), 42)
        XCTAssertEqual(AIToolHelpers.int64Value("13"), 13)
        XCTAssertEqual(AIToolHelpers.int64Value(NSNumber(value: 5)), 5)
        XCTAssertNil(AIToolHelpers.int64Value(42.5), "Fractional numbers are not valid ids.")
        XCTAssertNil(AIToolHelpers.int64Value("not a number"))
        XCTAssertNil(AIToolHelpers.int64Value(nil))
    }
}

// MARK: - Tool result sentinel tests

final class AIToolResultSentinelTests: XCTestCase {

    func testRoundTrip() {
        let encoded = AIToolResultSentinel.encode(id: "call-1", toolName: "search_clips", result: "found it")
        let decoded = AIToolResultSentinel.decode(encoded)
        XCTAssertEqual(decoded?.id, "call-1")
        XCTAssertEqual(decoded?.toolName, "search_clips")
        XCTAssertEqual(decoded?.result, "found it")
    }

    func testNonSentinelContentReturnsNil() {
        XCTAssertNil(AIToolResultSentinel.decode("plain message"))
        XCTAssertNil(AIToolResultSentinel.decode(""))
    }
}

// MARK: - Agent loop tests

final class AIAgentLoopTests: XCTestCase {

    // 1. Happy path: model returns text on first turn.
    func testLoopReturnsTextImmediately() async throws {
        let provider = ScriptedAgentProvider(steps: [.text("final answer")])
        let result = try await AIAgent.completeWithTools(
            messages: [AIMessage(role: .user, content: "hello")],
            provider: provider,
            tools: []
        )
        XCTAssertEqual(result, "final answer")
        XCTAssertEqual(provider.callCount, 1)
    }

    // 2. Model issues one tool call, then returns text.
    func testLoopExecutesToolAndContinues() async throws {
        let toolCall = AIToolCall(id: "c1", toolName: "recorder", arguments: ["input": "ping"])
        let provider = ScriptedAgentProvider(steps: [
            .calls([toolCall]),
            .text("all done"),
        ])
        let tool = RecordingTool(name: "recorder", response: "pong")

        let result = try await AIAgent.completeWithTools(
            messages: [AIMessage(role: .user, content: "use the tool")],
            provider: provider,
            tools: [tool]
        )
        XCTAssertEqual(result, "all done")
        XCTAssertEqual(tool.invocations.count, 1)
        XCTAssertEqual(provider.callCount, 2)
    }

    // 3. Confirmation hook denies execution — tool must not run.
    func testConfirmationDeniedToolDoesNotRun() async throws {
        let toolCall = AIToolCall(id: "c2", toolName: "gated", arguments: [:])

        // A gated tool that calls the confirm hook itself (like run_script/execute_code).
        // Here we wire a RunScriptTool-alike using a wrapper that calls the hook.
        final class GatedTool: AITool {
            let name = "gated"
            let description = "needs confirmation"
            let parametersSchema: [String: Any] = [
                "type": "object", "properties": [:] as [String: Any], "required": [] as [String]
            ]
            var didRun = false
            let confirmHook: (String) async -> Bool

            init(confirmHook: @escaping (String) async -> Bool) {
                self.confirmHook = confirmHook
            }

            func execute(args: [String: Any]) async throws -> String {
                let allowed = await confirmHook("allow?")
                guard allowed else { return "User declined." }
                didRun = true
                return "ran"
            }
        }

        let gated = GatedTool(confirmHook: { _ in false })
        let provider = ScriptedAgentProvider(steps: [
            .calls([toolCall]),
            .text("understood"),
        ])

        let result = try await AIAgent.completeWithTools(
            messages: [AIMessage(role: .user, content: "run gated")],
            provider: provider,
            tools: [gated]
        )
        XCTAssertEqual(result, "understood")
        XCTAssertFalse(gated.didRun, "Tool body must not execute when confirmation is denied.")
    }

    // 4. Loop terminates after maxRounds.
    func testLoopTerminatesAfterMaxRounds() async throws {
        // Feed more tool-call steps than maxRounds.
        let toolCall = AIToolCall(id: "cx", toolName: "noop", arguments: [:])
        let steps: [ScriptedAgentProvider.Step] = Array(
            repeating: .calls([toolCall]),
            count: AIAgent.maxRounds + 5
        ) + [.text("final")]
        let provider = ScriptedAgentProvider(steps: steps)
        let tool = RecordingTool(name: "noop", response: "ok")

        // Should not throw even though there are more calls than rounds.
        let _ = try await AIAgent.completeWithTools(
            messages: [AIMessage(role: .user, content: "go")],
            provider: provider,
            tools: [tool]
        )
        XCTAssertLessThanOrEqual(tool.invocations.count, AIAgent.maxRounds,
                                  "Tool must not be invoked more than maxRounds times.")
    }

    // 5. Tool result is fed back to the model in subsequent messages.
    func testToolResultAppearsinNextMessages() async throws {
        final class CapturingProvider: AIAgentProvider {
            var messages: [[AIMessage]] = []
            var step = 0
            let toolCall = AIToolCall(id: "tc1", toolName: "spy", arguments: [:])

            func complete(_ m: [AIMessage], options: AICompletionOptions) async throws -> String {
                messages.append(m); return "done"
            }
            func completeWithTools(
                _ m: [AIMessage], tools: [AITool], options: AICompletionOptions
            ) async throws -> AIAgentTurn {
                messages.append(m)
                defer { step += 1 }
                return step == 0 ? .toolCalls([toolCall]) : .text("answer")
            }

            func streamWithTools(
                _ m: [AIMessage],
                tools: [AITool],
                options: AICompletionOptions
            ) -> AsyncThrowingStream<AIStreamEvent, Error> {
                messages.append(m)
                let currentStep = step
                step += 1

                return AsyncThrowingStream { continuation in
                    if currentStep == 0 {
                        continuation.yield(.toolCalls([toolCall]))
                    } else {
                        continuation.yield(.textDelta("answer"))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                }
            }
        }

        let provider = CapturingProvider()
        let tool = RecordingTool(name: "spy", response: "spy-result")

        _ = try await AIAgent.completeWithTools(
            messages: [AIMessage(role: .user, content: "start")],
            provider: provider,
            tools: [tool]
        )

        // Second call to the provider must include a message carrying the tool result.
        let secondCallMessages = provider.messages[1]
        let containsResult = secondCallMessages.contains {
            AIToolResultSentinel.decode($0.content)?.result == "spy-result"
        }
        XCTAssertTrue(containsResult, "Tool result must be threaded back into the next provider call.")
    }
}

// MARK: - Endpoint configuration tests

final class AIProviderEndpointConfigTests: XCTestCase {

    func testAzurePlaceholderEndpointIsRejected() {
        let why = AIProviderKind.azureFoundry.endpointConfigError(
            "https://YOUR-RESOURCE.services.ai.azure.com")
        XCTAssertNotNil(why, "The unedited Azure placeholder host must be rejected.")
        XCTAssertTrue(why?.contains("Azure endpoint not configured") ?? false,
                      "Message must name the Azure endpoint precisely, not surface a DNS error.")
    }

    func testAzureRealEndpointIsAccepted() {
        let why = AIProviderKind.azureFoundry.endpointConfigError(
            "https://my-resource.services.ai.azure.com")
        XCTAssertNil(why, "A filled-in Azure endpoint must pass validation.")
    }

    func testNonAzureProvidersIgnoreEndpointValidation() {
        for kind in [AIProviderKind.openai, .anthropic, .ollama] {
            XCTAssertNil(kind.endpointConfigError("https://YOUR-RESOURCE.example.com"),
                         "Only Azure carries the placeholder check; \(kind) must not reject.")
        }
    }
}

// MARK: - AITool truncation tests

final class AIToolTruncationTests: XCTestCase {

    func testTruncateLongResult() {
        let big = String(repeating: "x", count: AIToolHelpers.maxResultBytes + 1000)
        let truncated = AIToolHelpers.truncate(big)
        XCTAssertLessThanOrEqual(truncated.utf8.count, AIToolHelpers.maxResultBytes + 50,
                                  "Truncated result must be close to maxResultBytes.")
        XCTAssertTrue(truncated.hasSuffix("[result truncated]"))
    }

    func testShortResultIsNotTruncated() {
        let short = "hello world"
        XCTAssertEqual(AIToolHelpers.truncate(short), short)
    }
}

// MARK: - AIToolRegistry.makeFiltered tests

final class AIToolRegistryFilteredTests: XCTestCase {

    /// With both toggles off, only search_clips and create_clip are registered;
    /// script and code tools must not appear.
    func testBothTogglesOffExcludesScriptAndCodeTools() {
        let registry = AIToolRegistry.makeFiltered(
            allowScripts: false,
            allowCodeExecution: false,
            allowWebSearch: false,
            confirmHook: { _ in true }
        )
        let names = Set(registry.all.map(\.name))
        XCTAssertTrue(names.contains("search_clips"))
        XCTAssertTrue(names.contains("create_clip"))
        XCTAssertFalse(names.contains("run_script"),
                       "run_script must be excluded when allowScripts is false")
        XCTAssertFalse(names.contains("list_scripts"),
                       "list_scripts must be excluded when allowScripts is false")
        XCTAssertFalse(names.contains("execute_code"),
                       "execute_code must be excluded when allowCodeExecution is false")
    }

    /// With allowScripts on, script tools appear.
    func testAllowScriptsIncludesScriptTools() {
        let registry = AIToolRegistry.makeFiltered(
            allowScripts: true,
            allowCodeExecution: false,
            allowWebSearch: false,
            confirmHook: { _ in true }
        )
        let names = Set(registry.all.map(\.name))
        XCTAssertTrue(names.contains("run_script"))
        XCTAssertTrue(names.contains("list_scripts"))
        XCTAssertFalse(names.contains("execute_code"))
    }

    /// With allowCodeExecution on, the code tool appears.
    func testAllowCodeExecutionIncludesCodeTool() {
        let registry = AIToolRegistry.makeFiltered(
            allowScripts: false,
            allowCodeExecution: true,
            allowWebSearch: false,
            confirmHook: { _ in true }
        )
        let names = Set(registry.all.map(\.name))
        XCTAssertTrue(names.contains("execute_code"))
        XCTAssertFalse(names.contains("run_script"))
    }

    /// With all toggles on, every built-in tool appears.
    func testBothTogglesOnIncludesAllBuiltInTools() {
        let registry = AIToolRegistry.makeFiltered(
            allowScripts: true,
            allowCodeExecution: true,
            allowWebSearch: true,
            confirmHook: { _ in true }
        )
        let names = Set(registry.all.map(\.name))
        XCTAssertEqual(names, ["search_clips", "create_clip", "get_clip", "set_clip_category",
                               "web_search", "list_scripts", "run_script", "execute_code"])
    }
}

// MARK: - WebSearchTool tests

final class WebSearchToolTests: XCTestCase {

    /// Parse a result with a DDG redirect-wrapped href, HTML entities, and a
    /// snippet. Proves tag stripping, entity decode, and uddg extraction.
    func testParsesRedirectAndEntities() {
        let html = """
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdocs.swift.org%2Fconcurrency&amp;rut=x">Concurrency &amp; Actors</a>
        <a class="result__snippet" href="//x">Use <b>actors</b> to protect state.</a>
        """
        let results = WebSearchTool.parse(html: html)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Concurrency & Actors")
        XCTAssertEqual(results[0].url, "https://docs.swift.org/concurrency")
        XCTAssertEqual(results[0].snippet, "Use actors to protect state.")
    }

    func testParseReturnsEmptyOnChallengePage() {
        // A bot-challenge page has no result anchors; parse must yield nothing.
        XCTAssertTrue(WebSearchTool.parse(html: "<html><body>nope</body></html>").isEmpty)
    }

    /// execute() formats injected HTML without touching the network.
    func testExecuteFormatsInjectedResults() async throws {
        let canned = "<a class=\"result__a\" href=\"https://example.com\">Example Domain</a>"
        let tool = WebSearchTool(fetchHTML: { _ in canned })
        let out = try await tool.execute(args: ["query": "anything"])
        XCTAssertTrue(out.contains("Example Domain"), "got: \(out)")
        XCTAssertTrue(out.contains("https://example.com"), "got: \(out)")
    }

    func testExecuteReportsNoResults() async throws {
        let tool = WebSearchTool(fetchHTML: { _ in "<html></html>" })
        let out = try await tool.execute(args: ["query": "zzz"])
        XCTAssertTrue(out.contains("No web results"), "got: \(out)")
    }

    func testExecuteRequiresQuery() async throws {
        let tool = WebSearchTool(fetchHTML: { _ in "" })
        let out = try await tool.execute(args: [:])
        XCTAssertTrue(out.contains("query parameter is required"), "got: \(out)")
    }
}

// MARK: - ExecuteCodeTool smoke tests

final class ExecuteCodeToolTests: XCTestCase {

    /// Confirms code execution actually runs a subprocess and returns its output.
    func testRunsConfirmedCode() async throws {
        let tool = ExecuteCodeTool(confirmHook: { _ in true })
        let out = try await tool.execute(args: ["language": "zsh", "code": "echo clippy-exec-ok"])
        XCTAssertTrue(out.contains("clippy-exec-ok"), "got: \(out)")
    }

    func testDeclinedCodeIsNotRun() async throws {
        let tool = ExecuteCodeTool(confirmHook: { _ in false })
        let out = try await tool.execute(args: ["language": "zsh", "code": "echo should-not-run"])
        XCTAssertTrue(out.contains("declined"), "got: \(out)")
        XCTAssertFalse(out.contains("should-not-run"), "declined code must not execute")
    }
}
