import Foundation

// MARK: - Errors

/// Why a `clippy://` URL was rejected. Never carries URL content, so it is
/// safe to log and to put in an audit entry.
enum ClippyURLError: Error, Equatable {
    case wrongScheme
    case unknownAction
    case unexpectedPathOrFragment
    case missingParameter(String)
    case unknownParameter(String)
    case duplicateParameter(String)
    case invalidParameter(String)
    case tooLarge(String)
}

// MARK: - Parsed action

/// A validated `clippy://` invocation. Parsing is pure: no I/O, no defaults
/// reads, so the whole validation matrix is unit-testable.
///
/// Grammar (all parameters are percent-decoded by URLComponents):
/// - `clippy://search?q=<query>`   `q` up to `maxQueryLength` characters
/// - `clippy://get?id=<int>`       positive clip id
/// - `clippy://add?text=<text>`    up to `maxTextBytes` UTF-8 bytes, no NUL
/// - `clippy://open`, `clippy://paste-latest`, `clippy://settings`, `clippy://palette`
enum ClippyURL: Equatable {
    case search(query: String)
    case get(id: Int64)
    case add(text: String)
    case open
    case pasteLatest
    case settings
    case palette

    /// The URL scheme this app registers (CFBundleURLTypes).
    static let scheme = "clippy"
    /// Longest accepted search query, in characters.
    static let maxQueryLength = 500
    /// Largest accepted `add` payload, in UTF-8 bytes (a URL is not a transport for bulk data).
    static let maxTextBytes = 64 * 1024

    /// Stable action name for audit entries and policy tables.
    enum Action: String, CaseIterable {
        case search, get, add, open
        case pasteLatest = "paste-latest"
        case settings, palette
    }

    /// The action this URL performs.
    var action: Action {
        switch self {
        case .search: return .search
        case .get: return .get
        case .add: return .add
        case .open: return .open
        case .pasteLatest: return .pasteLatest
        case .settings: return .settings
        case .palette: return .palette
        }
    }

    // MARK: Parsing

    /// Validates `url` strictly: exact scheme, known action, only the parameters
    /// that action defines (each at most once), size caps, no control characters.
    static func parse(_ url: URL) -> Result<ClippyURL, ClippyURLError> {
        guard url.scheme?.lowercased() == scheme else { return .failure(.wrongScheme) }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil
        else { return .failure(.invalidParameter("url")) }
        guard let host = parts.host?.lowercased(), let action = Action(rawValue: host) else {
            return .failure(.unknownAction)
        }
        guard (parts.path.isEmpty || parts.path == "/"), parts.fragment == nil else {
            return .failure(.unexpectedPathOrFragment)
        }
        let allowed = allowedParameters(for: action)
        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard allowed.contains(item.name) else { return .failure(.unknownParameter(item.name)) }
            guard values[item.name] == nil else { return .failure(.duplicateParameter(item.name)) }
            values[item.name] = item.value ?? ""
        }
        return build(action, values)
    }

    private static func allowedParameters(for action: Action) -> Set<String> {
        switch action {
        case .search: return ["q"]
        case .get: return ["id"]
        case .add: return ["text"]
        case .open, .pasteLatest, .settings, .palette: return []
        }
    }

    private static func build(_ action: Action, _ values: [String: String]) -> Result<ClippyURL, ClippyURLError> {
        switch action {
        case .search:
            guard let query = values["q"] else { return .failure(.missingParameter("q")) }
            guard query.count <= maxQueryLength else { return .failure(.tooLarge("q")) }
            guard !hasControlCharacters(query) else { return .failure(.invalidParameter("q")) }
            return .success(.search(query: query))
        case .get:
            guard let raw = values["id"] else { return .failure(.missingParameter("id")) }
            guard raw.count <= 18, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let identifier = Int64(raw), identifier > 0
            else { return .failure(.invalidParameter("id")) }
            return .success(.get(id: identifier))
        case .add:
            guard let text = values["text"] else { return .failure(.missingParameter("text")) }
            guard text.utf8.count <= maxTextBytes else { return .failure(.tooLarge("text")) }
            guard !text.isEmpty, !text.unicodeScalars.contains("\u{0}") else {
                return .failure(.invalidParameter("text"))
            }
            return .success(.add(text: text))
        case .open: return .success(.open)
        case .pasteLatest: return .success(.pasteLatest)
        case .settings: return .success(.settings)
        case .palette: return .success(.palette)
        }
    }

    /// Search queries are one line; tabs and newlines are rejected with the rest of C0/C1.
    private static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    // MARK: Building (used by the CLI and Shortcuts to form valid URLs)

    /// A canonical URL for this action, percent-encoded so it round-trips through `parse`.
    var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = action.rawValue
        switch self {
        case .search(let query): parts.queryItems = [URLQueryItem(name: "q", value: query)]
        case .get(let identifier): parts.queryItems = [URLQueryItem(name: "id", value: String(identifier))]
        case .add(let text): parts.queryItems = [URLQueryItem(name: "text", value: text)]
        default: break
        }
        // URLComponents leaves '&', '+' and '=' literal inside values; encode them explicitly.
        if let items = parts.queryItems {
            parts.percentEncodedQuery = items.map { item in
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&+=#%")
                let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(item.name)=\(value)"
            }.joined(separator: "&")
        }
        return parts.url ?? URL(string: "\(Self.scheme)://\(action.rawValue)")!
    }
}

// MARK: - Confirmation policy

/// What the handler must do before running a parsed URL.
enum ClippyURLDecision: Equatable {
    /// Run immediately.
    case allow
    /// Ask the user once (NSAlert) before running.
    case promptOnce
}

/// Per-action confirmation policy. Read-only and UI-navigation actions always
/// run. Mutating actions (`add` writes a clip; `paste-latest` injects keystrokes
/// into another app) run silently only when the user enabled URL scheme writes,
/// or after the user approved a prompt earlier in this session.
enum ClippyURLPolicy {

    /// Actions that change data or act on another app.
    static func isMutating(_ action: ClippyURL.Action) -> Bool {
        switch action {
        case .add, .pasteLatest: return true
        case .search, .get, .open, .settings, .palette: return false
        }
    }

    /// - Parameters:
    ///   - allowWrites: the "allow URL scheme writes" setting.
    ///   - approvedThisSession: the user already approved a prompt for this action.
    static func decision(for action: ClippyURL.Action, allowWrites: Bool,
                         approvedThisSession: Bool) -> ClippyURLDecision {
        guard isMutating(action) else { return .allow }
        return (allowWrites || approvedThisSession) ? .allow : .promptOnce
    }
}
