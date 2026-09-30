import Foundation

/// Pure rules behind the AI provider settings: what to show for a descriptor, how to
/// validate what the user typed, and what the privacy line says. No UI, no store.
enum AIProviderSettingsLogic {
    // MARK: - Add menu

    struct AddGroup: Equatable {
        let title: String
        let descriptors: [ProviderDescriptor]
    }

    /// Active descriptors grouped for the "+ Add provider" menu, in catalog group order.
    static func addGroups() -> [AddGroup] {
        let addable = ProviderCatalog.addable
        return ProviderCatalog.groupOrder.compactMap { group in
            let members = addable.filter { $0.group == group }
            return members.isEmpty ? nil : AddGroup(title: group, descriptors: members)
        }
    }

    /// Retired providers, listed only in a footnote.
    static var retiredProviderNames: [String] {
        ProviderCatalog.descriptors.filter { !$0.isActive }.map {
            $0.displayName.replacingOccurrences(of: " (retired)", with: "")
        }
    }

    // MARK: - Field visibility

    static func visibleFields(_ descriptor: ProviderDescriptor) -> [ProviderField] {
        descriptor.family == .appleFoundation ? [] : descriptor.fields
    }

    static func shows(_ field: ProviderField, for descriptor: ProviderDescriptor) -> Bool {
        visibleFields(descriptor).contains(field)
    }

    /// Advanced (headers, body, params, timeouts) makes no sense for the on-device model.
    static func supportsAdvanced(_ descriptor: ProviderDescriptor) -> Bool {
        descriptor.family != .appleFoundation
    }

    enum Param: CaseIterable {
        case temperature, maxTokens, topP, reasoningEffort, thinkOllama
    }

    static func supports(_ param: Param, for descriptor: ProviderDescriptor) -> Bool {
        switch param {
        case .temperature: return descriptor.sendsTemperature && supportsAdvanced(descriptor)
        case .maxTokens, .topP: return supportsAdvanced(descriptor)
        case .reasoningEffort:
            return [.openaiChat, .azureDeployments, .azureV1].contains(descriptor.family)
        case .thinkOllama: return descriptor.family == .ollamaChat
        }
    }

    static let reasoningEfforts = ["minimal", "low", "medium", "high"]
    static let temperatureRange: ClosedRange<Double> = 0...2
    static let topPRange: ClosedRange<Double> = 0...1
    static let maxTokensRange: ClosedRange<Int> = 1...1_000_000
    static let timeoutRange: ClosedRange<Double> = 1...3600

    /// The api-version a fresh Azure instance starts with (per-style default).
    static func defaultAPIVersion(_ descriptor: ProviderDescriptor) -> String {
        descriptor.queryParams["api-version"] ?? ""
    }

    // MARK: - Endpoint

    enum URLFeedback: Equatable {
        case none
        case warning(String)
        case error(String)

        var message: String? {
            switch self {
            case .none: return nil
            case .warning(let text), .error(let text): return text
            }
        }
    }

