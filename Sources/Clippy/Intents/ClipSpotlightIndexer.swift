import CoreSpotlight
import Foundation
import GRDB

/// Opt-in Spotlight donations (default OFF: `AutomationSettings.spotlightIndexingEnabled`).
///
/// Clip titles and short previews are handed to the system index, so this is
/// gated and sensitive clips are never donated. Donation errors (for example the
/// CSIndexErrorDomain -1000 seen before this type existed) are logged without
/// content and never retried in a loop. There was no prior donation code in the
/// tree to fix; the -1000 cause is unverified, so it is gated behind the toggle.
enum ClipSpotlightIndexer {
    /// Domain used for bulk removal.
    static let domain = "com.jerry.clippy.clips"
    /// Donation batch ceiling per call.
    static let maxBatch = 200

    /// Items to donate: text clips only, non-sensitive, with ids.
    static func indexable(_ clips: [Clip], isSensitive: (Clip) -> Bool = { SensitiveContent.isSensitive(clip: $0) }) -> [Clip] {
        clips.filter { $0.id != nil && $0.contentKind == .text && !isSensitive($0) }
    }

    /// Unique identifier used for both donation and deletion.
    static func identifier(for clipID: Int64) -> String { "clip-\(clipID)" }

    static func item(for clip: Clip) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = IntentQueryMapper.title(for: clip)
        attributes.contentDescription = String(clip.previewText.prefix(200))
        return CSSearchableItem(uniqueIdentifier: identifier(for: clip.id ?? 0), domainIdentifier: domain, attributeSet: attributes)
    }

    /// Donates recent clips when enabled; no-op otherwise.
    static func donateRecent(database: ClipDatabase = .shared, settings: AutomationSettings = AutomationSettings()) {
        guard settings.spotlightIndexingEnabled, CSSearchableIndex.isIndexingAvailable() else { return }
        guard let clips = try? database.recentClips(limit: maxBatch) else { return }
        let items = indexable(clips).map(item(for:))
        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error { ClippyLog.warning("Spotlight donation failed: \(type(of: error))", category: ClippyLog.storage) }
        }
    }

    /// Removes one clip from the index (call on clip deletion; harmless when never indexed).
    static func remove(clipID: Int64) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [identifier(for: clipID)]) { _ in }
    }

    /// Removes everything, e.g. when the user turns the toggle off.
    static func removeAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }
}
