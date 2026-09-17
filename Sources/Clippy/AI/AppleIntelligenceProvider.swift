import Foundation
import FoundationModels

/// Apple Intelligence, on device, via the Foundation Models framework.
///
/// Why it matters more than "one more provider": every other backend ships the
/// user's clipboard contents to a third party over the network. At a firm where
/// the clipboard routinely holds client data, that is the reason to leave AI
/// switched off. This one never leaves the Mac, needs no API key, and costs
/// nothing per call, which is what makes the always-on features (auto-titling on
/// capture) defensible at all.
///
/// Availability is a runtime fact, not a compile-time one: the framework exists
/// on every macOS 26+ system, but the model is only usable when the device is
/// eligible, Apple Intelligence is enabled, and the assets have finished
/// downloading. `AppleIntelligence.availability` is the single place that is
/// checked, and Settings surfaces the reason when it is not `.available`.
enum AppleIntelligence {
    enum Availability: Equatable {
        case available
        /// Not usable right now, with a sentence the user can act on.
        case unavailable(String)

        var isAvailable: Bool { self == .available }

        /// Nil when available; otherwise the reason, for display.
        var reason: String? {
            if case .unavailable(let why) = self { return why }
            return nil
        }
    }

    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac does not support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still downloading its model. Try again once it finishes.")
        case .unavailable:
            return .unavailable("Apple Intelligence is unavailable on this Mac right now.")
        @unknown default:
            return .unavailable("Apple Intelligence is unavailable on this Mac right now.")
        }
    }
}

/// Bridges Foundation Models onto Clippy's provider protocols.
///
/// Tool calling is deliberately not implemented. Foundation Models expects tools
/// declared at compile time as `@Generable` argument types, while Clippy's
/// `AITool` carries a JSON schema decided at runtime; there is no honest mapping
/// between the two without rewriting the tool layer. Rather than pretend, the
/// agentic entry points return the model's plain text answer and log that tools
/// were skipped. Chat, AI actions, and auto-titling all work; the assistant
/// simply cannot call Clippy's tools while this provider is selected.
struct AppleIntelligenceProvider: AIAgentProvider {

    // MARK: - Session construction

    /// Foundation Models takes the system prompt as session instructions and the
    /// conversation as a single prompt, rather than a role-tagged message array.
    /// Splitting here keeps that shape in one place.
    private func makeSession(for messages: [AIMessage]) throws -> (LanguageModelSession, String) {
        if case .unavailable(let why) = AppleIntelligence.availability {
            throw AIError.notConfigured(why)
        }
        let instructions = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }
        guard !turns.isEmpty else { throw AIError.empty }

        let session = instructions.isEmpty
            ? LanguageModelSession()
            : LanguageModelSession(instructions: instructions)
        return (session, Self.flatten(turns))
    }

    /// A single prompt string from the conversation so far. Multi-turn history is
    /// labelled rather than dropped: without the labels the model cannot tell its
    /// own previous answers from the user's messages.
    static func flatten(_ turns: [AIMessage]) -> String {
        guard turns.count > 1 else { return turns.first?.content ?? "" }
        return turns
            .map { message in
                switch message.role {
                case .assistant: return "Assistant: \(message.content)"
                case .user, .system: return "User: \(message.content)"
                }
            }
            .joined(separator: "\n\n")
    }

    private func generationOptions(_ options: AICompletionOptions) -> GenerationOptions {
        GenerationOptions(
            temperature: options.temperature,
            maximumResponseTokens: options.maxTokens
        )
    }

    // MARK: - AIProvider

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let (session, prompt) = try makeSession(for: messages)
        do {
            let response = try await session.respond(to: prompt, options: generationOptions(options))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AIError.empty }
            return text
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.decoding(error.localizedDescription)
        }
    }

    // MARK: - AIAgentProvider

    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn {
        Self.logSkippedTools(tools)
        return .text(try await complete(messages, options: options))
    }

    func streamWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        Self.logSkippedTools(tools)
        return AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let (session, prompt) = try makeSession(for: messages)
                    // streamResponse yields cumulative snapshots, not deltas, so
                    // emit only the newly appended suffix to match what every
                    // other provider sends and what the UI appends.
                    var emitted = ""
                    for try await partial in session.streamResponse(
                        to: prompt, options: generationOptions(options)
                    ) {
                        let snapshot = partial.content
                        guard snapshot.count > emitted.count,
                              snapshot.hasPrefix(emitted) else {
                            // A non-monotonic snapshot means the model revised
                            // earlier text; resend the whole thing rather than
                            // emitting a nonsensical diff.
                            if snapshot != emitted {
                                continuation.yield(.textDelta(snapshot))
                                emitted = snapshot
                            }
                            continue
                        }
                        continuation.yield(.textDelta(String(snapshot.dropFirst(emitted.count))))
                        emitted = snapshot
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func logSkippedTools(_ tools: [AITool]) {
        guard !tools.isEmpty else { return }
        ClippyLog.info(
            "Apple Intelligence provider ignoring \(tools.count) tool(s): Foundation Models requires compile-time tool types",
            category: ClippyLog.ai
        )
    }
}
