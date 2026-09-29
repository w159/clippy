import Foundation

/// Feature actions the clip context menu may offer beyond the built-in ones.
enum ClipFeatureMenuItem: Hashable {
    case quickLook, pasteStack, mergeWithSelection, appendClipboard
    case transform, saveSnippet, translate, describeImage, suggestCategory
}

/// Pure decision of which feature menu items a clip gets. Sensitive clips get none:
/// they are never fed to transform, translate, describe, snippet, stack or preview features.
enum ClipFeatureMenuPolicy {
    /// Items visible for `clip`; `isSensitive` defaults to the shared sensitivity check.
    static func items(for clip: Clip, isSensitive: Bool? = nil) -> Set<ClipFeatureMenuItem> {
        if isSensitive ?? SensitiveContent.isSensitive(clip: clip) { return [] }
        switch clip.contentKind {
        case .text:
            var items: Set<ClipFeatureMenuItem> = [.quickLook, .pasteStack, .mergeWithSelection, .appendClipboard, .translate,
                                                   .suggestCategory]
            if !clip.contentText.isEmpty { items.formUnion([.transform, .saveSnippet]) }
            return items
        case .image: return [.quickLook, .pasteStack, .describeImage]
        case .file: return [.quickLook, .pasteStack]
        }
    }
}
