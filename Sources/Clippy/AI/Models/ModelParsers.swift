import Foundation
import CoreFoundation

/// One page of a model list plus the cursor for the next page (nil = last page).
struct ModelPage: Sendable, Equatable {
    var models: [ModelInfo]
    var nextCursor: String?
}

enum ModelCatalogError: LocalizedError, Equatable {
    case noListEndpoint
    case badURL
    case http(Int, String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .noListEndpoint: return "This provider has no model list endpoint."
        case .badURL: return "The provider endpoint URL is not usable."
        case .http(let code, let body): return body.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(body)"
        case .decoding(let why): return "Unexpected model list format: \(why)"
        case .transport(let why): return why
        }
    }
}

/// Pure `Data -> [ModelInfo]` parsers, one per `ModelListParser`. Nothing here does I/O,
/// so each is unit-testable with fixtures. Unknown values stay nil.
enum ModelParsers {
    struct Context: Sendable {
        /// Hosted by the provider (Ollama Cloud): `size` is not a local disk footprint.
        var isCloud = false
        init(isCloud: Bool = false) { self.isCloud = isCloud }
    }

    static func parse(_ parser: ModelListParser, data: Data, context: Context = Context()) throws -> ModelPage {
        switch parser {
        case .openaiList: return try openAIList(data)
        case .vllm: return try vllm(data)
        case .groq: return try groq(data)
        case .ollamaTags: return try ollamaTags(data, context: context)
        case .openRouter: return try openRouter(data)
        case .anthropic: return try anthropic(data)
        case .gemini: return try gemini(data)
        case .together: return try together(data)
        case .lmStudio: return try lmStudio(data)
        case .fireworks: return try fireworks(data)
        case .perplexity: return try perplexity(data)
        case .xai: return try xai(data)
        case .cohere: return try cohere(data)
        case .azureDeployments: return try azureBaseModels(data)
        case .none: throw ModelCatalogError.noListEndpoint
        }
    }

    // MARK: - OpenAI-shaped

    /// `{data:[{id, created, owned_by}]}`; no metadata. Static facts are added by the service.
    static func openAIList(_ data: Data) throws -> ModelPage {
        let items = try array(data, keys: ["data"])
        let models = items.compactMap { item -> ModelInfo? in
            guard let id = str(item["id"]) else { return nil }
            return ModelInfo(id: id, created: unixDate(item["created"]), source: "GET /models (ids only)")
        }
        return ModelPage(models: models, nextCursor: nil)
    }

    /// `data[].max_model_len` (vLLM), `owned_by`.
    static func vllm(_ data: Data) throws -> ModelPage {
        let items = try array(data, keys: ["data"])
        let models = items.compactMap { item -> ModelInfo? in
            guard let id = str(item["id"]) else { return nil }
            return ModelInfo(id: id, contextLength: int(item["max_model_len"]),
                             created: unixDate(item["created"]), source: "GET /v1/models (max_model_len)")
        }
        return ModelPage(models: models, nextCursor: nil)
    }

    /// `data[].context_window`, `active`.
    static func groq(_ data: Data) throws -> ModelPage {
        let items = try array(data, keys: ["data"])
        let models = items.compactMap { item -> ModelInfo? in
            guard let id = str(item["id"]) else { return nil }
            if let active = item["active"] as? Bool, !active { return nil }
            return ModelInfo(id: id, contextLength: int(item["context_window"]),
                             created: unixDate(item["created"]), source: "GET /models (context_window)")
        }
        return ModelPage(models: models, nextCursor: nil)
    }

    // MARK: - Ollama

