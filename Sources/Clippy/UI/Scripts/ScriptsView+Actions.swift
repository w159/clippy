import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ScriptsView {
    // MARK: - Navigation

    func click(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        let visibleIDs = filteredScripts.map(\.id)
        if flags.contains(.command) {
            batchSelection.toggle(id)
        } else if flags.contains(.shift) {
            batchSelection.extend(to: id, in: visibleIDs)
        } else {
            batchSelection.select(id)
            requestOpen(id)
        }
    }

    func requestOpen(_ id: UUID?) {
        if id == editing?.id { batchSelection = ScriptBatchSelection(ids: id.map { [$0] } ?? [], anchor: id); return }
        if isDirty {
            pendingNav = .open(id)
            activeDialog = .discard
            return
        }
        performOpen(id)
    }

    func requestNew() {
        if isDirty {
            pendingNav = .newScript
            activeDialog = .discard
            return
        }
        performNew()
    }

    func performNew() {
        let draft = Script(name: "")
        editing = draft
        batchSelection.select(draft.id)
        saveOutcome = nil
        historyDetail = nil
    }

    func performOpen(_ id: UUID?) {
        saveOutcome = nil
        historyDetail = nil
        guard let id, let script = store.script(id: id) else {
            editing = nil
            batchSelection.clear()
            return
        }
        editing = script
        batchSelection.select(id)
    }

    // MARK: - Actions

    func save() {
        guard var script = editing,
              !script.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        script.timeoutSeconds = max(0, script.timeoutSeconds)
        let wasNew = store.script(id: script.id) == nil
        let saved = wasNew ? store.add(script) : store.update(script)
        if saved {
            // Adopt the stored copy (fresh updatedAt/sortOrder) so the dirty check
            // compares like with like, and the draft row becomes the real row.
            editing = store.script(id: script.id) ?? script
            batchSelection.select(script.id)
            saveOutcome = .saved
            let snapshot = saveOutcome
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if saveOutcome == snapshot { saveOutcome = nil }
            }
        } else {
            saveOutcome = .failed
        }
    }

    func performDelete() {
        guard let current = editing else { return }
        let order = store.scripts.map(\.id)
        let index = order.firstIndex(of: current.id)
        ScriptExternalEditor.shared.stop(scriptID: current.id)
        center.dismiss(current.id)
        store.delete(id: current.id)
        // Open the neighbour so no blank draft is left behind.
        let remaining = store.scripts.map(\.id)
        let next = index.flatMap { remaining.isEmpty ? nil : remaining[min($0, remaining.count - 1)] }
        performOpen(next)
    }

    func performRun() {
        guard let script = editing else { return }
        drawerTab = .output
        center.start(script, sandbox: ScriptSandboxPolicy().sandbox(for: script.id))
    }

    func duplicateCurrent() {
        guard let id = editing?.id, let copy = store.duplicate(id: id) else { return }
        performOpen(copy.id)
        notice = "Duplicated. The copy is disabled until you enable it in Options."
    }

    func openExternally() {
        guard let script = editing else { return }
        let id = script.id
        let opened = ScriptExternalEditor.shared.open(script) { text in
            if editing?.id == id {
                editing?.body = text
            } else if var stored = store.script(id: id) {
                stored.body = text
                store.update(stored)
            }
        }
        if !opened { notice = "Could not open an external editor." }
    }

    func refreshPreflight() async {
        guard let script = editing else { preflight = nil; return }
        let message = await Task.detached(priority: .utility) { ScriptRunner.preflight(script) }.value
        // The user may have switched scripts while the probe ran.
        if editing?.id == script.id { preflight = message }
    }

    func exportScripts() {
        let ids = selection.count > 1 ? selection : editing.map { [$0.id] }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "clippy-scripts.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportJSON(ids: ids).write(to: url, options: .atomic)
            notice = "Exported to \(url.lastPathComponent)."
        } catch {
            notice = "Export failed: \(error.localizedDescription)"
        }
    }

    func importScripts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try store.importJSON(Data(contentsOf: url))
            notice = "Imported \(result.imported) script\(result.imported == 1 ? "" : "s")"
                + (result.rejected > 0 ? ", skipped \(result.rejected) unreadable" : "")
                + ". Imported scripts are disabled until you review and enable them."
        } catch {
            notice = "Import failed: not a Clippy scripts file."
        }
    }
}
