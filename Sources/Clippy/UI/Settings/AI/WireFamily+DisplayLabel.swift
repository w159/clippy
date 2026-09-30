import Foundation

extension WireFamily {
    /// Human label for badges and lists; never show the raw enum name.
    var displayLabel: String {
        switch self {
        case .openaiChat: "OpenAI-compatible"
        case .anthropicMessages: "Anthropic API"
        case .ollamaChat: "Ollama API"
        case .azureDeployments, .azureV1: "Azure OpenAI"
        case .geminiNative: "Gemini API"
        case .appleFoundation: "On device"
        }
    }
}

extension ProviderDescriptor {
    /// `notes` for display: sentences carrying an internal research marker (`[UNVERIFIED]`)
    /// are dropped entirely, so an unconfirmed claim never reads as fact.
    var userFacingNotes: String? {
        guard let notes else { return nil }
        let marker = "[UNVERIFIED]"
        var kept: [Substring] = []
        for part in notes.split(separator: ". ", omittingEmptySubsequences: true) where !part.contains(marker) {
            kept.append(part)
        }
        var text = kept.joined(separator: ". ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.hasSuffix(".") { text += "." }
        return text.isEmpty ? nil : text
    }
}