    /// `GET /api/tags`: `models[]{name, modified_at, size, details{parameter_size, quantization_level}}`.
    static func ollamaTags(_ data: Data, context: Context) throws -> ModelPage {
        let items = try array(data, keys: ["models"])
        let models = items.compactMap { item -> ModelInfo? in
            guard let name = str(item["name"]) ?? str(item["model"]) else { return nil }
            let details = item["details"] as? [String: Any]
            let param = nonEmpty(str(details?["parameter_size"])).flatMap { $0 == "0" ? nil : $0 }
            let quant = nonEmpty(str(details?["quantization_level"]))
            let remote = str(item["remote_host"]) != nil || context.isCloud || name.hasSuffix(":cloud") || name.hasSuffix("-cloud")
            return ModelInfo(
                id: name, parameterSize: param.map(humanParameterSize), quantization: quant,
                created: isoDate(item["modified_at"]),
                source: "GET /api/tags", isLoaded: nil
            ).withSize(remote ? nil : int64(item["size"]))
        }
        return ModelPage(models: models, nextCursor: nil)
    }

    struct OllamaShowFacts: Sendable, Equatable {
        var contextLength: Int?
        var capabilities: [String]
        var parameterSize: String?
        var quantization: String?
    }

    /// `POST /api/show`: literal `model_info["<arch>.context_length"]`, `capabilities[]`.
    static func ollamaShow(_ data: Data) throws -> OllamaShowFacts {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelCatalogError.decoding("show response is not an object")
        }
        let info = root["model_info"] as? [String: Any] ?? [:]
        var context: Int?
        if let arch = str(info["general.architecture"]) { context = int(info["\(arch).context_length"]) }
        if context == nil {
            // No architecture key: accept a single unambiguous *.context_length entry.
            let hits = info.filter { $0.key.hasSuffix(".context_length") }
            if hits.count == 1 { context = int(hits.first?.value) }
        }
        let caps = (root["capabilities"] as? [Any])?.compactMap { str($0) } ?? []
        let details = root["details"] as? [String: Any]
        return OllamaShowFacts(
            contextLength: context, capabilities: caps,
            parameterSize: nonEmpty(str(details?["parameter_size"])).flatMap { $0 == "0" ? nil : humanParameterSize($0) },
            quantization: nonEmpty(str(details?["quantization_level"])))
    }

    /// `GET /api/ps`: names of models resident in memory.
    static func ollamaRunning(_ data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["models"] as? [[String: Any]] else { return [] }
        return Set(items.compactMap { str($0["name"]) ?? str($0["model"]) })
    }

    /// Ollama Cloud reports `parameter_size` as a raw count ("116829156672"); local as "8.0B".
    static func humanParameterSize(_ raw: String) -> String {
        guard let value = Double(raw), value >= 1_000_000 else { return raw }
        if value >= 1e9 { return String(format: "%.3gB", value / 1e9) }
        return String(format: "%.3gM", value / 1e6)
    }

    // MARK: - OpenRouter

    /// USD per token (decimal string) -> USD per million tokens. Negative (`"-1"` =
    /// variable) and unparseable values are unknown, zero is free.
    static func perMillion(fromPerToken raw: Any?) -> Double? {
        guard let text = str(raw), let decimal = Decimal(string: text), decimal >= 0 else { return nil }
        return NSDecimalNumber(decimal: decimal * 1_000_000).doubleValue
    }

    static func routerPrice(_ pricing: [String: Any]?, key: String) -> Double? {
        guard let rate = perMillion(fromPerToken: pricing?[key]) else { return nil }
        guard let discount = double(pricing?["discount"]) else { return rate }
        guard discount >= 0, discount <= 1 else { return nil }
        return rate * (1 - discount)
    }

    static func openRouter(_ data: Data) throws -> ModelPage {
        let items = try array(data, keys: ["data"])
        let models = items.compactMap { item -> ModelInfo? in
            guard let id = str(item["id"]) else { return nil }
            let arch = item["architecture"] as? [String: Any]
            let top = item["top_provider"] as? [String: Any]
            let pricing = item["pricing"] as? [String: Any]
            let params = (item["supported_parameters"] as? [Any])?.compactMap { str($0) } ?? []
            let input = (arch?["input_modalities"] as? [Any])?.compactMap { str($0) } ?? []
            let output = (arch?["output_modalities"] as? [Any])?.compactMap { str($0) } ?? []
            let hasParams = item["supported_parameters"] != nil
            return ModelInfo(
                id: id, displayName: str(item["name"]),
                contextLength: int(item["context_length"]) ?? int(top?["context_length"]),
                maxOutput: int(top?["max_completion_tokens"]),
                promptPricePerM: routerPrice(pricing, key: "prompt"),
                completionPricePerM: routerPrice(pricing, key: "completion"),
                inputModalities: input, outputModalities: output,
                supportsTools: hasParams ? params.contains("tools") : nil,
                supportsReasoning: hasParams ? (params.contains("reasoning") || params.contains("include_reasoning")) : nil,
                supportsVision: arch == nil ? nil : input.contains("image"),
                created: unixDate(item["created"]),
                source: "GET /api/v1/models")
        }
        return ModelPage(models: models, nextCursor: nil)
    }

    struct EndpointStats: Sendable, Equatable {
        var ttftMsP50: Double?
        var tokensPerSecP50: Double?
    }

    /// `GET /api/v1/models/{author}/{slug}/endpoints`: best (lowest) p50 latency and best
    /// p50 throughput across endpoints. Values are null without an API key.
    static func openRouterEndpointStats(_ data: Data) -> EndpointStats {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let endpoints = payload["endpoints"] as? [[String: Any]] else { return EndpointStats() }
        let latencies = endpoints.compactMap { double(($0["latency_last_30m"] as? [String: Any])?["p50"]) }
        let rates = endpoints.compactMap { double(($0["throughput_last_30m"] as? [String: Any])?["p50"]) }
        return EndpointStats(ttftMsP50: latencies.min(), tokensPerSecP50: rates.max())
    }

    // MARK: - Anthropic

    /// `data[]{id, display_name, created_at, max_input_tokens, max_tokens, capabilities}`;
    /// next page = `after_id=<last_id>` while `has_more`.
    static func anthropic(_ data: Data) throws -> ModelPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            throw ModelCatalogError.decoding("expected {data:[…]}")
        }
        let models = items.compactMap { item -> ModelInfo? in
            guard let id = str(item["id"]) else { return nil }
            let caps = item["capabilities"] as? [String: Any]
            func supported(_ key: String) -> Bool? {
                ((caps?[key] as? [String: Any])?["supported"]) as? Bool
            }
            let thinking = caps?["thinking"] as? [String: Any]
            let types = thinking?["types"] as? [String: Any]
            var reasoning: Bool?
            if thinking != nil {
                let adaptive = (types?["adaptive"] as? [String: Any])?["supported"] as? Bool
                let enabled = (types?["enabled"] as? [String: Any])?["supported"] as? Bool
                reasoning = (thinking?["supported"] as? Bool) ?? ((adaptive ?? false) || (enabled ?? false))
            }
            let vision = supported("image_input")
            return ModelInfo(
                id: id, displayName: str(item["display_name"]),
                contextLength: int(item["max_input_tokens"]), maxOutput: int(item["max_tokens"]),
                inputModalities: vision == true ? ["text", "image"] : [],
                supportsReasoning: reasoning, supportsVision: vision,
                created: isoDate(item["created_at"]),
                source: "GET /v1/models (max_input_tokens, max_tokens, capabilities)")
        }
        let more = root["has_more"] as? Bool ?? false
        return ModelPage(models: models, nextCursor: more ? str(root["last_id"]) : nil)
    }

    // MARK: - Gemini

    /// `models[]{name:"models/x", displayName, inputTokenLimit, outputTokenLimit, thinking,
    /// supportedGenerationMethods}`; keeps only models that can `generateContent`.
    static func gemini(_ data: Data) throws -> ModelPage {
        let root = try object(data)
        let items = root["models"] as? [[String: Any]] ?? []
        let models = items.compactMap { item -> ModelInfo? in
            guard let name = str(item["name"]) else { return nil }
            let methods = (item["supportedGenerationMethods"] as? [Any])?.compactMap { str($0) } ?? []
            if !methods.isEmpty, !methods.contains("generateContent") { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
            return ModelInfo(
                id: id, displayName: str(item["displayName"]),
                contextLength: int(item["inputTokenLimit"]), maxOutput: int(item["outputTokenLimit"]),
                supportsReasoning: item["thinking"] as? Bool,
                source: "GET /v1beta/models (token limits, methods, thinking)")
        }
        return ModelPage(models: models, nextCursor: nonEmpty(str(root["nextPageToken"])))
    }

    // MARK: - Together

    /// Bare array `[{id, type, display_name, created, context_length, pricing{input,output}}]`.
    /// Pricing units are not stated in the list schema. Only an explicit $/1M unit
    /// permits displaying rates; the serverless table does not prove list units.
    static func together(_ data: Data) throws -> ModelPage {
        let items = try array(data, keys: ["data", "models"])
        let models = items.compactMap { item -> ModelInfo? in
            guard let id = str(item["id"]) else { return nil }
            if let type = str(item["type"]), !["chat", "language", "code"].contains(type) { return nil }
            let pricing = item["pricing"] as? [String: Any]
            return ModelInfo(
                id: id, displayName: str(item["display_name"]),
                contextLength: int(item["context_length"]),
                promptPricePerM: str(pricing?["unit"]) == "usd_per_1m_tokens" ? nonNegative(double(pricing?["input"])) : nil,
                completionPricePerM: str(pricing?["unit"]) == "usd_per_1m_tokens" ? nonNegative(double(pricing?["output"])) : nil,
                created: unixDate(item["created"]),
                source: "GET /models (context_length; price units undocumented unless explicitly supplied)")
        }
        return ModelPage(models: models, nextCursor: nil)
    }

    // MARK: - LM Studio

    /// v1 `models[]{key, display_name, type, quantization{name}, size_bytes, params_string,
    /// loaded_instances[], max_context_length, capabilities{vision, trained_for_tool_use,
    /// reasoning}}`; falls back to the v0/OpenAI `data[]{id, type, state, quantization,
    /// max_context_length}` shape.
}

