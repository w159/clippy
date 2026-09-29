import Foundation
import NaturalLanguage

/// `NLContextualEmbedding` (macOS 14+) embedder: mean-pooled token vectors.
/// Assets are NEVER requested implicitly; `hasAvailableAssets` gates every use
/// and `requestAssets` runs only from an explicit user action.
///
/// `@unchecked Sendable`: `model` and `loaded` are only touched under `lock`; the rest is immutable.
final class NLContextualTextEmbedder: TextEmbedder, SemanticAssetProbe, @unchecked Sendable {
    private let language: NLLanguage
    private let lock = NSLock()
    private var model: NLContextualEmbedding?
    private var loaded = false
    private let maxChars = 1000

    init(language: NLLanguage = .english) { self.language = language }

    /// True when the model assets are already on disk.
    var hasAvailableAssets: Bool { NLContextualEmbedding(language: language)?.hasAvailableAssets ?? false }

    /// Embedding revision; changes invalidate persisted vectors.
    var revision: Int { Int(NLContextualEmbedding(language: language)?.revision ?? 0) &+ 1000 }

    /// Asks the OS to download assets. Call ONLY from an explicit user action.
    func requestAssets() async -> Bool {
        guard let embedding = NLContextualEmbedding(language: language) else { return false }
        if embedding.hasAvailableAssets { return true }
        return await withCheckedContinuation { continuation in
            embedding.requestAssets { result, _ in continuation.resume(returning: result == .available) }
        }
    }

    func vector(for text: String) -> [Float]? {
        let trimmed = String(text.prefix(maxChars))
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasAvailableAssets else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let embedding = loadedModel(),
            let result = try? embedding.embeddingResult(for: trimmed, language: language)
        else { return nil }
        var rows: [[Float]] = []
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            rows.append(vector.map { Float($0) })
            return true
        }
        return VectorMath.mean(rows)
    }

    func embedding(for text: String) -> LanguageVector? {
        vector(for: text).map { LanguageVector(vector: $0, language: language.rawValue) }
    }

    /// Caller holds `lock`.
    private func loadedModel() -> NLContextualEmbedding? {
        if loaded { return model }
        loaded = true
        guard let candidate = NLContextualEmbedding(language: language), (try? candidate.load()) != nil else { return nil }
        model = candidate
        return candidate
    }
}
