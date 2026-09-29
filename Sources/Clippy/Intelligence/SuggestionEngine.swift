import Accelerate
import Foundation
import NaturalLanguage

// MARK: - Engine

/// Ranks clipboard history against the user's current screen context (or
/// against another clip) using a hybrid of embedding similarity, keyword
/// overlap, recency, source-app affinity, and kind fit. All on-device.
///
/// `@unchecked Sendable`: the collaborators are immutable references that are
/// thread-safe by contract (`EmbeddingCache`, `SuggestionDismissals` and
/// `NLTextEmbedder` each serialize internally); the engine's own mutable state
/// (`ignoredBundleIDsStorage`, `warming`) is only touched under `lock`.
final class SuggestionEngine: @unchecked Sendable {
    static let shared: SuggestionEngine = {
        let embedder = NLTextEmbedder()
        return SuggestionEngine(
            embedder: embedder,
            cache: EmbeddingCache(fileURL: EmbeddingCache.defaultFileURL, revision: embedder.revision),
            dismissals: .shared, secondStage: FoundationModelsSecondStage())
    }()

    /// Hybrid weights; sum to 1.
    private enum Weight {
        static let embedding = 0.55
        static let keyword = 0.15
        static let recency = 0.12
        static let app = 0.10
        static let kind = 0.08
    }

    private let embedder: TextEmbedder
    private let cache: EmbeddingCache
    /// Feedback store consulted inside `rank`/`related` (INT-07).
    let dismissals: SuggestionDismissals
    private let secondStage: SuggestionSecondStage?
    private let isSecondStageEnabled: () -> Bool

