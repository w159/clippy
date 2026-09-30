import Foundation

/// One row of the model browser. Every metadata field is optional: `nil` means the
/// provider did not say, never "zero". Prices are USD per million tokens.
struct ModelInfo: Identifiable, Sendable, Hashable {
    var id: String
    var displayName: String
    var contextLength: Int?
    var maxOutput: Int?
    var promptPricePerM: Double?
    var completionPricePerM: Double?
    var inputModalities: [String] = []
    var outputModalities: [String] = []
    var supportsTools: Bool?
    var supportsReasoning: Bool?
    var supportsVision: Bool?
    var sizeBytes: Int64?
    var parameterSize: String?
    var quantization: String?
    var created: Date?
    /// Measured locally by `ModelLatencyProbe`, or published by the provider (OpenRouter
    /// endpoint stats). See `source` for which.
    var ttftMs: Double?
    var tokensPerSec: Double?
    /// Which API field set filled this row, e.g. "GET /api/tags + /api/show".
    var source: String
    var isLoaded: Bool?

    init(
        id: String, displayName: String? = nil, contextLength: Int? = nil, maxOutput: Int? = nil,
        promptPricePerM: Double? = nil, completionPricePerM: Double? = nil,
        inputModalities: [String] = [], outputModalities: [String] = [],
        supportsTools: Bool? = nil, supportsReasoning: Bool? = nil, supportsVision: Bool? = nil,
        sizeBytes: Int64? = nil, parameterSize: String? = nil, quantization: String? = nil,
        created: Date? = nil, ttftMs: Double? = nil, tokensPerSec: Double? = nil,
        source: String, isLoaded: Bool? = nil
    ) {
        self.id = id
        self.displayName = (displayName?.isEmpty == false) ? displayName! : id
        self.contextLength = contextLength
        self.maxOutput = maxOutput
        self.promptPricePerM = promptPricePerM
        self.completionPricePerM = completionPricePerM
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.supportsTools = supportsTools
        self.supportsReasoning = supportsReasoning
        self.supportsVision = supportsVision
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.created = created
        self.ttftMs = ttftMs
        self.tokensPerSec = tokensPerSec
        self.source = source
        self.isLoaded = isLoaded
    }

    /// Both prices known and zero. Unknown is not free.
    var isFree: Bool { promptPricePerM == 0 && completionPricePerM == 0 }
}

struct ModelLatencyResult: Sendable, Equatable {
    var ttftMs: Double?
    var tokensPerSec: Double?
    var error: String?
    var measuredAt: Date
}
