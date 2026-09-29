import Foundation

/// Decides whether a URL may be sent to its host for a link preview (FEAT-14).
/// Rejects non-http(s), userinfo (credentials) and common token/secret query parameters.
enum LinkURLSanitizer {
    /// Query parameter names (lowercased) that indicate a secret or session.
    static let blockedParameters: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "auth", "authorization", "key", "apikey", "api_key",
        "api-key", "secret", "client_secret", "password", "passwd", "pwd", "sig", "signature", "session",
        "sessionid", "sid", "code", "jwt", "otp", "x-amz-signature", "x-amz-credential", "x-amz-security-token",
        "sas", "bearer", "credential", "magic", "reset", "invite"
    ]

    /// Returns the URL with its fragment removed when it is safe to fetch, else nil.
    static func sanitized(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        for item in parts.queryItems ?? [] where isBlocked(item.name) { return nil }
        parts.fragment = nil
        return parts.url
    }

    /// True when a parameter name looks like a credential.
    static func isBlocked(_ name: String) -> Bool {
        let lower = name.lowercased()
        if blockedParameters.contains(lower) { return true }
        return lower.hasSuffix("_token") || lower.hasSuffix("-token") || lower.hasSuffix("_key") || lower.hasSuffix("_secret")
    }
}