extension ModelParsers {
    static func lmStudio(_ data: Data) throws -> ModelPage {
        let root = try object(data)
        if let items = root["models"] as? [[String: Any]] {
            let models = items.compactMap { item -> ModelInfo? in
                guard let key = str(item["key"]) ?? str(item["id"]) else { return nil }
                if let type = str(item["type"]), type == "embedding" || type == "embeddings" { return nil }
                let caps = item["capabilities"] as? [String: Any]
                let quant = (item["quantization"] as? [String: Any]).flatMap { str($0["name"]) }
                    ?? str(item["quantization"])
                let loaded = item["loaded_instances"] as? [Any]
                let vision = caps?["vision"] as? Bool
                return ModelInfo(
                    id: key, displayName: str(item["display_name"]),
                    contextLength: int(item["max_context_length"]),
                    inputModalities: vision == true ? ["text", "image"] : [],
                    supportsTools: caps?["trained_for_tool_use"] as? Bool,
                    supportsReasoning: (caps?["reasoning"] as? [String: Any]).flatMap {
                        ($0["allowed_options"] as? [String]).map { $0.contains(where: { $0 != "off" }) }
                    },
                    supportsVision: vision, sizeBytes: int64(item["size_bytes"]),
                    parameterSize: nonEmpty(str(item["params_string"])), quantization: quant,
                    source: "GET /api/v1/models", isLoaded: loaded.map { !$0.isEmpty })
            }
            return ModelPage(models: models, nextCursor: nil)
        }
        let items = root["data"] as? [[String: Any]] ?? []
        let models = items.compactMap { item -> ModelInfo? in
            guard let id = str(item["id"]) else { return nil }
            if let type = str(item["type"]), type == "embeddings" { return nil }
            let state = str(item["state"])
            return ModelInfo(
                id: id, contextLength: int(item["max_context_length"]),
                inputModalities: str(item["type"]) == "vlm" ? ["text", "image"] : [],
                supportsVision: str(item["type"]).map { $0 == "vlm" },
                quantization: nonEmpty(str(item["quantization"])),
                source: "GET /api/v0/models", isLoaded: state.map { $0 == "loaded" })
        }
        return ModelPage(models: models, nextCursor: nil)
    }

