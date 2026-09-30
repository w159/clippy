import Foundation

struct AIRequestFailure: Sendable, Equatable {
    var provider: String
    var requestURLDisplay: String
    var status: Int?
    var message: String
    var hint: String
    var description: String {
        "\(provider) · \(requestURLDisplay)\(status.map { " · HTTP \($0)" } ?? ""): \(message) \(hint)"
    }
}

enum AIErrorMapper {
    static func displayURL(_ url: URL?) -> String {
        guard let url else { return "invalid endpoint" }
        return (url.host ?? "") + (url.port.map { ":\($0)" } ?? "") + url.path
    }

    static func message(_ data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = root["error"] as? String { return error }
            if let error = root["error"] as? [String: Any], let text = error["message"] as? String { return text }
            if let text = root["message"] as? String { return text }
        }
        return String(data: data, encoding: .utf8).map { String($0.prefix(2000)) } ?? "Unreadable provider error"
    }

    static func failure(resolved: ResolvedProvider, status: Int?, data: Data, purpose: EndpointPurpose = .chat) -> AIRequestFailure {
        let text = message(data)
        let hint: String
        switch status ?? 0 {
        case 401, 403: hint = "Check the API key, custom authentication headers and resource permissions."
        case 404: hint = "Check the model/deployment name and the endpoint path shown above. For Ollama, install the model first."
        case 429: hint = "Provider rate limit or quota reached. Check quota and wait before trying again."
        case 400: hint = "Check model-supported parameters and Advanced request overrides."
        case 500...599: hint = "The provider is temporarily unavailable. Try again later."
        default: hint = "Check provider settings and service availability."
        }
        return AIRequestFailure(provider: resolved.instance.name, requestURLDisplay: displayURL(resolved.url(for: purpose)), status: status, message: redact(text, resolved: resolved), hint: hint)
    }

    static func network(error: Error, resolved: ResolvedProvider, purpose: EndpointPurpose = .chat) -> AIError {
        if let ai = error as? AIError {
            if case .decoding(let text) = ai {
                return .provider(failure(resolved: resolved, status: nil, data: Data(text.utf8), purpose: purpose))
            }
            return ai
        }
        let code = (error as? URLError)?.code
        let hint: String
        switch code {
        case .appTransportSecurityRequiresSecureConnection:
            hint = "macOS blocks plain HTTP to non-loopback hosts. Use HTTPS, or connect to an Ollama daemon on localhost."
        case .cannotConnectToHost:
            hint = "Is the server running? For local Ollama, start the Ollama daemon and check its port."
        case .timedOut:
            hint = "The configured request deadline expired. Cold local models may need a longer timeout."
        default: hint = "Check connectivity and the configured endpoint."
        }
        return .provider(AIRequestFailure(provider: resolved.instance.name,
                                         requestURLDisplay: displayURL(resolved.url(for: purpose)), status: nil,
                                         message: redact(error.localizedDescription, resolved: resolved), hint: hint))
    }

    static func timeout(_ phase: String, resolved: ResolvedProvider, purpose: EndpointPurpose = .chat) -> AIError {
        .provider(AIRequestFailure(provider: resolved.instance.name,
                                   requestURLDisplay: displayURL(resolved.url(for: purpose)), status: nil,
                                   message: "\(phase) timeout",
                                   hint: "Increase this provider's timeout. Ollama may still be loading or thinking."))
    }

    private static func redact(_ text: String, resolved: ResolvedProvider) -> String {
        var result = text
        for secret in [resolved.apiKey] + Array(resolved.secretHeaders.values) where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        for purpose in [EndpointPurpose.chat, .stream] {
            if let url = resolved.url(for: purpose)?.absoluteString {
                result = result.replacingOccurrences(of: url, with: displayURL(resolved.url(for: purpose)))
            }
        }
        return result
    }
}
