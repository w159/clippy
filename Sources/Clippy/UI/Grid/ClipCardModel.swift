import SwiftUI

/// Everything a card or row needs, precomputed as a plain value (LAY-12), so
/// views never reach into stores or settings singletons and never see masked
/// content in accessibility text.
struct ClipCardModel: Equatable {
    /// Database id, nil for unsaved clips.
    let clipID: Int64?
    /// Title shown in the header (user title, else source app).
    let title: String
    /// Source app name for the metadata row, if known.
    let sourceApp: String?
    /// Human kind label ("Link", "Image", ...).
    let kindLabel: String
    /// Selection state.
    let isSelected: Bool
    /// Pinned (member of any category).
    let isPinned: Bool
    /// Sensitive clips render masked.
    let isSensitive: Bool
    /// Image-like clips (real images and image files).
    let isImageLike: Bool
    /// True while OCR runs for this clip.
    let isOCRRunning: Bool
    /// Image has recognised text stored.
    let hasOCRText: Bool
    /// The search matched recognised text rather than the visible title.
    let matchedInOCR: Bool
    /// Quick-paste digit (1...9) shown as a keycap, nil when none.
    let quickPasteDigit: Int?

    /// Builds the model for `clip`.
    static func make(
        clip: Clip, isSelected: Bool, isPinned: Bool, isSensitive: Bool,
        isOCRRunning: Bool, query: String, quickPasteDigit: Int? = nil
    ) -> ClipCardModel {
        ClipCardModel(
            clipID: clip.id,
            title: clip.displayTitle,
            sourceApp: clip.sourceAppName,
            kindLabel: clip.kind.label,
            isSelected: isSelected,
            isPinned: isPinned,
            isSensitive: isSensitive,
            isImageLike: clip.isImageLike,
            isOCRRunning: isOCRRunning,
            hasOCRText: !(clip.ocrText ?? "").isEmpty,
            matchedInOCR: ocrMatched(clip: clip, query: query),
            quickPasteDigit: quickPasteDigit.flatMap { (1...9).contains($0) ? $0 : nil }
        )
    }

    /// True when `query` hits the clip's OCR text but not its visible title.
    static func ocrMatched(clip: Clip, query: String) -> Bool {
        guard clip.isImageLike, !query.isEmpty, let text = clip.ocrText, !text.isEmpty else { return false }
        guard !SearchHighlight.ranges(in: text, for: query, limit: 1).isEmpty else { return false }
        return SearchHighlight.ranges(in: clip.displayTitle, for: query, limit: 1).isEmpty
    }

    /// VoiceOver label. Sensitive clips expose only kind and source app: never
    /// the content and never the user title (which may echo the content).
    var accessibilityLabel: String {
        if isSensitive {
            return "Sensitive \(kindLabel.lowercased()) clip" + (sourceApp.map { " from \($0)" } ?? "")
        }
        return "\(title), \(kindLabel)"
    }

    /// VoiceOver value: state flags only, joined.
    var accessibilityValue: String {
        var parts: [String] = [isSelected ? "selected" : "not selected"]
        if isPinned { parts.append("pinned") }
        if isSensitive { parts.append("masked, hold to reveal") }
        if isOCRRunning { parts.append("extracting text") } else if hasOCRText { parts.append("text extracted") }
        if matchedInOCR { parts.append("matched in image text") }
        return parts.joined(separator: ", ")
    }
}

/// Cached sensitivity decision so scanning runs once per clip, not per redraw.
enum CardSensitivity {
    private nonisolated(unsafe) static let scanCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 2000
        return cache
    }()

    /// Same rules as `SensitiveContent.isSensitive(clip:)` with the text scan cached.
    static func isSensitive(_ clip: Clip) -> Bool {
        if let entry = SensitiveFlagStore.current?.entry(for: clip.contentKey) {
            if let override = entry.userOverride { return override }
            if entry.confidence >= SensitiveContent.sensitiveThreshold { return true }
        }
        guard clip.contentKind == .text else { return false }
        let key = "\(clip.id ?? -1)-\(clip.contentText.utf8.count)" as NSString
        if let hit = scanCache.object(forKey: key) { return hit.boolValue }
        let result = SensitiveContent.isSensitive(text: clip.contentText)
        scanCache.setObject(NSNumber(value: result), forKey: key)
        return result
    }
}

extension CardSensitivity {
    private nonisolated(unsafe) static let maskCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 1000
        return cache
    }()

    /// Single-line preview with recognised secrets bulleted, cached per clip.
    static func maskedLine(_ clip: Clip) -> String {
        let key = "\(clip.id ?? -1)-\(clip.contentText.utf8.count)" as NSString
        if let hit = maskCache.object(forKey: key) { return hit as String }
        let line = SensitiveContent.maskedPreview(clip.previewText)
            .replacingOccurrences(of: "\n", with: " ")
        maskCache.setObject(line as NSString, forKey: key)
        return line
    }
}

/// Search-match highlighting for previews.
enum HighlightedPreview {
    /// `text` with every match of `query` marked; returns plain text when none.
    static func attributed(_ text: String, query: String, color: Color) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        for range in SearchHighlight.ranges(in: text, for: query) {
            guard let target = Range(range, in: result) else { continue }
            result[target].backgroundColor = color.opacity(0.35)
            result[target].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }

    /// Number of marked runs, for tests.
    static func matchCount(_ text: String, query: String) -> Int {
        query.isEmpty ? 0 : SearchHighlight.ranges(in: text, for: query).count
    }
}