    /// Inline validation for the base URL field. Empty means "use the default", which is
    /// only an error when the descriptor has no usable default (Azure, custom servers).
    static func urlFeedback(raw: String, descriptor: ProviderDescriptor) -> URLFeedback {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if descriptor.defaultBaseURL.isEmpty {
                return .error("Enter the server address, for example http://localhost:8080.")
            }
            if descriptor.defaultBaseURL.contains("{") {
                return .error("Enter your resource endpoint, for example https://my-resource.openai.azure.com.")
            }
            return .none
        }
        switch URLNormalizer.normalize(trimmed, for: descriptor) {
        case .failure(.placeholder):
            return .error("Replace the placeholder (such as {resource}) with your real resource name.")
        case .failure(.notHTTP): return .error("Use an http:// or https:// address.")
        case .failure(.empty): return .none
        case .failure(.malformed): return .error("That does not look like a valid URL.")
        case .success(let url):
            if let tail = strippedTail(raw: trimmed, normalized: url) {
                return .warning("Clippy adds the request path itself, so \u{201C}\(tail)\u{201D} is ignored.")
            }
            if url.scheme?.lowercased() == "http", !HostLocality.isVerifiedLoopback(url) {
                return .warning("http:// is not encrypted. Your API key and text would cross the network in clear text.")
            }
            return .none
        }
    }

    /// The path suffix URLNormalizer dropped, if any (e.g. `/v1/chat/completions`).
    private static func strippedTail(raw: String, normalized: URL) -> String? {
        guard let comps = URLComponents(string: raw) else { return nil }
        var rawPath = comps.path
        while rawPath.hasSuffix("/") { rawPath.removeLast() }
        var kept = normalized.path
        while kept.hasSuffix("/") { kept.removeLast() }
        guard rawPath.count > kept.count, rawPath.hasPrefix(kept) else { return nil }
        return String(rawPath.dropFirst(kept.count))
    }

    /// "Requests go to: <url>" for the form footer.
    static func effectiveURLText(descriptor: ProviderDescriptor, instance: ProviderInstance) -> String {
        if descriptor.family == .appleFoundation { return "Runs on this Mac. No network request is made." }
        let draft = ResolvedProvider(descriptor: descriptor, instance: instance, apiKey: "", secretHeaders: [:])
        if let url = draft.url(for: .chat) { return "Requests go to: \(url.absoluteString)" }
        if draft.effectiveBaseURL == nil { return "Requests go to: \u{2014} (fix the URL above)" }
        return "Requests go to: \u{2014} (fill in the model or deployment)"
    }

    // MARK: - Headers

    private static let tokenChars = CharacterSet(charactersIn:
        "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let reservedHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "upgrade", "te", "trailer",
    ]

    /// One message per problematic row, keyed by `HeaderEntry.id`. Rows that are completely
    /// blank are not problems (they are dropped when sent).
    static func headerIssues(_ headers: [HeaderEntry], hasStoredSecret: (UUID) -> Bool = { _ in false }) -> [UUID: String] {
        var issues: [UUID: String] = [:]
        var seen = Set<String>()
        for header in headers {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let valueEmpty = header.value.isEmpty && !(header.isSecret && hasStoredSecret(header.id))
            if name.isEmpty {
                if !valueEmpty { issues[header.id] = "Enter a header name." }
                continue
            }
            let lower = name.lowercased()
            if name.unicodeScalars.contains(where: { !tokenChars.contains($0) }) {
                issues[header.id] = "Header names use letters, digits and - _ . only."
            } else if reservedHeaders.contains(lower) {
                issues[header.id] = "\(name) is set by the system and cannot be overridden."
            } else if !seen.insert(lower).inserted {
                issues[header.id] = "\(name) is listed twice."
            } else if valueEmpty {
                issues[header.id] = "Enter a value, or remove the row. Empty headers are not sent."
            } else if header.value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
                issues[header.id] = "Values cannot contain line breaks."
            }
        }
        return issues
    }

    /// Suggested headers not yet present (case-insensitive).
    static func unusedSuggestions(_ descriptor: ProviderDescriptor, headers: [HeaderEntry]) -> [HeaderHint] {
        let present = Set(headers.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() })
        return descriptor.suggestedHeaders.filter { !present.contains($0.name.lowercased()) }
    }

    /// Adds a suggested header row; no-op when the name is already present.
    static func adding(_ hint: HeaderHint, to headers: [HeaderEntry]) -> [HeaderEntry] {
        let name = hint.name.lowercased()
        if headers.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name }) {
            return headers
        }
        return headers + [HeaderEntry(name: hint.name)]
    }

    // MARK: - Extra body JSON

    /// nil when valid (or empty). Otherwise a one-line message, with line/column when the
    /// parser reports one.
    static func extraBodyIssue(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        do {
            let value = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
            return value is [String: Any] ? nil : "Must be a JSON object, for example {\"top_k\": 40}."
        } catch {
            let ns = error as NSError
            let debug = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ""
            if let range = debug.range(of: "line \\d+, column \\d+", options: .regularExpression) {
                return "Invalid JSON at \(debug[range])."
            }
            return "Invalid JSON."
        }
    }

    // MARK: - Privacy

    enum Privacy: Equatable {
        case noProvider
        case onDevice
        case loopback
        case remote(host: String)
    }

    static func privacy(active: ProviderInstance?) -> Privacy {
        guard let active, let descriptor = ProviderCatalog.descriptor(id: active.descriptorID) else { return .noProvider }
        let draft = ResolvedProvider(descriptor: descriptor, instance: active, apiKey: "", secretHeaders: [:])
        if descriptor.family == .appleFoundation { return .onDevice }
        if draft.isVerifiedLoopback { return .loopback }
        if ResolvedProvider.modelLeavesMac(draft.effectiveModel, descriptor: descriptor) {
            return .remote(host: "ollama.com (through your local Ollama)")
        }
        return .remote(host: draft.effectiveBaseURL?.host ?? "the configured server")
    }

    /// The paragraph under the master switch.
    static func privacyText(_ privacy: Privacy) -> String {
        switch privacy {
        case .noProvider:
            return "No provider is set up yet. Add one below."
        case .onDevice:
            return "Apple Intelligence runs on this Mac. Clipboard text stays on this device."
        case .loopback:
            return "This provider runs on this Mac (localhost). Clipboard text stays on this device."
        case .remote(let host):
            return "Clipboard text you send to AI (rewrites, actions, the assistant) is sent to \(host). "
                + "Automatic title suggestions are paused while this provider is active, because they would run on every copy."
        }
    }

    static func isRemote(_ privacy: Privacy) -> Bool {
        if case .remote = privacy { return true }
        return false
    }

    // MARK: - Managed preferences

    /// Which parts of the active instance a managed (MDM) preference locks. The store applies
    /// forced provider / base URL / model / API version at resolve time, so those fields are
    /// shown disabled on the instance that is (or would be) used.
    struct ForcedGate: Equatable {
        var providerLocked: Bool
        var baseURLLocked: Bool
        var modelLocked: Bool
        var apiVersionLocked: Bool

        init(isForced: (String) -> Bool = { AppSettings.isForced($0) }) {
            providerLocked = isForced(AppSettings.Keys.aiProvider)
            baseURLLocked = isForced(AppSettings.Keys.aiBaseURL)
            modelLocked = isForced(AppSettings.Keys.aiModel)
            apiVersionLocked = isForced(AppSettings.Keys.aiAzureAPIVersion)
        }

        /// Whether `field` is disabled. Only the active instance is affected.
        func locks(_ field: ProviderField, isActive: Bool) -> Bool {
            guard isActive else { return false }
            switch field {
            case .baseURL: return baseURLLocked
            case .model, .deployment: return modelLocked
            case .apiVersion: return apiVersionLocked
            default: return false
            }
        }

        var anyLocked: Bool { providerLocked || baseURLLocked || modelLocked || apiVersionLocked }
    }
}
