import AppKit
import Foundation
import GRDB

/// Applies transform results through the store. Sensitive sources never reach here: the panel does not offer transforms for them.
@MainActor
struct ClipStoreTransformSink: @MainActor TransformActionSink {
    let store: ClipStore
    let clip: Clip

    /// Inserts `text` as a fresh history clip.
    func saveAsNewClip(_ text: String) { store.saveDerivedText(text, source: "Clippy Transform") }

    /// Rewrites the source clip's text.
    func replaceText(_ text: String) { store.updateText(of: clip, to: text) }

    /// Copies `text` without the monitor re-capturing it.
    func copyResult(_ text: String) { store.copyOwnText(text) }
}

/// Applies translation results through the store.
@MainActor
struct ClipStoreTranslateSink: @MainActor TranslateActionSink {
    let store: ClipStore

    func copy(_ text: String) { store.copyOwnText(text) }

    func saveAsNewClip(_ text: String) { store.saveDerivedText(text, source: "Clippy Translate") }

    func replaceClip(_ clipID: Int64, with text: String) {
        do { try store.database.updateClipText(id: clipID, newText: text) } catch {
            ClippyLog.error("failed to replace translated clip: \(error)", category: ClippyLog.storage)
        }
    }
}

extension ClipStore {
    /// Saves derived text (transform, translation, image description) as a new clip. Never logs the text.
    func saveDerivedText(_ text: String, source: String) {
        guard !text.isEmpty else { return }
        do { try database.insertTextClip(text, sourceAppName: source) } catch {
            ClippyLog.error("failed to save derived clip: \(error)", category: ClippyLog.storage)
        }
    }

    /// Writes plain text to the pasteboard, skipping monitor capture when a monitor is attached.
    func copyOwnText(_ text: String) {
        let write = {
            self.pasteboard.clearContents()
            self.pasteboard.setString(text, forType: .string)
        }
        if let monitor { monitor.performOwnWrite(write) } else { write() }
    }
}

/// `AutoFileDataSource` over the clip database. Rows are read on demand; sensitivity is evaluated per clip.
struct ClipDatabaseAutoFileSource: AutoFileDataSource {
    let database: ClipDatabase

    func categories() -> [AutoFileCategory] {
        ((try? database.categories()) ?? []).compactMap { category in
            category.id.map { AutoFileCategory(id: $0, name: category.name) }
        }
    }

    func filedClips(inCategory id: Int64) -> [AutoFileClip] {
        fetch("""
            SELECT c.* FROM clips c JOIN clip_category cc ON cc.clipID = c.id
            WHERE cc.categoryID = ? AND c.contentKind = ? ORDER BY c.createdAt DESC LIMIT 60
            """, [id, ClipContentKind.text.rawValue])
    }

    func recentUncategorized(limit: Int) -> [AutoFileClip] {
        fetch("""
            SELECT * FROM clips WHERE contentKind = ? AND id NOT IN (SELECT clipID FROM clip_category)
            ORDER BY createdAt DESC LIMIT ?
            """, [ClipContentKind.text.rawValue, limit])
    }

    /// Maps one clip for the suggester; the content key is a hash so dismissals never store text.
    static func autoFileClip(_ clip: Clip) -> AutoFileClip? {
        guard let id = clip.id else { return nil }
        return AutoFileClip(id: id, contentKey: String(StableHash.fnv1a(clip.contentText)), text: clip.contentText,
                            isSensitive: SensitiveContent.isSensitive(clip: clip))
    }

    private func fetch(_ sql: String, _ arguments: [DatabaseValueConvertible]) -> [AutoFileClip] {
        let rows = (try? database.dbQueue.read { try Clip.fetchAll($0, sql: sql, arguments: StatementArguments(arguments)) }) ?? []
        return rows.compactMap(Self.autoFileClip)
    }
}
