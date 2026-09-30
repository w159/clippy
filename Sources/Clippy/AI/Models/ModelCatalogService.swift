import Foundation

/// Session cache scoped to an instance and endpoint. Explicit Refresh invalidates it.
private actor ModelSessionCache {
    static let shared = ModelSessionCache()
    private var entries: [String: [ModelInfo]] = [:]
    func get(_ key: String) -> [ModelInfo]? { entries[key] }
    func put(_ models: [ModelInfo], key: String) { entries[key] = models }
    func remove(_ key: String) { entries.removeValue(forKey: key) }
}

enum ModelCatalogService {
    static func fetch(_ resolved: ResolvedProvider) async throws -> [ModelInfo] {
        try await fetch(resolved, refresh: false)
    }

    static func fetch(_ resolved: ResolvedProvider, refresh: Bool) async throws -> [ModelInfo] {
        guard let spec = resolved.descriptor.models, let url = resolved.url(for: .models) else {
            throw ModelCatalogError.noListEndpoint
        }
        let key = resolved.instance.id.uuidString + ":" + url.absoluteString
        if refresh { await ModelSessionCache.shared.remove(key) }
        else if let cached = await ModelSessionCache.shared.get(key) { return cached }
        var models: [ModelInfo] = []
        var nextURL: URL? = url
        var visited: Set<URL> = []
        while let pageURL = nextURL {
            try Task.checkCancellation()
            guard visited.insert(pageURL).inserted else { throw ModelCatalogError.decoding("Repeated pagination cursor") }
            let data = try await request(pageURL, resolved: resolved, authenticated: spec.needsAuth)
            let page = try ModelParsers.parse(spec.parser, data: data,
                                             context: .init(isCloud: !resolved.isVerifiedLoopback))
            models += page.models
            nextURL = nil
            if let cursor = page.nextCursor {
                var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let name: String
                switch spec.parser {
                case .anthropic: name = "after_id"
                case .cohere: name = "page_token"
                default: name = "pageToken"
                }
                var query = parts?.queryItems ?? []
                query.removeAll { $0.name == name }
                query.append(URLQueryItem(name: name, value: cursor))
                parts?.queryItems = query
                nextURL = parts?.url
            }
        }
        var seen: Set<String> = []
        models = models.filter { seen.insert($0.id).inserted }
        if spec.parser == .ollamaTags {
            models = try await enrichOllama(models, resolved: resolved)
        }
        models = models.map { StaticModelFacts.enrich($0, providerID: resolved.descriptor.id) }
        try Task.checkCancellation()
        await ModelSessionCache.shared.put(models, key: key)
        return models
    }

    /// Lazy endpoint enrichment when a row is selected, never N requests for a large catalog.
    /// Catalog latency is provider-reported, not a measurement on this Mac.
    static func enrichEndpoint(_ model: ModelInfo, resolved: ResolvedProvider) async throws -> ModelInfo {
        guard resolved.descriptor.models?.parser == .openRouter, !resolved.apiKey.isEmpty,
              let base = resolved.effectiveBaseURL,
              let url = URLNormalizer.join(base: base, path: "/models/\(model.id)/endpoints", query: [:]) else { return model }
        let data = try await request(url, resolved: resolved)
        let stats = ModelParsers.openRouterEndpointStats(data)
        var copy = model
        copy.ttftMs = stats.ttftMsP50
        copy.tokensPerSec = stats.tokensPerSecP50
        if copy.ttftMs != nil || copy.tokensPerSec != nil {
            copy.source += "; /endpoints (best provider p50, last 30m)"
        }
        return copy
    }

    private static func enrichOllama(_ models: [ModelInfo], resolved: ResolvedProvider) async throws -> [ModelInfo] {
        guard let base = resolved.effectiveBaseURL,
              let showURL = URLNormalizer.join(base: base, path: "/api/show", query: [:]) else { return models }
        var result = models
        try await withThrowingTaskGroup(of: (Int, ModelParsers.OllamaShowFacts?).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let model = models[index]
                group.addTask {
                    do {
                        let body = try JSONSerialization.data(withJSONObject: ["model": model.id, "verbose": false])
                        let data = try await request(showURL, resolved: resolved, body: body, authenticated: false)
                        return (index, try ModelParsers.ollamaShow(data))
                    } catch {
                        try Task.checkCancellation()
                        return (index, nil) // A model can disappear or have no show metadata.
                    }
                }
            }
            while next < min(4, models.count) { enqueue(next); next += 1 }
            while let (index, facts) = try await group.next() {
                try Task.checkCancellation()
                if let facts {
                    result[index].contextLength = facts.contextLength
                    result[index].parameterSize = facts.parameterSize ?? result[index].parameterSize
                    result[index].quantization = facts.quantization ?? result[index].quantization
                    if !facts.capabilities.isEmpty {
                        result[index].supportsTools = facts.capabilities.contains("tools")
                        result[index].supportsReasoning = facts.capabilities.contains("thinking")
                        result[index].supportsVision = facts.capabilities.contains("vision")
                        if facts.capabilities.contains("completion") { result[index].outputModalities = ["text"] }
                        result[index].inputModalities = facts.capabilities.contains("vision") ? ["text", "image"] : ["text"]
                    }
                    result[index].source += " + POST /api/show"
                }
                if next < models.count { enqueue(next); next += 1 }
            }
        }
        if resolved.isVerifiedLoopback, let psURL = URLNormalizer.join(base: base, path: "/api/ps", query: [:]),
           let data = try? await request(psURL, resolved: resolved, authenticated: false) {
            let running = ModelParsers.ollamaRunning(data)
            for index in result.indices { result[index].isLoaded = running.contains(result[index].id) }
        }
        try Task.checkCancellation()
        return result
    }

    static func request(_ url: URL, resolved: ResolvedProvider, body: Data? = nil,
                        authenticated: Bool = true) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        // Public catalogs work without credentials; preserve custom non-auth headers.
        for (name, value) in resolved.allHeaders {
            if !authenticated && (name.caseInsensitiveCompare("Authorization") == .orderedSame
                || name.caseInsensitiveCompare(resolved.descriptor.auth.header ?? "") == .orderedSame) { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelCatalogError.transport("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let hint: String
            switch http.statusCode {
            case 401, 403: hint = "Check the API key and model-list permissions."
            case 404: hint = "Model listing is not available at this endpoint. Enter a model or deployment id manually."
            case 429: hint = "The provider rate limit was reached. Try Refresh later."
            default: hint = "The provider could not return its model catalog."
            }
            throw ModelCatalogError.http(http.statusCode, hint)
        }
        return data
    }
}
