import AppKit
import Combine
import GRDB
import SwiftUI

/// The clip editor. Text clips get a full text editor with a title field, live
/// counts, and (when configured) AI actions. Image clips get rotate / flip /
/// crop tools that save back to the media store. Both share the title + Save /
/// Cancel chrome.
struct ClipEditorView: View {
    let clip: Clip
    let store: ClipStore
    /// Registered with dirty/save callbacks so the hosting window can prompt
    /// before the title-bar close button discards unsaved edits.
    var dirtyBridge: EditorDirtyStateBridge? = nil
    /// A recovered draft to restore into a text editor (EDT-01).
    var draft: EditorDraft? = nil
    let onClose: () -> Void

    var body: some View {
        Group {
            if clip.contentKind == .image {
                ImageClipEditor(clip: clip, store: store, dirtyBridge: dirtyBridge, onClose: onClose)
            } else {
                TextClipEditor(clip: clip, store: store, dirtyBridge: dirtyBridge, draft: draft, onClose: onClose)
            }
        }
        .clippyDesignSystem()
    }
}