    /// Clips captured from these apps are never suggested. Set by the store
    /// from the user's ignored-apps setting.
    var ignoredBundleIDs: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return ignoredBundleIDsStorage }
        set { lock.lock(); ignoredBundleIDsStorage = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var ignoredBundleIDsStorage: Set<String> = []
    private var warming = false

    /// Defaults are in-memory and side-effect free (no disk, no Foundation Models),
    /// so tests never touch real user data; `shared` wires the persistent pieces.
    init(
        embedder: TextEmbedder = NLTextEmbedder(),
        cache: EmbeddingCache? = nil,
        dismissals: SuggestionDismissals = SuggestionDismissals(fileURL: nil),
        secondStage: SuggestionSecondStage? = nil,
        isSecondStageEnabled: @escaping () -> Bool = { SuggestionTuning.useFoundationModels }
    ) {
        self.embedder = embedder
        self.cache = cache ?? EmbeddingCache(fileURL: nil, revision: embedder.revision)
        self.dismissals = dismissals
        self.secondStage = secondStage
        self.isSecondStageEnabled = isSecondStageEnabled
    }

    // MARK: Public API

    /// Pure ranking core (synchronous, testable): rank `clips` against `context`.
    func rank(context: ScreenContext, clips: [Clip], limit: Int, now: Date) -> [Suggestion] {
        let feedback = dismissals.snapshot(now: now)
        if let bundle = context.bundleID, feedback.excludedApps.contains(bundle) { return [] }
        let refine = secondStage != nil && isSecondStageEnabled()
        let query = Query(
            text: context.queryText,
            excludedText: Self.normalized(context.text),
            bundleID: context.bundleID,
            writingContext: Self.looksLikeWriting(context),
            excludedClipID: nil,
            embeddingReason: context.text.isEmpty
                ? "Related to this window" : "Similar to what you're writing")
        let base = score(
            query: query, clips: clips,
            limit: refine ? max(limit, SuggestionTuning.secondStageCandidates) : limit,
            now: now, feedback: feedback)
        guard refine, let secondStage else { return base }
        let summary = [context.appName, context.windowTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        return Array(
            SecondStageRunner.apply(to: base, contextSummary: summary, stage: secondStage).prefix(limit))
    }

    /// "Find Similar": rank `clips` by relatedness to one clip, excluding it.
    func related(to clip: Clip, clips: [Clip], limit: Int, now: Date) -> [Suggestion] {
        let text = Self.embedText(for: clip)
        guard !text.isEmpty else { return [] }
        let query = Query(
            text: text,
            excludedText: Self.normalized(clip.contentText),
            bundleID: clip.sourceAppBundleID,
            writingContext: false,
            excludedClipID: clip.id,
            embeddingReason: "Similar content")
        return score(
            query: query, clips: clips, limit: limit, now: now,
            feedback: dismissals.snapshot(now: now))
    }

    /// Computes/caches vectors for recent text clips off-main. Idempotent;
    /// concurrent calls collapse into the one already running.
    func warmUp(clips: [Clip]) {
        lock.lock()
        if warming { lock.unlock(); return }
        warming = true
        lock.unlock()
        let batch = Array(clips.prefix(SuggestionTuning.cacheCapacity))
        DispatchQueue.global(qos: .utility).async { [self] in
            for clip in batch { _ = embedding(for: clip) }
            cache.flush()
            lock.lock()
            warming = false
            lock.unlock()
        }
    }

    /// Drops every cached vector, including the persisted file.
    func clearCache() {
        cache.clear()
    }

    // MARK: Scoring

    private struct Query {
        var text: String
        var excludedText: String
        var bundleID: String?
        var writingContext: Bool
        var excludedClipID: Int64?
        var embeddingReason: String
    }

    private struct Candidate {
        var clip: Clip
        var embedding: LanguageVector?
        /// True when a same-language cosine was computed for this candidate.
        var compared = false
        var demoted = false
        var cosine: Double = 0
        var sharedWords: [String] = []
        var keyword: Double = 0
    }

    private func score(
        query: Query, clips: [Clip], limit: Int, now: Date, feedback: DismissalSnapshot
    ) -> [Suggestion] {
        guard limit > 0 else { return [] }
        let ignored = ignoredBundleIDs
        let queryWords = Self.words(query.text)
        let queryWordSet = Set(queryWords)
        let queryEmbedding: LanguageVector? = query.text.isEmpty ? nil : embedder.embedding(for: query.text)

        // Filter + de-duplicate (newest wins).
        var seen = Set<String>()
        var candidates: [Candidate] = []
        for clip in clips.sorted(by: { $0.createdAt > $1.createdAt }) {
            if let id = clip.id, id == query.excludedClipID { continue }
            if let bundle = clip.sourceAppBundleID, ignored.contains(bundle) { continue }
            guard let key = Self.contentKey(clip) else { continue }
            let text = Self.normalized(clip.contentText)
            if !text.isEmpty, text == query.excludedText { continue }
            var demoted = false
            if !feedback.isEmpty {
                let feedbackKey = clip.contentKey
                if feedback.neverKeys.contains(feedbackKey) { continue }
                demoted = feedback.demotedKeys.contains(feedbackKey)
            }
            guard seen.insert(key).inserted else { continue }
            var candidate = Candidate(clip: clip, embedding: nil, demoted: demoted)
            let embedded = Self.embedText(for: clip)
            if !embedded.isEmpty {
                if queryEmbedding != nil { candidate.embedding = embedding(for: clip) }
                let clipWords = Self.words(embedded)
                var ordered: [String] = []
                var unique = Set<String>()
                for word in clipWords where unique.insert(word).inserted { ordered.append(word) }
                candidate.sharedWords = ordered.filter { queryWordSet.contains($0) }
                candidate.keyword = min(
                    1, Double(candidate.sharedWords.count) / Double(min(max(ordered.count, 1), 4)))
            }
            candidates.append(candidate)
        }

        // Cosine similarity, scaled ABSOLUTELY (min-max normalizing stretched the
        // least-unrelated clip up to look relevant). Only vectors from the SAME
        // language space are compared; anything else ranks on keyword, recency,
        // and app signals. Floor/span live in `SuggestionTuning` with the
        // calibration procedure.
        if let queryEmbedding {
            for index in candidates.indices {
                guard let candidateEmbedding = candidates[index].embedding,
                    candidateEmbedding.language == queryEmbedding.language,
                    candidateEmbedding.vector.count == queryEmbedding.vector.count
                else { continue }
                candidates[index].cosine = Self.cosine(queryEmbedding.vector, candidateEmbedding.vector)
                candidates[index].compared = true
            }
        }

        var results: [Suggestion] = []
        for candidate in candidates {
            let embedNorm =
                !candidate.compared
                ? 0.0
                : min(
                    1,
                    max(
                        0,
                        (candidate.cosine - SuggestionTuning.embeddingFloor)
                            / SuggestionTuning.embeddingSpan))
            let age = max(0, now.timeIntervalSince(candidate.clip.createdAt))
            let recency = pow(0.5, age / SuggestionTuning.recencyHalfLife)
            let app: Double =
                (query.bundleID != nil && candidate.clip.sourceAppBundleID == query.bundleID) ? 1 : 0
            let kind = Self.kindFit(candidate.clip, writing: query.writingContext)

            let parts: [(Double, Factor)] = [
                (Weight.embedding * embedNorm, .embedding),
                (Weight.keyword * candidate.keyword, .keyword),
                (Weight.recency * recency, .recency),
                (Weight.app * app, .app),
                (Weight.kind * kind, .kind),
            ]
            var total = min(1, max(0, parts.reduce(0) { $0 + $1.0 }))
            if candidate.demoted { total *= SuggestionTuning.notRelevantWeight }
            guard total >= SuggestionTuning.minScore else { continue }
            // Reason = the most meaningful signal that actually applies, in
            // priority order. Recency is a background signal every clip has, so
            // it only explains a suggestion when nothing else does (picking the
            // largest weighted term would label almost everything "Recently
            // copied").
            let dominant: Factor
            if embedNorm >= 0.3 {
                dominant = .embedding
            } else if !candidate.sharedWords.isEmpty {
                dominant = .keyword
            } else if app == 1 {
                dominant = .app
            } else if query.writingContext, kind == 1 {
                dominant = .kind
            } else {
                dominant = .recency
            }
            let reason = Self.reason(dominant, candidate: candidate, query: query)
            results.append(
                Suggestion(
                    clip: candidate.clip, score: total, reason: reason,
                    embeddingLanguage: candidate.compared ? queryEmbedding?.language : nil))
        }
        results.sort {
            $0.score != $1.score ? $0.score > $1.score : $0.clip.createdAt > $1.clip.createdAt
        }
        return Array(results.prefix(limit))
    }

    private enum Factor { case embedding, keyword, recency, app, kind }

    private static func reason(_ factor: Factor, candidate: Candidate, query: Query) -> String {
        switch factor {
        case .embedding:
            return query.embeddingReason
        case .keyword:
            // Only words present in the clip itself, at most 3.
            let shared = candidate.sharedWords.prefix(3)
            return shared.isEmpty ? query.embeddingReason : "Shares words: " + shared.joined(separator: ", ")
        case .recency:
            switch candidate.clip.kind {
            case .link: return "Recent link"
            case .image: return "Recent image"
            default: return "Recently copied"
            }
        case .app:
            return "Copied from " + (candidate.clip.sourceAppName ?? "the same app")
        case .kind:
            return candidate.clip.kind == .link ? "Link for this message" : "Image for this message"
        }
    }

    // MARK: Signals

    private static func kindFit(_ clip: Clip, writing: Bool) -> Double {
        let media = clip.isImageLike || clip.kind == .link
        if writing { return media ? 1 : 0.5 }
        return 0.4
    }

    private static let writingApps = [
        "mail", "messages", "slack", "discord", "telegram", "whatsapp", "outlook", "notes",
        "pages", "word", "teams", "signal", "textedit", "notion", "obsidian", "bear",
    ]

    private static func looksLikeWriting(_ context: ScreenContext) -> Bool {
        if let bundle = context.bundleID?.lowercased(), writingApps.contains(where: bundle.contains) {
            return true
        }
        let title = context.windowTitle?.lowercased() ?? ""
        return ["compose", "reply", "re:", "draft", "new message"].contains(where: title.contains)
    }

    // MARK: Text helpers

    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "her", "was",
        "one", "our", "out", "has", "have", "with", "this", "that", "from", "they", "will",
        "what", "when", "your", "about", "there", "their", "would", "been", "were",
    ]

    /// Lowercased alphanumeric tokens of length >= 3, minus stopwords.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Text embedded and keyword-matched for a clip (INT-05): the body, OCR text
    /// (unless it looks sensitive), and a file clip's file name, capped to
    /// `SuggestionTuning.clipEmbedChars`. A user title is prepended only when
    /// there is other text. Empty for clips with no text at all.
    static func embedText(for clip: Clip) -> String {
        var pieces: [String] = []
        let body = clip.contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { pieces.append(body) }
        if let ocr = clip.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty,
            !SensitiveContent.isSensitive(text: ocr)
        {
            pieces.append(ocr)
        }
        if clip.contentKind == .file, let name = fileName(clip) { pieces.append(name) }
        guard !pieces.isEmpty else { return "" }
        let text = String(pieces.joined(separator: "\n").prefix(SuggestionTuning.clipEmbedChars))
        guard let title = clip.userTitle, !title.isEmpty else { return text }
        return title + "\n" + text
    }

    /// Words of a file clip's name with separators opened up ("Q3_report-final.pdf" -> "Q3 report final pdf").
    private static func fileName(_ clip: Clip) -> String? {
        guard let path = clip.filePath, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
            .map { "_-.+".contains($0) ? " " : $0 }
        let flat = String(name).trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : flat
    }

    /// Identity used for de-duplication; nil marks a clip with nothing to suggest.
    private static func contentKey(_ clip: Clip) -> String? {
        let text = normalized(clip.contentText)
        if !text.isEmpty { return "t:" + text }
        switch clip.contentKind {
        case .text: return nil
        case .image: return clip.mediaFilename.map { "m:" + $0 }
        case .file: return (clip.filePath ?? clip.mediaFilename).map { "f:" + $0 }
        }
    }

    // MARK: Vectors + cache

    /// Cached embedding for a text clip; computes and stores on a miss. The
    /// cache key is the clip id validated by a stable text hash.
    private func embedding(for clip: Clip) -> LanguageVector? {
        let text = Self.embedText(for: clip)
        guard !text.isEmpty else { return nil }
        guard let id = clip.id else { return embedder.embedding(for: text) }
        let hash = StableHash.fnv1a(text)
        if let hit = cache.lookup(id: id, textHash: hash) { return hit }
        guard let computed = embedder.embedding(for: text) else { return nil }
        cache.store(id: id, textHash: hash, value: computed)
        return computed
    }

    /// Cosine similarity via Accelerate; 0 for mismatched or zero vectors.
    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let length = vDSP_Length(lhs.count)
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &dot, length)
        vDSP_svesq(lhs, 1, &normA, length)
        vDSP_svesq(rhs, 1, &normB, length)
        let denom = (normA * normB).squareRoot()
        return denom > 0 ? Double(dot / denom) : 0
    }
}
