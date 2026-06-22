import Foundation

/// Role in a chat exchange. Anthropic keeps `system` out of the message list, so
/// providers that need it split it out themselves.
enum AIRole: String, Codable {
    case system
    case user
    case assistant
}

struct AIMessage: Equatable {
    let role: AIRole
    let content: String
}

struct AICompletionOptions {
    var temperature: Double = 0.3
    var maxTokens: Int = 1024
}

enum AIError: LocalizedError, Equatable {
    case notConfigured(String)
    case badURL(String)
    case http(Int, String)
    case decoding(String)
    case empty
    // Audit [LOW]: distinguish a wedged (idle) stream from a generic HTTP -1 so
    // the user gets an actionable message instead of "HTTP -1".
    case idleTimeout

    var errorDescription: String? {
        switch self {
        case .notConfigured(let why): return "AI is not configured: \(why)"
        case .badURL(let url): return "Invalid endpoint URL: \(url)"
        case .http(let code, let body):
            // -1 was the old sentinel for an idle-timeout; the dedicated
            // .idleTimeout case now carries that meaning with a friendlier text.
            if code == -1 { return "The provider connection failed (HTTP -1)." }
            let snippet = body.prefix(300)
            return "Provider returned HTTP \(code): \(snippet)"
        case .decoding(let why): return "Could not read the provider response: \(why)"
        case .empty: return "The provider returned an empty response."
        case .idleTimeout:
            return "The assistant stopped responding. The connection was idle for too long. Try sending again."
        }
    }
}

/// One chat-completion call. Every backend (Ollama, OpenAI, Anthropic, Azure AI
/// Foundry) implements this; the rest of the app only depends on this protocol,
/// which keeps the agentic features testable with a mock.
protocol AIProvider {
    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String
}

/// The backends Clippy can talk to. `ollama` is local and needs no key.
enum AIProviderKind: String, CaseIterable, Codable, Identifiable {
    case ollama
    case openai
    case anthropic
    case azureFoundry

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama (local)"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .azureFoundry: return "Microsoft Foundry"
        }
    }

    /// Local Ollama needs no credential; the hosted providers do.
    var needsAPIKey: Bool { self != .ollama }

    /// Keychain account under which this provider's key is stored.
    var keychainAccount: String { "ai.\(rawValue).apiKey" }

    var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434"
        case .openai: return "https://api.openai.com"
        case .anthropic: return "https://api.anthropic.com"
        case .azureFoundry: return "https://YOUR-RESOURCE.services.ai.azure.com"
        }
    }

    var defaultModel: String {
        switch self {
        case .ollama: return "llama3.1"
        case .openai: return "gpt-4o-mini"
        case .anthropic: return "claude-haiku-4-5"
        case .azureFoundry: return "gpt-4o-mini"
        }
    }

    /// Validate the resolved endpoint before any network call. Returns a precise
    /// reason string when the endpoint is unusable (e.g. the Azure resource name
    /// was never filled in), or nil when it is acceptable. Keeping this here means
    /// every construction site (AIService.fromSettings, the assistant panel) shares
    /// one authoritative check instead of letting a placeholder host reach DNS.
    func endpointConfigError(_ baseURL: String) -> String? {
        guard self == .azureFoundry else { return nil }
        if baseURL.contains("YOUR-RESOURCE") {
            return "Azure endpoint not configured. Set your resource Endpoint URL in Settings (e.g. https://my-resource.services.ai.azure.com)."
        }
        return nil
    }

    /// One-line hint shown under the model field in Settings.
    var modelHint: String {
        switch self {
        case .ollama: return "A model you have pulled, e.g. llama3.1 or qwen2.5."
        case .openai: return "An OpenAI chat model, e.g. gpt-4o-mini."
        case .anthropic: return "A Claude model id, e.g. claude-haiku-4-5."
        case .azureFoundry: return "Your Azure deployment name."
        }
    }
}
