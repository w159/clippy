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
                let settings = AppSettings.shared
                if case .failure(let error) = AIService.fromSettings(settings) { return .failure(error) }
                let kind = settings.aiProvider
                let base = settings.aiBaseURL.isEmpty ? kind.defaultBaseURL : settings.aiBaseURL
                let model = settings.aiModel.isEmpty ? kind.defaultModel : settings.aiModel
                let key = kind.needsAPIKey ? (KeychainStore.shared.read(account: kind.keychainAccount) ?? "") : ""
                let config = AIProviderConfig(baseURL: base, apiKey: key, model: model,
                                              apiVersion: settings.aiAzureAPIVersion)
                ClippyLog.debug("AI send: provider=\(kind.rawValue) model=\(model) base=\(base)",
                                category: ClippyLog.ai)
                return .success(AIAgentProviderFactory.make(kind: kind, config: config))
            },
            supportsTools: { AppSettings.shared.aiProvider.supportsTools },
            providerName: { AppSettings.shared.aiProvider.displayName },
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