    // MARK: - Fireworks

    /// Account list `models[]{name, displayName, createTime, contextLength, supportsImageInput,
    /// supportsTools, baseModelDetails{parameterCount, defaultPrecision}}`, `nextPageToken`.
    static func fireworks(_ data: Data) throws -> ModelPage {
        let root = try object(data)
        let items = (root["models"] as? [[String: Any]]) ?? (root["data"] as? [[String: Any]]) ?? []
        let models = items.compactMap { item -> ModelInfo? in
            guard let name = str(item["name"]) ?? str(item["id"]) else { return nil }
            let details = item["baseModelDetails"] as? [String: Any]
            let vision = item["supportsImageInput"] as? Bool
            let count = str(details?["parameterCount"]).flatMap { Double($0) }
            return ModelInfo(
                id: name, displayName: str(item["displayName"]),
                contextLength: int(item["contextLength"]),
                inputModalities: vision == true ? ["text", "image"] : [],
                supportsTools: item["supportsTools"] as? Bool, supportsVision: vision,
                parameterSize: count.map { humanParameterSize(String(format: "%.0f", $0)) },
                quantization: nonEmpty(str(details?["defaultPrecision"])),
                created: isoDate(item["createTime"]),
                source: "GET /v1/accounts/fireworks/models")
        }
        return ModelPage(models: models, nextCursor: nonEmpty(str(root["nextPageToken"])))
    }

