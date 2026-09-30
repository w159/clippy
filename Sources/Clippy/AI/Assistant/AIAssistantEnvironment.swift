import Foundation

/// Everything the assistant view model needs from the outside world, so the
/// conversation logic can be driven in tests with a scripted provider and no
/// settings, keychain, database or files.
struct AIAssistantEnvironment {
    /// Validated provider for the next turn, or the reason there is none.
    var makeProvider: @MainActor () -> Result<AIAgentProvider, AIError>
    /// Whether the selected provider can call tools at all (AI-02).
    var supportsTools: @MainActor () -> Bool
    /// Display name of the selected provider, for the no-tools banner.
    var providerName: @MainActor () -> String
    /// Enabled tools before policy is applied.
    var baseTools: @MainActor () -> [AITool]
    var policyStore: AIToolPolicyStore
    /// nil disables persistence.
    var conversationStore: AIConversationStore?
}

extension AIAssistantEnvironment {
    /// The real environment: settings, keychain, built-in tools, Application Support.
    static func live() -> AIAssistantEnvironment {
        AIAssistantEnvironment(
            makeProvider: {
                switch AIProviderStore.shared.resolve() {
                case .failure(let error): return .failure(error)
                case .success(let resolved):
                    ClippyLog.debug("AI send: \(resolved.displaySummary)", category: ClippyLog.ai)
                    return .success(AIProviderRuntime.make(resolved))
                }
            },
            supportsTools: {
                if case .success(let resolved) = AIProviderStore.shared.resolve() { return resolved.descriptor.supportsTools }
                return false
            },
            providerName: {
                return AIProviderStore.shared.active?.name ?? "No provider selected"
            },
            baseTools: {
                let settings = AppSettings.shared
                // Confirmation is the policy layer's job now (AIToolPolicy), so the
                // tools' own hooks approve; otherwise each gated call would prompt twice.
                return AIToolRegistry.makeFiltered(
                    allowScripts: settings.aiAgentAllowScripts,
                    allowCodeExecution: settings.aiAgentAllowCodeExecution,
                    allowWebSearch: settings.aiAgentAllowWebSearch,
                    confirmHook: { _ in true }
                ).all
            },
            policyStore: AIToolPolicyStore(),
            conversationStore: AIConversationStore()
        )
    }
}
