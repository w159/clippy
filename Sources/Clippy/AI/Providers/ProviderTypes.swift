import Foundation

// Provider descriptors: static, bundled knowledge about each backend (endpoints,
// auth, quirks). A `ProviderInstance` is one user-configured copy of a descriptor.
// See docs/ai/architecture.md.

/// The wire protocol a provider speaks. Transport code switches on this, never on a
/// provider id.
enum WireFamily: String, Codable, Sendable, CaseIterable {
    case openaiChat
    case anthropicMessages
    case ollamaChat
    /// Azure OpenAI classic: `/openai/deployments/{deployment}/chat/completions?api-version=`.
    case azureDeployments
    /// Azure OpenAI / Foundry v1: `{resource}/openai/v1/chat/completions`.
    case azureV1
    case geminiNative
    case appleFoundation
}

struct AuthSpec: Codable, Sendable, Equatable {
    enum Scheme: String, Codable, Sendable {
        case bearer, header, none, entra
    }

    var scheme: Scheme
    var header: String?
    var prefix: String?

    static let bearer = AuthSpec(scheme: .bearer, header: "Authorization", prefix: "Bearer ")
    static let noAuth = AuthSpec(scheme: .none, header: nil, prefix: nil)
    static func header(_ name: String, prefix: String = "") -> AuthSpec {
        AuthSpec(scheme: .header, header: name, prefix: prefix)
    }
}

/// Which inputs the settings UI shows for a provider.
enum ProviderField: String, Codable, Sendable {
    case baseURL, apiKey, model, apiVersion, organization, project, deployment, region
}

enum ModelListParser: String, Codable, Sendable, CaseIterable {
    case openaiList, ollamaTags, openRouter, anthropic, gemini, together, groq
    case lmStudio, vllm, fireworks, perplexity, azureDeployments
    // Added: shapes that are not `{data:[{id}]}`.
    case xai, cohere
    case none
}

struct ModelListSpec: Codable, Sendable, Equatable {
    /// Path (joined to the effective base URL) or an absolute http(s) URL.
    var url: String
    var needsAuth: Bool
    var parser: ModelListParser
}

struct HeaderHint: Codable, Sendable, Equatable {
    var name: String
    var valueHint: String
    var purpose: String
}

enum EndpointPurpose: Sendable {
    case chat, stream, models
}

struct ProviderDescriptor: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var displayName: String
    var family: WireFamily
    /// "Local", "Cloud", "Enterprise" or "Aggregator".
    var group: String
    var defaultBaseURL: String
    /// May contain `{deployment}` / `{model}` placeholders and an inline `?query`.
    var chatPath: String
    var streamPath: String
    var auth: AuthSpec
    var apiKeyOptional: Bool
    var fixedHeaders: [String: String]
    var queryParams: [String: String]
    var fields: [ProviderField]
    var models: ModelListSpec?
    var defaultModel: String?
    var docsURL: String
    var notes: String?
    var isLoopbackDefault: Bool
    var supportsTools: Bool
    var streamOptionsSupported: Bool
    /// OpenAI-compatible output cap key: "max_tokens" or "max_completion_tokens".
    /// Native transports map the output cap to their own fields by wire family.
    var tokenLimitField: String
    var sendsTemperature: Bool
    /// False for retired providers: hidden from the add list.
    var isActive: Bool
    var suggestedHeaders: [HeaderHint]

    init(
        id: String, displayName: String, family: WireFamily, group: String,
        defaultBaseURL: String, chatPath: String, streamPath: String? = nil,
        auth: AuthSpec = .bearer, apiKeyOptional: Bool = false,
        fixedHeaders: [String: String] = [:], queryParams: [String: String] = [:],
        fields: [ProviderField], models: ModelListSpec? = nil, defaultModel: String? = nil,
        docsURL: String, notes: String? = nil, isLoopbackDefault: Bool = false,
        supportsTools: Bool = true, streamOptionsSupported: Bool = true,
        tokenLimitField: String = "max_tokens", sendsTemperature: Bool = true,
        isActive: Bool = true, suggestedHeaders: [HeaderHint] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.group = group
        self.defaultBaseURL = defaultBaseURL
        self.chatPath = chatPath
        self.streamPath = streamPath ?? chatPath
        self.auth = auth
        self.apiKeyOptional = apiKeyOptional
        self.fixedHeaders = fixedHeaders
        self.queryParams = queryParams
        self.fields = fields
        self.models = models
        self.defaultModel = defaultModel
        self.docsURL = docsURL
        self.notes = notes
        self.isLoopbackDefault = isLoopbackDefault
        self.supportsTools = supportsTools
        self.streamOptionsSupported = streamOptionsSupported
        self.tokenLimitField = tokenLimitField
        self.sendsTemperature = sendsTemperature
        self.isActive = isActive
        self.suggestedHeaders = suggestedHeaders
    }

    /// True when the provider needs a credential the user must supply.
    var requiresAPIKey: Bool { auth.scheme != .none && !apiKeyOptional && family != .appleFoundation }
}
