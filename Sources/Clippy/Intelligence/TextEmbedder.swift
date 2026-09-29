import Foundation
import NaturalLanguage

/// A sentence vector tagged with the language space it lives in. Vectors from
/// different languages are never comparable, so callers must check `language`.
struct LanguageVector: Equatable {
    var vector: [Float]
    /// `NLLanguage.rawValue` of the embedding space, e.g. "en".
    var language: String
}

/// Turns text into a fixed-size vector so relevance can be compared by cosine
/// similarity. Injected so tests can use a deterministic stub.
protocol TextEmbedder {
    /// Vector only; language-agnostic callers and simple stubs implement this.
    func vector(for text: String) -> [Float]?
    /// Vector plus its language space. Defaults to a single shared space.
    func embedding(for text: String) -> LanguageVector?
    /// Identifies the embedding model revision; a change invalidates persisted vectors.
    var revision: Int { get }
}

extension TextEmbedder {
    func embedding(for text: String) -> LanguageVector? {
        vector(for: text).map { LanguageVector(vector: $0, language: "und") }
    }
    var revision: Int { 0 }
}

/// On-device sentence embedding via NaturalLanguage. No network, no model
/// download. The language is detected with `NLLanguageRecognizer`; when no
/// sentence embedding exists for it there is NO vector (never a wrong-language
/// fallback), so the engine ranks by keyword, recency, and app signals instead.
final class NLTextEmbedder: TextEmbedder {
    /// NLEmbedding is not documented as thread-safe; serialize all access.
    private let lock = NSLock()
    private var embeddings: [NLLanguage: NLEmbedding?] = [:]
    private let maxChars = 1000

    /// Languages whose sentence-model revision feeds `revision`.
    private static let revisionLanguages: [NLLanguage] = [
        .english, .spanish, .french, .german, .italian, .portuguese, .dutch, .russian,
        .simplifiedChinese, .traditionalChinese, .japanese, .korean, .turkish, .swedish, .polish,
    ]

    func vector(for text: String) -> [Float]? { embedding(for: text)?.vector }

    func embedding(for text: String) -> LanguageVector? {
        let trimmed = String(text.prefix(maxChars))
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let language = Self.dominantLanguage(of: trimmed)
        lock.lock()
        defer { lock.unlock() }
        guard let embedding = embedding(for: language),
            let vector = embedding.vector(for: trimmed)
        else { return nil }
        return LanguageVector(vector: vector.map { Float($0) }, language: language.rawValue)
    }

    /// Stable across launches; changes when any tracked sentence model is updated.
    var revision: Int { Self.currentRevision }

    private static let currentRevision: Int = {
        let signature = NLTextEmbedder.revisionLanguages
            .map { "\($0.rawValue):\(NLEmbedding.currentSentenceEmbeddingRevision(for: $0))" }
            .joined(separator: ",")
        return Int(StableHash.fnv1a(signature) & 0x7fff_ffff)
    }()

    /// True when this SDK ships a sentence embedding for `language`.
    static func hasSentenceEmbedding(for language: NLLanguage) -> Bool {
        NLEmbedding.sentenceEmbedding(for: language) != nil
    }

    private static func dominantLanguage(of text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? .english
    }

    /// Caller holds `lock`.
    private func embedding(for language: NLLanguage) -> NLEmbedding? {
        if let cached = embeddings[language] { return cached }
        let loaded = NLEmbedding.sentenceEmbedding(for: language)
        embeddings[language] = .some(loaded)
        return loaded
    }
}