    // MARK: - Perplexity

    /// Router `data[]{id, created, pricing{input, output, unit:"usd_per_1m_tokens"}}`.
    static func perplexity(_ data: Data) throws -> ModelPage {
        let items = try array(data, keys: ["data"])
        let models = items.compactMap { item -> ModelInfo? in
            guard let id = str(item["id"]) else { return nil }
            let pricing = item["pricing"] as? [String: Any]
            let perM = str(pricing?["unit"]) == "usd_per_1m_tokens"
            return ModelInfo(
                id: id,
                promptPricePerM: perM ? nonNegative(double(pricing?["input"])) : nil,
                completionPricePerM: perM ? nonNegative(double(pricing?["output"])) : nil,
                created: unixDate(item["created"]),
                source: "GET /router/v1/models (pricing)")
        }
        return ModelPage(models: models, nextCursor: nil)
    }

    // MARK: - xAI

    /// Prices are USD cents per 100M tokens: divide by 1e4 for USD per million
    /// (`12500` = $1.25 / 1M).
    static func xaiPerMillion(_ raw: Any?) -> Double? {
        nonNegative(double(raw)).map { $0 / 10_000 }
    }

    /// `/language-models`: `models[]` (or `data[]`) `{id, created, input_modalities,
    /// output_modalities, context_length, prompt_text_token_price,
    /// completion_text_token_price, capabilities{reasoning_effort[]}}`.
    static func xai(_ data: Data) throws -> ModelPage {
        let root = try object(data)
        let items = (root["models"] as? [[String: Any]]) ?? (root["data"] as? [[String: Any]]) ?? []
        let models = items.compactMap { item -> ModelInfo? in
            guard let id = str(item["id"]) else { return nil }
            let input = (item["input_modalities"] as? [Any])?.compactMap { str($0) } ?? []
            let output = (item["output_modalities"] as? [Any])?.compactMap { str($0) } ?? []
            let efforts = (item["capabilities"] as? [String: Any])?["reasoning_effort"] as? [Any]
            return ModelInfo(
                id: id, contextLength: int(item["context_length"]),
                promptPricePerM: xaiPerMillion(item["prompt_text_token_price"]),
                completionPricePerM: xaiPerMillion(item["completion_text_token_price"]),
                inputModalities: input, outputModalities: output,
                supportsReasoning: efforts.map { !$0.isEmpty },
                supportsVision: input.isEmpty ? nil : input.contains("image"),
                created: unixDate(item["created"]),
                source: "GET /v1/language-models (prices: cents per 100M tokens converted)")
        }
        return ModelPage(models: models, nextCursor: nil)
    }

