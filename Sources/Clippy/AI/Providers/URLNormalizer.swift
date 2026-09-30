import Foundation

/// Pure URL hygiene for user-typed endpoints. The rule: a stored base URL is the part
/// BEFORE the provider's chat path, so a pasted `/v1`, `/api`, `/chat/completions` or
/// Azure `/openai/...` tail is stripped and never doubled (docs/ai/diagnosis.md).
enum URLNormalizer {
    enum Failure: Error, Equatable {
        case empty
        case placeholder
        case notHTTP
        case malformed
    }

    /// Normalizes `raw` for a descriptor. Host-only input for the descriptor's own host
    /// adopts the default path prefix (e.g. `https://api.openai.com` -> `.../v1`).
    static func normalize(_ raw: String, for descriptor: ProviderDescriptor) -> Result<URL, Failure> {
        normalize(raw, family: descriptor.family, chatPath: descriptor.chatPath,
                  defaultBase: descriptor.defaultBaseURL)
    }

    static func normalize(_ raw: String, family: WireFamily, chatPath: String = "",
                          defaultBase: String = "") -> Result<URL, Failure> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed.contains("{") || trimmed.contains("}") || trimmed.uppercased().contains("YOUR-RESOURCE") {
            return .failure(.placeholder)
        }
        guard var comps = URLComponents(string: trimmed), let scheme = comps.scheme?.lowercased() else {
            return .failure(.malformed)
        }
        guard scheme == "http" || scheme == "https" else { return .failure(.notHTTP) }
        guard let host = comps.host, !host.isEmpty else { return .failure(.malformed) }
        comps.scheme = scheme
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil

        var path = collapse(comps.path)
        path = stripTail(path, family: family, chatPath: chatPath)
        if path.isEmpty, let prefix = defaultPrefix(host: host, defaultBase: defaultBase, family: family) {
            path = prefix
        }
        if family == .azureV1 { path += "/openai/v1" }
        comps.path = path
        guard let url = comps.url else { return .failure(.malformed) }
        return .success(url)
    }

    /// Joins `path` (may hold an inline `?query`) onto `base` and merges `query`
    /// (explicit entries win over the inline ones). No double slashes.
    static func join(base: URL, path: String, query: [String: String] = [:]) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var pathPart = path
        var inline: [URLQueryItem] = []
        if let mark = path.firstIndex(of: "?") {
            pathPart = String(path[..<mark])
            inline = URLComponents(string: "?" + path[path.index(after: mark)...])?.queryItems ?? []
        }
        let basePath = collapse(comps.path)
        let tail = collapse(pathPart)
        var pathAllowed = CharacterSet.urlPathAllowed
        pathAllowed.insert(charactersIn: "%")
        guard let encodedPath = (basePath + tail).addingPercentEncoding(withAllowedCharacters: pathAllowed) else { return nil }
        comps.percentEncodedPath = encodedPath
        var merged: [String: String] = [:]
        for item in (comps.queryItems ?? []) + inline { merged[item.name] = item.value ?? "" }
        for (key, value) in query { merged[key] = value }
        comps.queryItems = merged.isEmpty ? nil
            : merged.keys.sorted().map { URLQueryItem(name: $0, value: merged[$0]) }
        return comps.url
    }

    // MARK: - Internals

    /// Collapses repeated slashes, drops the trailing one, guarantees a leading one
    /// (or returns "" for an empty path).
    private static func collapse(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
    }

    private static func defaultPrefix(host: String, defaultBase: String, family: WireFamily) -> String? {
        guard family != .azureV1, family != .azureDeployments,
              let def = URLComponents(string: defaultBase), def.host?.lowercased() == host.lowercased()
        else { return nil }
        let prefix = collapse(def.path)
        return prefix.isEmpty ? nil : prefix
    }

    private static func stripTail(_ input: String, family: WireFamily, chatPath: String) -> String {
        var path = input
        switch family {
        case .azureDeployments, .azureV1:
            // Everything from "/openai" on belongs to the API, not to the base.
            if let range = path.range(of: "/openai", options: [.caseInsensitive]) {
                path = String(path[..<range.lowerBound])
            }
            return path
        case .geminiNative:
            if let range = path.range(of: "/models") { path = String(path[..<range.lowerBound]) }
            return path
        case .appleFoundation:
            return path
        case .openaiChat, .anthropicMessages, .ollamaChat:
            break
        }
        // "/v1" is deliberately not part of these: whether it belongs to the base depends on
        // the descriptor's chat path and is handled below.
        let endpoints = ["/chat/completions", "/messages", "/api/chat", "/api/tags", "/models", "/responses"]
        // The descriptor's own chat path (without placeholders/query) is also an endpoint.
        let own = collapse(String(chatPath.split(separator: "?").first ?? ""))
        var changed = true
        while changed {
            changed = false
            for tail in endpoints + (own.isEmpty ? [] : [own]) where path.lowercased().hasSuffix(tail) {
                path = String(path.dropLast(tail.count))
                changed = true
            }
        }
        // Version/prefix segments the chat path re-adds: strip them only then.
        var segments: [String] = []
        if chatPath.hasPrefix("/v1/") || chatPath == "/v1" { segments += ["/api/v1", "/v1"] }
        if chatPath.hasPrefix("/api/") { segments += ["/api"] }
        if family == .ollamaChat { segments += ["/v1", "/api"] }
        if family == .anthropicMessages { segments += ["/v1"] }
        for seg in segments where path.lowercased().hasSuffix(seg) {
            path = String(path.dropLast(seg.count))
            break
        }
        return path
    }
}
