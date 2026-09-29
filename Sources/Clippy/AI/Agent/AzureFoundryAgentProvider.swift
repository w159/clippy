import Foundation

// MARK: - Azure AI Foundry agent provider
//
// Wire format: OpenAI-compatible chat completions.
// API version: 2024-10-21 (set in AIProviderConfig.apiVersion).

struct AzureFoundryAgentProvider: AIAgentProvider {
    let config: AIProviderConfig

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let url = "\(config.baseURL)/openai/deployments/\(config.model)/chat/completions?api-version=\(config.apiVersion)"
        let data = try await AIHTTP.post(
            url: url, headers: ["api-key": config.apiKey],
            body: [
                // Use the same wire transform as the agentic path so that
                // tool-result sentinel messages (injected by AIAgent.streamWithTools
                // at the round-cap summary turn) are correctly shaped for Azure.
                "messages": AIMessageBuilder.openAI(AIMessageBuilder.plainText(messages)),
                "temperature": options.temperature,
                "max_tokens": options.maxTokens,
            ]
        )
        return try AIHTTP.string(data, at: ["choices", 0, "message", "content"])
    }

    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn {
        let url = "\(config.baseURL)/openai/deployments/\(config.model)/chat/completions?api-version=\(config.apiVersion)"
        let body: [String: Any] = [
            "messages": AIMessageBuilder.openAI(messages),
            "tools": tools.map(\.openAIFunctionSpec),
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
        ]
        let data = try await AIHTTP.post(url: url, headers: ["api-key": config.apiKey], body: body)
        // Azure returns the same shape as OpenAI.
        return try OpenAIAgentProvider.parseTurn(data)
    }

    func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                         options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let url = "\(config.baseURL)/openai/deployments/\(config.model)/chat/completions?api-version=\(config.apiVersion)"
        var body: [String: Any] = [
            "messages": AIMessageBuilder.openAI(messages),
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !tools.isEmpty { body["tools"] = tools.map(\.openAIFunctionSpec) }
        let lines = AIStreamingHTTP.postLines(url: url, headers: ["api-key": config.apiKey], body: body)
        return OpenAIAgentProvider.eventStream(from: lines, accumulator: OpenAIStreamAccumulator())
    }
}
