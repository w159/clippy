import AppKit
import SwiftUI

// AI actions and staged side effects (EDT-09).
extension TextClipEditor {
    // MARK: AI actions (EDT-09)

    /// Run a store action against the current editor text, mirroring
    /// ClipListView.runAIAction. Suggest Category routes through suggestCategory,
    /// and {instruction} templates prompt first.
    func runAction(_ action: AIAction) {
        if action.isSuggestCategory {
            let clipText = text
            let categoryNames = store.categories.map(\.name)
            assistant.run { service in
                try await service.suggestCategory(forText: clipText, categories: categoryNames)
            }
            return
        }
        if action.needsInstruction {
            instructionAction = action
            return
        }
        runActionNow(action, instruction: "")
    }

    /// Execute the action immediately against the current editor text.
    func runActionNow(_ action: AIAction, instruction: String) {
        let clipText = text
        // Streams partial text into `assistant.partialText` (AI-12).
        assistant.run(action: action, on: clipText, instruction: instruction)
    }

    /// Every result is staged: field results land in the editor (dirty until
    /// Save), the rest wait in `pendingEffects` until Save applies them.
    func apply(_ proposal: AIProposal) {
        switch proposal.kind {
        case .title:
            title = proposal.proposed
        case .rewrite, .summary:
            text = proposal.proposed
        case .newClip:
            stage(.newClip(proposal.proposed))
        case .copyToClipboard:
            stage(.copy(proposal.proposed))
        case .category:
            let name = proposal.proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                showStatus("The suggested category was empty")
                return
            }
            stage(.category(name))
        }
    }

    func stage(_ effect: PendingEffect) {
        pendingEffects.removeAll { $0.id == effect.id }
        pendingEffects.append(effect)
    }

    /// Applies staged side effects after the text/title save landed. Returns a
    /// failure message, or nil when everything applied.
    func applyPendingEffects() -> String? {
        var failure: String?
        for effect in pendingEffects {
            switch effect {
            case .newClip(let value):
                if !store.saveScriptOutput(value) { failure = "Could not create the new clip." }
            case .copy(let value):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            case .category(let name):
                if !assignClipToCategory(named: name) { failure = "Could not file the clip under \"\(name)\"." }
            }
        }
        pendingEffects = []
        return failure
    }

    /// Assigns the open clip to a category whose name matches `name`
    /// (case-insensitive, trimmed), creating it with default appearance if
    /// there is none. Returns false when it could not be done.
    func assignClipToCategory(named name: String) -> Bool {
        guard let clipID = clip.id else { return false }
        if let existing = store.categories.first(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }), let catID = existing.id {
            store.addClip(id: clipID, toCategory: catID)
            return true
        }
        let created = store.createCategory(
            named: name,
            colorHex: CategoryPalette.hexes[0],
            iconKind: .symbol,
            iconValue: "pin.fill"
        )
        guard let catID = created?.id else { return false }
        store.addClip(id: clipID, toCategory: catID)
        return true
    }

    func showStatus(_ message: String) {
        statusMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if statusMessage == message {
                statusMessage = nil
            }
        }
    }

    var aiSheetBinding: Binding<Bool> {
        Binding(get: { assistant.isPresenting }, set: { if !$0 { assistant.reset() } })
    }
}
