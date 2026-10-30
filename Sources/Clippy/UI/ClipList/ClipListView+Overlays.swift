import SwiftUI
import AppKit

// Confirmation flows for `ClipListView`: delete, batch delete and
// send-keystrokes requests that drive the alert bindings in `body`.

extension ClipListView {
    /// Single entry point for every single-clip delete path. A clip that can be
    /// snapshotted for Cmd+Z is deleted at once with an Undo toast (asking first
    /// and then offering Undo is two gates for one action); a clip too large to
    /// snapshot cannot come back, so it still goes through the confirmation alert.
    func requestDelete(_ clip: Clip) {
        if let snapshot = ClipUndoBuffer.snapshot(of: clip, categoryIDs: store.categoryIDs(for: clip),
                                                  media: store.database.media) {
            deleteWithUndo([clip], snapshots: [snapshot])
        } else {
            clipPendingDeletion = clip
        }
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