    // MARK: - Cohere

    /// `models[]{name, endpoints[], context_length, features[], is_deprecated}`, `next_page_token`.
    static func cohere(_ data: Data) throws -> ModelPage {
        let root = try object(data)
        let items = root["models"] as? [[String: Any]] ?? []
        let models = items.compactMap { item -> ModelInfo? in
            guard let name = str(item["name"]) else { return nil }
            let endpoints = (item["endpoints"] as? [Any])?.compactMap { str($0) } ?? []
            if !endpoints.isEmpty, !endpoints.contains("chat") { return nil }
            if item["is_deprecated"] as? Bool == true || item["finetuned"] as? Bool == true { return nil }
            let features = (item["features"] as? [Any])?.compactMap { str($0) } ?? []
            let hasFeatures = item["features"] != nil
            return ModelInfo(
                id: name, contextLength: int(item["context_length"]),
                supportsTools: hasFeatures ? features.contains("tools") : nil,
                supportsVision: hasFeatures ? features.contains("vision") : nil,
                source: "GET /v1/models (context_length, features)")
        }
        return ModelPage(models: models, nextCursor: nonEmpty(str(root["next_page_token"])))
    }

    // MARK: - Azure

    /// Data-plane `/openai/models`: base and fine-tuned models, NOT deployments. Deployment
    /// names must be typed; this list only hints at what the resource can serve.
    static func azureBaseModels(_ data: Data) throws -> ModelPage {
        let items = try array(data, keys: ["data"])
        let models = items.compactMap { item -> ModelInfo? in
            guard let id = str(item["id"]) else { return nil }
            let caps = item["capabilities"] as? [String: Any]
            if let chat = caps?["chat_completion"] as? Bool, !chat { return nil }
            return ModelInfo(
                id: id, created: unixDate(item["created_at"]) ?? isoDate(item["created_at"]),
                source: "GET /openai/models (base models, not your deployments)")
        }
        return ModelPage(models: models, nextCursor: nil)
    }

    // MARK: - JSON helpers

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelCatalogError.decoding("expected a JSON object")
        }
        return root
    }

    /// Accepts a bare array or an object holding the array under one of `keys`.
    private static func array(_ data: Data, keys: [String]) throws -> [[String: Any]] {
        let any = try? JSONSerialization.jsonObject(with: data)
        if let bare = any as? [[String: Any]] { return bare }
        if let root = any as? [String: Any] {
            for key in keys { if let items = root[key] as? [[String: Any]] { return items } }
            if root.isEmpty { return [] }
        }
        throw ModelCatalogError.decoding("expected {\(keys.joined(separator: "|")):[…]}")
    }

    static func str(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue > 0 ? number.intValue : nil }
        if let text = value as? String, let parsed = Int(text), parsed > 0 { return parsed }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.int64Value > 0 ? number.int64Value : nil }
        if let text = value as? String, let parsed = Int64(text), parsed > 0 { return parsed }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func nonNegative(_ value: Double?) -> Double? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Unix seconds; 0 (Cerebras example) and missing are unknown.
    static func unixDate(_ value: Any?) -> Date? {
        guard let seconds = double(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// RFC 3339 with any fractional precision (Ollama emits nanoseconds); epoch dates are unknown.
    static func isoDate(_ value: Any?) -> Date? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            text.removeSubrange(dot..<end)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text), date.timeIntervalSince1970 > 86_400 else { return nil }
        return date
    }
}

extension ModelInfo {
    fileprivate func withSize(_ bytes: Int64?) -> ModelInfo {
        var copy = self
        copy.sizeBytes = bytes
        return copy
    }
}
