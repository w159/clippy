import Foundation

/// What the Test connection button shows. Mirrors AITransport's `AIConnectionResult`.
struct AIConnectionOutcome: Equatable, Sendable {
    var ok: Bool
    var summary: String
    var detail: String?
    var latency: TimeInterval?
    var requestURLDisplay: String
}

enum AIConnectionRunner {
    static func run(_ resolved: ResolvedProvider) async -> AIConnectionOutcome {
        let result = await AIConnectionTester.test(resolved)
        return AIConnectionOutcome(ok: result.ok, summary: result.summary, detail: result.detail,
                                   latency: result.latency, requestURLDisplay: result.requestURLDisplay)
    }
}
