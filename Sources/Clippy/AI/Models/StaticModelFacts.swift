import Foundation

// Bundled facts, as of 2026-09-30. Exact ids only, never aliases inferred from a name.
// Sources (linked by docs/ai/providers-core.md):
// https://developers.openai.com/api/docs/models/gpt-4o-mini
// https://developers.openai.com/api/docs/pricing
// GPT-4o mini: 128,000 context; 16,384 output; $0.15 input / $0.60 output per 1M.
enum StaticModelFacts {
    static let date = "2026-09-30"
    static let sourceLabel = "bundled table, as of \(date)"

    static func lookup(providerID: String, modelID: String) -> ModelInfo? {
        guard providerID == "openai", modelID == "gpt-4o-mini" || modelID == "gpt-4o-mini-2024-07-18" else { return nil }
        return ModelInfo(id: modelID, contextLength: 128_000, maxOutput: 16_384,
                         promptPricePerM: 0.15, completionPricePerM: 0.60,
                         inputModalities: ["text", "image"], outputModalities: ["text"],
                         supportsTools: true, supportsReasoning: false, supportsVision: true,
                         source: sourceLabel)
    }

    static func enrich(_ model: ModelInfo, providerID: String) -> ModelInfo {
        guard let facts = lookup(providerID: providerID, modelID: model.id) else { return model }
        var result = model
        result.contextLength = result.contextLength ?? facts.contextLength
        result.maxOutput = result.maxOutput ?? facts.maxOutput
        result.promptPricePerM = result.promptPricePerM ?? facts.promptPricePerM
        result.completionPricePerM = result.completionPricePerM ?? facts.completionPricePerM
        if result.inputModalities.isEmpty { result.inputModalities = facts.inputModalities }
        if result.outputModalities.isEmpty { result.outputModalities = facts.outputModalities }
        result.supportsTools = result.supportsTools ?? facts.supportsTools
        result.supportsReasoning = result.supportsReasoning ?? facts.supportsReasoning
        result.supportsVision = result.supportsVision ?? facts.supportsVision
        result.source += "; \(sourceLabel)"
        return result
    }
}
