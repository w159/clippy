import Foundation

// MARK: web_search

/// Search the web via DuckDuckGo's HTML endpoint and return the top results as
/// title + URL + snippet. No API key required. The query is sent to DuckDuckGo,
/// so the tool is gated by its own settings toggle.
///
/// The endpoint is POST-only in practice: a GET returns a 202 bot challenge,
/// while a form POST returns parseable result markup (verified against the live
/// endpoint). Networking and parsing are split so the parser is unit-tested
/// without touching the network, and tests inject canned HTML via `fetchHTML`.
struct WebSearchTool: AITool {
    let name = "web_search"
    let description = "Search the web for current information. Returns the top results as title, URL, and a short snippet. Use when the user "
        + "asks about recent events, documentation, or facts you are unsure of."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "The search query.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["query"],
    ]

    /// Injected so tests supply canned HTML instead of hitting the network.
    let fetchHTML: (String) async throws -> String

    init(fetchHTML: @escaping (String) async throws -> String = WebSearchTool.duckDuckGoHTML) {
        self.fetchHTML = fetchHTML
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let query = args["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: query parameter is required."
        }
        let html: String
        do {
            html = try await fetchHTML(query)
        } catch {
            return "Web search failed: \(error.localizedDescription)"
        }
        let results = Self.parse(html: html)
        guard !results.isEmpty else { return "No web results found for \"\(query)\"." }
        // Explicit String typing: GRDB's `SQL` type is visible module-wide and
        // conforms to ExpressibleByStringInterpolation, so an unannotated literal
        // here resolves to SQL instead of String.
        let body: String = results.prefix(6).enumerated().map { (index, result) -> String in
            let snippet: String = result.snippet.isEmpty ? "" : "\n   \(result.snippet)"
            return "\(index + 1). \(result.title)\n   \(result.url)\(snippet)"
        }.joined(separator: "\n")
        return AIToolHelpers.truncate(body)
    }

    // MARK: Networking

    /// POST the query to DuckDuckGo's HTML endpoint and return the raw HTML.
    static func duckDuckGoHTML(_ query: String) async throws -> String {
        guard let url = URL(string: "https://html.duckduckgo.com/html/") else {
            throw AIError.badURL("https://html.duckduckgo.com/html/")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        // DDG rejects an empty User-Agent; a browser UA returns full markup.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        request.httpBody = "q=\(encoded)".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIError.http(http.statusCode, "DuckDuckGo returned status \(http.statusCode)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Parsing (pure, unit-tested)

    struct WebResult: Equatable {
        let title: String
        let url: String
        let snippet: String
    }

    static func parse(html: String) -> [WebResult] {
        let titlePattern = "<a[^>]+class=\"result__a\"[^>]+href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>"
        let snippetPattern = "class=\"result__snippet\"[^>]*>([\\s\\S]*?)</a>"
        let titleMatches = regexMatches(titlePattern, in: html)
        let snippetMatches = regexMatches(snippetPattern, in: html)
        var out: [WebResult] = []
        for (index, match) in titleMatches.enumerated() where match.count >= 3 {
            let title = clean(match[2])
            guard !title.isEmpty else { continue }
            let url = decodeRedirect(match[1])
            let snippet = (index < snippetMatches.count && snippetMatches[index].count >= 2)
                ? clean(snippetMatches[index][1]) : ""
            out.append(WebResult(title: title, url: url, snippet: snippet))
        }
        return out
    }

    /// Return one array of capture-group strings per match (index 0 is the full
    /// match); a non-participating group yields "".
    private static func regexMatches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, options: [], range: full).map { match in
            (0..<match.numberOfRanges).map { groupIndex in
                let groupRange = match.range(at: groupIndex)
                return groupRange.location == NSNotFound ? "" : nsText.substring(with: groupRange)
            }
        }
    }

    /// Strip HTML tags, decode the handful of entities DDG emits, collapse runs
    /// of whitespace.
    private static func clean(_ raw: String) -> String {
        var stripped = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&#x27;": "'", "&#39;": "'", "&quot;": "\"",
                        "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, replacement) in entities { stripped = stripped.replacingOccurrences(of: entity, with: replacement) }
        return stripped.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// DDG wraps external links as `//duckduckgo.com/l/?uddg=<encoded>&rut=...`.
    /// Pull the real destination back out; pass through already-direct links.
    private static func decodeRedirect(_ href: String) -> String {
        var target = href.replacingOccurrences(of: "&amp;", with: "&")
        if target.hasPrefix("//") { target = "https:" + target }
        guard target.contains("uddg="),
              let comps = URLComponents(string: target),
              let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value else {
            return target
        }
        return uddg
    }
}
