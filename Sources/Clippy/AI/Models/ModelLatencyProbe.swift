import Foundation

enum ModelLatencyProbe {
    /// Explicit user action only: this sends a small inference request (may incur cost).
    /// Throughput is unknown when the provider does not report actual completion tokens.
    static func measure(_ resolved: ResolvedProvider, model: String) async -> ModelLatencyResult {
        var instance = resolved.instance
        instance.model = model
        if resolved.descriptor.fields.contains(.deployment) { instance.deployment = model }
        let target = ResolvedProvider(descriptor: resolved.descriptor, instance: instance,
                                      apiKey: resolved.apiKey, secretHeaders: resolved.secretHeaders)
        let start = Date()
        var first: Date?
        var last: Date?
        var tokens: Int?
        do {
            let provider = AIProviderRuntime.make(target)
            for try await event in provider.stream(
                [AIMessage(role: .user, content: "Count from one to ten, no explanation.")],
                options: AICompletionOptions(temperature: nil, maxTokens: 512, purpose: .chat)) {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let text), .thinkingDelta(let text):
                    if !text.isEmpty {
                        if first == nil { first = Date() }
                        last = Date()
                    }
                case .usage(let usage): tokens = usage.completionTokens
                default: break
                }
            }
            let duration = first.flatMap { first in last.map { $0.timeIntervalSince(first) } }
            let rate: Double?
            if let tokens, tokens > 1, let duration, duration > 0 { rate = Double(tokens - 1) / duration }
            else { rate = nil }
            return ModelLatencyResult(ttftMs: first.map { $0.timeIntervalSince(start) * 1000 },
                                      tokensPerSec: rate, error: first == nil ? "The provider returned no tokens." : nil,
                                      measuredAt: Date())
        } catch {
            return ModelLatencyResult(ttftMs: nil, tokensPerSec: nil, error: error.localizedDescription, measuredAt: Date())
        }
    }
}
