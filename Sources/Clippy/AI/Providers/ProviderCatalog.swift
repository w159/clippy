import Foundation

/// Bundled provider knowledge. Values come from docs/ai/providers-*.md (researched
/// 2026-09-30); anything the docs marked [UNVERIFIED] is kept and kept in `notes`; the settings UI strips the marker (`ProviderDescriptor.userFacingNotes`).
enum ProviderCatalog {
    static let groupOrder = ["Local", "Cloud", "Enterprise", "Aggregator"]

    static func descriptor(id: String) -> ProviderDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// Active providers, in group order (catalog order within a group).
    static var addable: [ProviderDescriptor] {
        let active = descriptors.filter(\.isActive)
        return groupOrder.flatMap { group in active.filter { $0.group == group } }
    }

    private static let compatFields: [ProviderField] = [.baseURL, .apiKey, .model]
    private static let localFields: [ProviderField] = [.baseURL, .apiKey, .model]
    private static let bearerModels = ModelListSpec(url: "/models", needsAuth: true, parser: .openaiList)

    static let descriptors: [ProviderDescriptor] = local + cloud + enterprise + aggregators

    // MARK: - Local

    private static let local: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: "apple-intelligence", displayName: "Apple Intelligence (on device)",
            family: .appleFoundation, group: "Local", defaultBaseURL: "", chatPath: "",
            auth: .noAuth, apiKeyOptional: true, fields: [], defaultModel: "system",
            docsURL: "https://developer.apple.com/documentation/foundationmodels",
            notes: "Runs in-process; nothing leaves the Mac. Tool calling is not wired yet (PLT-04).",
            isLoopbackDefault: true, supportsTools: false, streamOptionsSupported: false,
            sendsTemperature: false),
        ProviderDescriptor(
            id: "ollama-local", displayName: "Ollama (local)", family: .ollamaChat, group: "Local",
            defaultBaseURL: "http://localhost:11434", chatPath: "/api/chat",
            auth: .noAuth, apiKeyOptional: true, fixedHeaders: ["Content-Type": "application/json"],
            fields: [.baseURL, .model],
            models: ModelListSpec(url: "/api/tags", needsAuth: false, parser: .ollamaTags),
            defaultModel: "llama3.1", docsURL: "https://docs.ollama.com/faq.md",
            notes: "Models named `x:cloud` or `x-cloud` are proxied to ollama.com and leave this Mac. "
                + "Output cap is options.num_predict; `think` is model-defined.",
            isLoopbackDefault: true, streamOptionsSupported: false),
        ProviderDescriptor(
            id: "ollama-cloud", displayName: "Ollama Cloud", family: .ollamaChat, group: "Cloud",
            defaultBaseURL: "https://ollama.com", chatPath: "/api/chat",
            fixedHeaders: ["Content-Type": "application/json"], fields: compatFields,
            models: ModelListSpec(url: "/api/tags", needsAuth: false, parser: .ollamaTags),
            defaultModel: "gpt-oss:120b", docsURL: "https://docs.ollama.com/cloud.md",
            notes: "Hosted by Ollama; content leaves the Mac. keep_alive residency effect [UNVERIFIED].",
            streamOptionsSupported: false),
        ProviderDescriptor(
            id: "lmstudio", displayName: "LM Studio", family: .openaiChat, group: "Local",
            defaultBaseURL: "http://localhost:1234", chatPath: "/v1/chat/completions",
            apiKeyOptional: true, fixedHeaders: ["Content-Type": "application/json"], fields: localFields,
            models: ModelListSpec(url: "/api/v1/models", needsAuth: true, parser: .lmStudio),
            docsURL: "https://lmstudio.ai/docs/developer/core/authentication",
            notes: "Auth only when enabled in LM Studio. max_completion_tokens and developer role [UNVERIFIED]; uses max_tokens.",
            isLoopbackDefault: true),
        ProviderDescriptor(
            id: "llamacpp", displayName: "llama.cpp server", family: .openaiChat, group: "Local",
            defaultBaseURL: "http://127.0.0.1:8080", chatPath: "/v1/chat/completions",
            apiKeyOptional: true, fixedHeaders: ["Content-Type": "application/json"], fields: localFields,
            models: ModelListSpec(url: "/v1/models", needsAuth: true, parser: .openaiList),
            docsURL: "https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md",
            notes: "Router-mode /models entries carry status/args; single-model metadata differs [UNVERIFIED].",
            isLoopbackDefault: true),
        ProviderDescriptor(
            id: "vllm", displayName: "vLLM", family: .openaiChat, group: "Local",
            defaultBaseURL: "http://localhost:8000", chatPath: "/v1/chat/completions",
            apiKeyOptional: true, fixedHeaders: ["Content-Type": "application/json"], fields: localFields,
            models: ModelListSpec(url: "/v1/models", needsAuth: true, parser: .vllm),
            docsURL: "https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/",
            notes: "max_tokens is deprecated in favor of max_completion_tokens; both accepted. "
                + "Model generation_config.json may override sampling defaults.",
            isLoopbackDefault: true, tokenLimitField: "max_completion_tokens"),
        ProviderDescriptor(
            id: "jan", displayName: "Jan", family: .openaiChat, group: "Local",
            defaultBaseURL: "http://127.0.0.1:1337", chatPath: "/v1/chat/completions",
            apiKeyOptional: true, fixedHeaders: ["Content-Type": "application/json"], fields: localFields,
            models: nil, docsURL: "https://www.jan.ai/docs/desktop/api-server",
            notes: "Streaming wire details, model listing route and parameter limits [UNVERIFIED]; enter the model id manually.",
            isLoopbackDefault: true, streamOptionsSupported: false),
        ProviderDescriptor(
            id: "custom-openai", displayName: "Custom OpenAI-compatible", family: .openaiChat, group: "Local",
            defaultBaseURL: "", chatPath: "/v1/chat/completions", apiKeyOptional: true,
            fixedHeaders: ["Content-Type": "application/json"], fields: compatFields,
            models: ModelListSpec(url: "/v1/models", needsAuth: true, parser: .openaiList),
            docsURL: "https://platform.openai.com/docs/api-reference/chat",
            notes: "Any server that speaks /v1/chat/completions. Only loopback URLs count as staying on this Mac.",
            streamOptionsSupported: false),
    ]

    // MARK: - Cloud

    private static let cloud: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: "openai", displayName: "OpenAI", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "https://api.openai.com/v1", chatPath: "/chat/completions",
            fixedHeaders: ["Content-Type": "application/json"],
            fields: [.baseURL, .apiKey, .model, .organization, .project], models: bearerModels,
            defaultModel: "gpt-4o-mini",
            docsURL: "https://developers.openai.com/api/reference/overview",
            notes: "Chat Completions. max_tokens is deprecated and rejected by o-series models; "
                + "reasoning models reject a custom temperature, so it is not sent unless set.",
            tokenLimitField: "max_completion_tokens", sendsTemperature: false,
            suggestedHeaders: [
                HeaderHint(name: "OpenAI-Organization", valueHint: "org_...", purpose: "Bill usage to a specific organization"),
                HeaderHint(name: "OpenAI-Project", valueHint: "proj_...", purpose: "Bill usage to a specific project"),
            ]),
        ProviderDescriptor(
            id: "anthropic", displayName: "Anthropic", family: .anthropicMessages, group: "Cloud",
            defaultBaseURL: "https://api.anthropic.com", chatPath: "/v1/messages",
            auth: .header("x-api-key"),
            fixedHeaders: ["anthropic-version": "2023-06-01", "Content-Type": "application/json"],
            fields: [.baseURL, .apiKey, .model],
            models: ModelListSpec(url: "/v1/models", needsAuth: true, parser: .anthropic),
            defaultModel: "claude-haiku-4-5", docsURL: "https://platform.claude.com/docs/en/api/messages",
            notes: "max_tokens is required on every request. Override anthropic-version via a custom header.",
            streamOptionsSupported: false,
            suggestedHeaders: [
                HeaderHint(name: "anthropic-beta", valueHint: "comma-separated beta flags", purpose: "Opt in to beta features"),
            ]),
        ProviderDescriptor(
            id: "gemini", displayName: "Google Gemini (native)", family: .geminiNative, group: "Cloud",
            defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
            chatPath: "/models/{model}:generateContent",
            streamPath: "/models/{model}:streamGenerateContent?alt=sse",
            auth: .header("x-goog-api-key"), fixedHeaders: ["Content-Type": "application/json"],
            fields: [.baseURL, .apiKey, .model],
            models: ModelListSpec(url: "/models", needsAuth: true, parser: .gemini),
            defaultModel: "gemini-2.5-flash", docsURL: "https://ai.google.dev/gemini-api/docs/api-key",
            notes: "x-goog-api-key on generateContent itself is [UNVERIFIED] (docs show ?key=). Output cap is generationConfig.maxOutputTokens.",
            supportsTools: false, streamOptionsSupported: false),
        ProviderDescriptor(
            id: "gemini-openai", displayName: "Google Gemini (OpenAI-compatible)", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai", chatPath: "/chat/completions",
            fields: compatFields, models: bearerModels, defaultModel: "gemini-2.5-flash",
            docsURL: "https://ai.google.dev/gemini-api/docs/openai",
            notes: "Model list shape [UNVERIFIED]. reasoning_effort is supported."),
        ProviderDescriptor(
            id: "mistral", displayName: "Mistral", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "https://api.mistral.ai/v1", chatPath: "/chat/completions",
            fields: compatFields, models: bearerModels, defaultModel: "mistral-small-latest",
            docsURL: "https://docs.mistral.ai/api/endpoint/models",
            notes: "Uses max_tokens (no max_completion_tokens). temperature 0-1.5. Regional base URLs [UNVERIFIED]."),
        ProviderDescriptor(
            id: "groq", displayName: "Groq", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "https://api.groq.com/openai/v1", chatPath: "/chat/completions",
            fields: compatFields, models: ModelListSpec(url: "/models", needsAuth: true, parser: .groq),
            defaultModel: "llama-3.3-70b-versatile", docsURL: "https://console.groq.com/docs/api-reference",
            notes: "n must be 1. logprobs/penalties/logit_bias unsupported.",
            tokenLimitField: "max_completion_tokens"),
        ProviderDescriptor(
            id: "together", displayName: "Together AI", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "https://api.together.ai/v1", chatPath: "/chat/completions",
            fields: compatFields, models: ModelListSpec(url: "/models", needsAuth: true, parser: .together),
            defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            docsURL: "https://docs.together.ai/reference/models",
            notes: "The model list is a bare JSON array. pricing units in the list [UNVERIFIED]."),
        ProviderDescriptor(
            id: "deepseek", displayName: "DeepSeek", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "https://api.deepseek.com", chatPath: "/chat/completions",
            fields: compatFields, models: bearerModels, defaultModel: "deepseek-chat",
            docsURL: "https://api-docs.deepseek.com/api/list-models",
            notes: "[UNVERIFIED] against primary docs (host timed out during research); values from search excerpts. "
                + "max_completion_tokens preferred over deprecated max_tokens.",
            tokenLimitField: "max_completion_tokens"),
        ProviderDescriptor(
            id: "xai", displayName: "xAI (Grok)", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "https://api.x.ai/v1", chatPath: "/chat/completions",
            fields: compatFields, models: ModelListSpec(url: "/language-models", needsAuth: true, parser: .xai),
            defaultModel: "grok-4", docsURL: "https://docs.x.ai/developers/rest-api-reference/inference/models",
            notes: "stop and presence_penalty are rejected by reasoning models.",
            tokenLimitField: "max_completion_tokens"),
        ProviderDescriptor(
            id: "perplexity", displayName: "Perplexity (Router)", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "https://api.perplexity.ai", chatPath: "/router/v1/chat/completions",
            fields: compatFields,
            models: ModelListSpec(url: "/router/v1/models", needsAuth: true, parser: .perplexity),
            defaultModel: "sonar", docsURL: "https://docs.perplexity.ai/api-reference/gateway-models-get",
            notes: "Router endpoint. Search-grounded; tool calling not confirmed [UNVERIFIED].",
            supportsTools: false, tokenLimitField: "max_completion_tokens"),
        ProviderDescriptor(
            id: "fireworks", displayName: "Fireworks AI", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "https://api.fireworks.ai/inference/v1", chatPath: "/chat/completions",
            fields: compatFields,
            models: ModelListSpec(url: "https://api.fireworks.ai/v1/accounts/fireworks/models", needsAuth: true, parser: .fireworks),
            defaultModel: "accounts/fireworks/models/llama-v3p3-70b-instruct",
            docsURL: "https://docs.fireworks.ai/tools-sdks/openai-compatibility",
            notes: "Model list lives under /v1/accounts/{accountID}/models (shown for account `fireworks`); its schema is [UNVERIFIED]. "
                + "Do not send both max_tokens and max_completion_tokens.",
            tokenLimitField: "max_completion_tokens"),
        ProviderDescriptor(
            id: "cerebras", displayName: "Cerebras", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "https://api.cerebras.ai/v1", chatPath: "/chat/completions",
            fields: compatFields, models: bearerModels, defaultModel: "gpt-oss-120b",
            docsURL: "https://inference-docs.cerebras.ai/api-reference/models/list-models",
            notes: "Supplemental model fields [UNVERIFIED]. reasoning_effort support varies by model.",
            tokenLimitField: "max_completion_tokens"),
        ProviderDescriptor(
            id: "cohere", displayName: "Cohere (OpenAI-compatible)", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "https://api.cohere.ai/compatibility/v1", chatPath: "/chat/completions",
            fields: compatFields,
            models: ModelListSpec(url: "https://api.cohere.com/v1/models", needsAuth: true, parser: .cohere),
            defaultModel: "command-a-03-2025", docsURL: "https://docs.cohere.com/docs/compatibility-api",
            notes: "Compatibility-mode model list is [UNVERIFIED]; the native /v1/models list is used."),
        ProviderDescriptor(
            id: "github-models", displayName: "GitHub Models (retired)", family: .openaiChat, group: "Cloud",
            defaultBaseURL: "", chatPath: "", auth: .noAuth, fields: [],
            docsURL: "https://docs.github.com/en/github-models",
            notes: "Retired 2026-07-30. Kept only as a marker; not offered when adding a provider.",
            isActive: false),
    ]

    // MARK: - Enterprise

    private static let enterprise: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: "azure-deployments", displayName: "Azure OpenAI (deployments)", family: .azureDeployments,
            group: "Enterprise", defaultBaseURL: "https://{resource}.openai.azure.com",
            chatPath: "/openai/deployments/{deployment}/chat/completions",
            auth: .header("api-key"), fixedHeaders: ["Content-Type": "application/json"],
            queryParams: ["api-version": "2024-10-21"],
            fields: [.baseURL, .apiKey, .deployment, .apiVersion],
            models: ModelListSpec(url: "/openai/models", needsAuth: true, parser: .azureDeployments),
            defaultModel: "gpt-4o-mini",
            docsURL: "https://learn.microsoft.com/en-us/azure/foundry/openai/reference",
            notes: "Requires the deployment name and an api-version. /openai/models lists base models, not your "
                + "deployments (ARM lists those). Entra bearer auth is supported by the service; scope docs conflict [UNVERIFIED].",
            tokenLimitField: "max_completion_tokens", sendsTemperature: false),
        ProviderDescriptor(
            id: "azure-v1", displayName: "Azure OpenAI / Foundry (v1)", family: .azureV1,
            group: "Enterprise", defaultBaseURL: "https://{resource}.openai.azure.com/openai/v1",
            chatPath: "/chat/completions", auth: .header("api-key"),
            fixedHeaders: ["Content-Type": "application/json"],
            fields: [.baseURL, .apiKey, .deployment],
            models: ModelListSpec(url: "/models", needsAuth: true, parser: .openaiList),
            defaultModel: "gpt-4o-mini",
            docsURL: "https://learn.microsoft.com/en-us/azure/foundry/openai/api-version-lifecycle",
            notes: "No api-version needed. The model field is the deployment name. Whether listed ids equal deployed aliases is [UNVERIFIED].",
            tokenLimitField: "max_completion_tokens", sendsTemperature: false),
    ]

    // MARK: - Aggregators

    private static let aggregators: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: "openrouter", displayName: "OpenRouter", family: .openaiChat, group: "Aggregator",
            defaultBaseURL: "https://openrouter.ai/api/v1", chatPath: "/chat/completions",
            fixedHeaders: ["Content-Type": "application/json"], fields: compatFields,
            models: ModelListSpec(url: "/models", needsAuth: true, parser: .openRouter),
            defaultModel: "openai/gpt-4o-mini",
            docsURL: "https://openrouter.ai/docs/api_reference/authentication",
            notes: "Pricing values may be \"-1\" (variable/unknown); treat as unknown, not negative.",
            suggestedHeaders: [
                HeaderHint(name: "HTTP-Referer", valueHint: "https://your.app", purpose: "App attribution on openrouter.ai"),
                HeaderHint(name: "X-OpenRouter-Title", valueHint: "Clippy", purpose: "App title shown in OpenRouter rankings"),
            ]),
        ProviderDescriptor(
            id: "huggingface", displayName: "Hugging Face (router)", family: .openaiChat, group: "Aggregator",
            defaultBaseURL: "https://router.huggingface.co/v1", chatPath: "/chat/completions",
            fields: compatFields,
            models: ModelListSpec(url: "/models", needsAuth: false, parser: .openaiList),
            defaultModel: "openai/gpt-oss-120b",
            docsURL: "https://huggingface.co/docs/inference-providers/index",
            notes: "Append `:provider` to the model id to pin an inference provider. Use a token with Inference Providers permission."),
    ]
}
