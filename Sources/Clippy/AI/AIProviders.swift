import Foundation

/// Connection details for a hosted or local provider. Non-secret fields come
/// from AppSettings; `apiKey` comes from the keychain.
struct AIProviderConfig {
    var baseURL: String
    var apiKey: String
    var model: String
    /// Azure AI Foundry / Azure OpenAI data-plane version.
    var apiVersion: String = "2024-10-21"
}

/// Shared JSON POST used by every HTTP provider. Throws a typed AIError on a
/// non-2xx so the UI can show a readable message.
enum AIHTTP {
    /// POST with a transient-error retry wrapper (audit [MEDIUM]). Up to
    /// `AIRetry.maxAttempts` tries with jittered backoff on retryable statuses.
    static func post(url urlString: String,
                     headers: [String: String],
                     body: [String: Any]) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await postSingle(url: urlString, headers: headers, body: body)
            } catch {
                attempt += 1
                if attempt < AIRetry.maxAttempts && AIRetry.isTransient(error) {
                    try? await Task.sleep(for: .milliseconds(AIRetry.backoffMs(attempt)))
                    continue
                }
                throw error
            }
        }
    }

    /// One-shot POST with no retry. Separated so `post` can wrap it.
    private static func postSingle(url urlString: String,
                                   headers: [String: String],
                                   body: [String: Any]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw AIError.badURL(urlString) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.decoding("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Pull a string out of a nested JSON path, e.g. ["choices", 0, "message", "content"].
    static func string(_ data: Data, at path: [Any]) throws -> String {
        var current: Any = try JSONSerialization.jsonObject(with: data)
        for key in path {
            if let index = key as? Int, let array = current as? [Any], array.indices.contains(index) {
                current = array[index]
            } else if let name = key as? String, let dict = current as? [String: Any], let next = dict[name] {
                current = next
            } else {
                throw AIError.decoding("missing field at \(path)")
            }
        }
        guard let text = current as? String, !text.isEmpty else { throw AIError.empty }
        return text
    }

    static func messagePayload(_ messages: [AIMessage]) -> [[String: String]] {
        messages.map { ["role": $0.role.rawValue, "content": $0.content] }
    }
}

// MARK: - OpenAI

struct OpenAIProvider: AIProvider {
    let config: AIProviderConfig

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/v1/chat/completions",
            headers: ["Authorization": "Bearer \(config.apiKey)"],
            body: [
                "model": config.model,
                "messages": AIHTTP.messagePayload(messages),
                "temperature": options.temperature,
                "max_tokens": options.maxTokens,
            ]
        )
        return try AIHTTP.string(data, at: ["choices", 0, "message", "content"])
    }
}

// MARK: - Anthropic

struct AnthropicProvider: AIProvider {
    let config: AIProviderConfig

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        // Anthropic carries the system prompt outside the message list.
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
            "messages": AIHTTP.messagePayload(turns),
        ]
        if !system.isEmpty { body["system"] = system }

        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/v1/messages",
            headers: [
                "x-api-key": config.apiKey,
                "anthropic-version": "2023-06-01",
            ],
            body: body
        )
        return try AIHTTP.string(data, at: ["content", 0, "text"])
    }
}

// MARK: - Ollama (local)

struct OllamaProvider: AIProvider {
    let config: AIProviderConfig

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/api/chat",
            headers: [:],
            body: [
                "model": config.model,
                "messages": AIHTTP.messagePayload(messages),
                "stream": false,
                "options": ["temperature": options.temperature],
            ]
        )
        return try AIHTTP.string(data, at: ["message", "content"])
    }
}

// MARK: - Azure AI Foundry (Azure OpenAI compatible)

struct AzureFoundryProvider: AIProvider {
    let config: AIProviderConfig

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        // model == Azure deployment name; key goes in the api-key header.
        let url = "\(config.baseURL)/openai/deployments/\(config.model)/chat/completions?api-version=\(config.apiVersion)"
        let data = try await AIHTTP.post(
            url: url,
            headers: ["api-key": config.apiKey],
            body: [
                "messages": AIHTTP.messagePayload(messages),
                "temperature": options.temperature,
                "max_tokens": options.maxTokens,
            ]
        )
        return try AIHTTP.string(data, at: ["choices", 0, "message", "content"])
    }
}

// MARK: - Factory

enum AIProviderFactory {
    static func make(kind: AIProviderKind, config: AIProviderConfig) -> AIProvider {
        switch kind {
        case .ollama: return OllamaProvider(config: config)
        case .openai: return OpenAIProvider(config: config)
        case .anthropic: return AnthropicProvider(config: config)
        case .azureFoundry: return AzureFoundryProvider(config: config)
        }
    }
}
