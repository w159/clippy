import Foundation

/// A descriptor + instance + credentials, ready for a transport to use. Built by
/// `AIProviderStore.resolve()`; never persisted.
struct ResolvedProvider: Sendable {
    let descriptor: ProviderDescriptor
    let instance: ProviderInstance
    let apiKey: String
    /// Secret header values (already read from the Keychain), by header name.
    let secretHeaders: [String: String]
    /// Set (by `resolveForModels`) when the Keychain refused a credential read; the key or
    /// header is then empty and the UI can explain why.
    var keychainDeniedStatus: OSStatus? = nil

    /// The normalized base URL (instance override, else the descriptor default).
    /// nil for Apple Intelligence or when the URL is unusable.
    var effectiveBaseURL: URL? {
        guard descriptor.family != .appleFoundation else { return nil }
        if case .success(let url) = baseURLResult { return url }
        return nil
    }

    var baseURLResult: Result<URL, URLNormalizer.Failure> {
        let raw = instance.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URLNormalizer.normalize(raw.isEmpty ? descriptor.defaultBaseURL : raw, for: descriptor)
    }

    /// Model to send: the instance's, else the descriptor default.
    var effectiveModel: String {
        let model = instance.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? (descriptor.defaultModel ?? "") : model
    }

    /// Azure deployment name: explicit deployment, else the model field.
    var effectiveDeployment: String {
        let deployment = instance.deployment.trimmingCharacters(in: .whitespacesAndNewlines)
        return deployment.isEmpty ? instance.model.trimmingCharacters(in: .whitespacesAndNewlines) : deployment
    }

    func url(for purpose: EndpointPurpose) -> URL? {
        guard let base = effectiveBaseURL else { return nil }
        var query = descriptor.queryParams
        let version = instance.apiVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if descriptor.fields.contains(.apiVersion), !version.isEmpty { query["api-version"] = version }
        switch purpose {
        case .chat, .stream:
            let template = purpose == .chat ? descriptor.chatPath : descriptor.streamPath
            guard let path = substitute(template) else { return nil }
            return URLNormalizer.join(base: base, path: path, query: query)
        case .models:
            guard let spec = descriptor.models, spec.parser != .none, !spec.url.isEmpty else { return nil }
            let lower = spec.url.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                return URL(string: spec.url)
            }
            return URLNormalizer.join(base: base, path: spec.url, query: query)
        }
    }

    /// Fixed + auth + user headers. User headers come last and replace earlier ones
    /// case-insensitively.
    var allHeaders: [String: String] {
        var ordered: [(name: String, value: String)] = descriptor.fixedHeaders.sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
        if !apiKey.isEmpty, descriptor.auth.scheme != .none, let header = descriptor.auth.header {
            ordered.append((header, (descriptor.auth.prefix ?? "") + apiKey))
        }
        if !instance.organization.isEmpty { ordered.append(("OpenAI-Organization", instance.organization)) }
        if !instance.project.isEmpty { ordered.append(("OpenAI-Project", instance.project)) }
        for entry in instance.headers {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let value = entry.isSecret ? (secretHeaders[name] ?? "") : entry.value
            guard !value.isEmpty else { continue }
            ordered.append((name, value))
        }
        var result: [String: String] = [:]
        for (name, value) in ordered {
            if let existing = result.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                result.removeValue(forKey: existing)
            }
            result[name] = value
        }
        return result
    }

    /// True only when the request provably stays on this Mac.
    var isVerifiedLoopback: Bool {
        guard HostLocality.isVerifiedLoopback(effectiveBaseURL) else { return false }
        return !Self.modelLeavesMac(effectiveModel, descriptor: descriptor)
    }

    /// Loopback or on-device: the gate for capture-time features.
    var keepsDataOnMac: Bool { descriptor.family == .appleFoundation || isVerifiedLoopback }

    /// Ollama proxies `name:cloud` / `name-cloud` models to ollama.com even when the
    /// request goes to localhost.
    static func modelLeavesMac(_ model: String, descriptor: ProviderDescriptor) -> Bool {
        guard descriptor.family == .ollamaChat else { return false }
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasSuffix(":cloud") || lower.hasSuffix("-cloud")
    }

    /// One line for logs and Settings. Never contains a credential.
    var displaySummary: String {
        let location = descriptor.family == .appleFoundation
            ? "on device" : (effectiveBaseURL?.host ?? "invalid URL")
        let model = effectiveModel
        return model.isEmpty ? "\(instance.name) (\(location))" : "\(instance.name) · \(model) (\(location))"
    }

    // MARK: - Internals

    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()

    /// Fills `{deployment}` / `{model}`; nil when a required value is empty.
    private func substitute(_ template: String) -> String? {
        var out = template
        for (token, value) in [("{deployment}", effectiveDeployment), ("{model}", effectiveModel)]
        where out.contains(token) {
            guard !value.isEmpty,
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed)
            else { return nil }
            out = out.replacingOccurrences(of: token, with: encoded)
        }
        return out
    }
}
