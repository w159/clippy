import SwiftUI
import AppKit

// Confirmation flows for `ClipListView`: delete, batch delete and
// send-keystrokes requests that drive the alert bindings in `body`.

extension ClipListView {
    /// Stages a clip for deletion behind the confirmation alert. All delete
    /// entry points call this instead of store.delete directly.
    func requestDelete(_ clip: Clip) {
        clipPendingDeletion = clip
    }

    // MARK: - Batch actions

    /// Stages the current multi-selection for deletion behind the batch alert.
    func requestBatchDelete() {
        let clips = actionableClips
        guard !clips.isEmpty else { return }
        batchDeletePending = clips
    }

    /// Deletes each clip via the same single-clip store call used by the
    /// confirmation alert, then clears the selection.
    func performBatchDelete(_ clips: [Clip]) {
        deleteWithUndo(clips)
        selectedClipIDs = []
    }

    /// Routes a "send keystrokes" request through a confirmation dialog when
    /// the clip exceeds the warn threshold, otherwise fires immediately.
    func requestSendKeystrokes(_ clip: Clip) {
        if clip.contentText.count > settings.keystrokeWarnThreshold {
            clipPendingKeystrokes = clip
        } else {
            onSendKeystrokes(clip)
        }
    }
}
