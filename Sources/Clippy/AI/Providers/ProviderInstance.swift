import Foundation

/// One extra request header. Secret values live in the Keychain under
/// `ai.instance.<UUID>.header.<id>`; the persisted JSON always carries an empty `value`
/// for them.
struct HeaderEntry: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var value: String
    var isSecret: Bool

    init(id: UUID = UUID(), name: String = "", value: String = "", isSecret: Bool = false) {
        self.id = id
        self.name = name
        self.value = value
        self.isSecret = isSecret
    }

    private enum CodingKeys: String, CodingKey { case id, name, value, isSecret }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try box.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try box.decodeIfPresent(String.self, forKey: .value) ?? ""
        isSecret = try box.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(name, forKey: .name)
        // A secret must never reach UserDefaults, whatever the caller left in `value`.
        try box.encode(isSecret ? "" : value, forKey: .value)
        try box.encode(isSecret, forKey: .isSecret)
    }
}

/// nil = provider/model default. Action-specific defaults come from callers.
struct GenerationParams: Codable, Sendable, Equatable {
    var temperature: Double?
    var maxTokens: Int?
    var topP: Double?
    var reasoningEffort: String?
    var thinkOllama: Bool?

    init(temperature: Double? = nil, maxTokens: Int? = nil, topP: Double? = nil,
         reasoningEffort: String? = nil, thinkOllama: Bool? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.reasoningEffort = reasoningEffort
        self.thinkOllama = thinkOllama
    }
}

/// A user-configured provider. Empty string fields mean "use the descriptor default".
struct ProviderInstance: Codable, Identifiable, Sendable, Equatable {
    static let defaultFirstTokenTimeout: TimeInterval = 0
    static let defaultIdleTimeout: TimeInterval = 60
    static let defaultRequestTimeout: TimeInterval = 300

    var id: UUID
    var descriptorID: String
    var name: String
    var baseURL: String
    var model: String
    var apiVersion: String
    var organization: String
    var project: String
    var deployment: String
    var region: String
    var headers: [HeaderEntry]
    /// JSON object merged into every request body last.
    var extraBodyJSON: String
    var params: GenerationParams
    var firstTokenTimeout: TimeInterval
    var idleTimeout: TimeInterval
    var requestTimeout: TimeInterval

    init(
        id: UUID = UUID(), descriptorID: String, name: String, baseURL: String = "",
        model: String = "", apiVersion: String = "", organization: String = "",
        project: String = "", deployment: String = "", region: String = "",
        headers: [HeaderEntry] = [], extraBodyJSON: String = "",
        params: GenerationParams = GenerationParams(),
        firstTokenTimeout: TimeInterval = ProviderInstance.defaultFirstTokenTimeout,
        idleTimeout: TimeInterval = ProviderInstance.defaultIdleTimeout,
        requestTimeout: TimeInterval = ProviderInstance.defaultRequestTimeout
    ) {
        self.id = id
        self.descriptorID = descriptorID
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiVersion = apiVersion
        self.organization = organization
        self.project = project
        self.deployment = deployment
        self.region = region
        self.headers = headers
        self.extraBodyJSON = extraBodyJSON
        self.params = params
        self.firstTokenTimeout = firstTokenTimeout
        self.idleTimeout = idleTimeout
        self.requestTimeout = requestTimeout
    }

    /// Keychain account for the API key.
    static func keyAccount(_ id: UUID) -> String { "ai.instance.\(id.uuidString).apiKey" }
    /// Keychain account for a secret header value.
    static func headerAccount(instance: UUID, header: UUID) -> String {
        "ai.instance.\(instance.uuidString).header.\(header.uuidString)"
    }
}
