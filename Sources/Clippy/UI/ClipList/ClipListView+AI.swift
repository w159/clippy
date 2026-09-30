import SwiftUI
import AppKit

// AI action plumbing for `ClipListView`: batch title generation, assistant
// hand-off, action execution, the instruction sheet and proposal handling.

/// Guards against starting a second batch title run while one is in flight.
@MainActor
private enum AIBatchTitleGuard {
    static var running = false
}

/// Instruction field that takes focus when the sheet appears.
private struct AIInstructionField: View {
    let prompt: String
    let label: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(3...5)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .accessibilityLabel(label)
            .onAppear { focused = true }
    }
}

extension ClipListView {
    /// Generate and apply an AI title for every selected text clip, non-interactively.
    /// Runs on the main actor (network awaits suspend off-main); each title is set
    /// via the store's title setter, so clip content is never overwritten.
    /// Pass `targets` to retry just the failed subset; omit it to run on the
    /// current selection (audit: batch AI title failures logged but not surfaced).
    func runBatchAITitles(targets retryTargets: [Clip]? = nil) {
        let targets = retryTargets ?? actionableClips.filter { $0.contentKind == .text }
        guard !targets.isEmpty else { return }
        guard !AIBatchTitleGuard.running else {
            showStatusBanner("Titles are already being generated.")
            return
        }
        guard case .success(let service) = AIService.fromSettings() else {
            showStatusBanner("AI isn't configured. Open Settings to set it up.")
            return
        }
        guard let titleAction = AIActionStore.shared.actions.first(where: { $0.name == "Suggest Title" })
            ?? AIActionStore.shared.actions.first else {
            showStatusBanner("No AI title action available.")
            return
        }
        if retryTargets == nil { selectedClipIDs = [] }
        showStatusBanner("Titling \(targets.count) clip\(targets.count == 1 ? "" : "s")...")
        AIBatchTitleGuard.running = true
        Task { @MainActor in
            defer { AIBatchTitleGuard.running = false }
            var done = 0
            var failed: [Clip] = []
            for clip in targets {
                do {
                    let proposal = try await service.run(action: titleAction, on: clip.contentText)
                    let title = AIService.sanitizeTitle(proposal.proposed)
                    guard AIService.isPlausibleTitle(AIService.trim(proposal.proposed)), AIService.isPlausibleTitle(title) else {
                        let error = AIError.decoding("The model returned reasoning or a sentence instead of a short title.")
                        AIHealth.shared.record(error)
                        throw error
                    }
                    store.renameClip(clip, userTitle: title)
                    done += 1
                } catch {
                    failed.append(clip)
                    ClippyLog.error("Batch AI title failed: \(error)", category: ClippyLog.ai)
                }
            }
            if failed.isEmpty {
                showStatusBanner("Titled \(done) of \(targets.count) clip\(targets.count == 1 ? "" : "s").", severity: .success)
            } else {
                showStatusBanner(
                    "Titled \(done) of \(targets.count). \(failed.count) failed.",
                    severity: .failure,
                    retry: { runBatchAITitles(targets: failed) }
                )
            }
        }
    }

    /// Switch the pane to the assistant with `clip` attached as context. The
    /// explicit flag stops the selection-change handler from re-deriving the
    /// context from the anchored row (the right-clicked clip may differ).
    func openAssistant(with clip: Clip) {
        assistantContextExplicit = true
        assistantContextClip = clip.contentKind == .text ? clip : nil
        selection = .assistant
    }

    func runAIAction(_ action: AIAction, on clip: Clip) {
        // Suggest Category must file the clip, not rewrite its body. Route it
        // through suggestCategory so it yields a .category proposal.
        if action.isSuggestCategory {
            aiTargetClip = clip
            let clipText = clip.contentText
            let categoryNames = store.categories.map(\.name)
            aiRunner.run { service in
                try await service.suggestCategory(forText: clipText, categories: categoryNames)
            }
            return
        }
        // Actions whose template references {instruction} need the user's input
        // first; running them blind sends the model a prompt with an empty
        // instruction (e.g. "Translate the following text to .").
        if action.needsInstruction {
            aiInstructionAction = action
            aiInstructionClip = clip
            aiInstructionText = ""
            return
        }
        runAIActionNow(action, on: clip, instruction: "")
    }

    /// Small sheet asking for the {instruction} an AI action needs before it
    /// runs. Multi-line so real instructions fit; Return runs, Escape cancels.
    var instructionSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(aiInstructionAction?.name ?? "AI action", systemImage: "sparkles")
                .font(PanelTypography.body(settings).weight(.semibold))
                .foregroundStyle(tokens.textPrimary)
            AIInstructionField(
                prompt: aiInstructionPromptMessage, label: "Instruction for \(aiInstructionAction?.name ?? "AI action")",
                text: $aiInstructionText)
                .font(PanelTypography.body(settings))
            HStack {
                Spacer()
                Button("Cancel") {
                    aiInstructionAction = nil
                    aiInstructionClip = nil
                }
                .keyboardShortcut(.cancelAction)
                .help("Close without running the action")
                Button("Run") {
                    let trimmed = aiInstructionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let action = aiInstructionAction, let clip = aiInstructionClip, !trimmed.isEmpty {
                        runAIActionNow(action, on: clip, instruction: trimmed)
                    }
                    aiInstructionAction = nil
                    aiInstructionClip = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(aiInstructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Run \(aiInstructionAction?.name ?? "the action") with this instruction")
            }
        }
        .padding(16)
        .frame(minWidth: 380, idealWidth: 400)
    }

    /// Tailored prompt copy per built-in so the field reads naturally
    /// (e.g. "Which language?" for Translate). Falls back to a generic ask.
    var aiInstructionPromptMessage: String {
        switch aiInstructionAction?.name {
        case "Translate":    return "Which language should this be translated to?"
        case "Change Tone":  return "What tone? (e.g. formal, friendly, concise)"
        case "Rewrite":      return "How should this be rewritten?"
        case "Generate Clip": return "What should the new clip contain?"
        default:             return "Enter an instruction for this action."
        }
    }

    /// Execute the action immediately with the (possibly empty) instruction.
    func runAIActionNow(_ action: AIAction, on clip: Clip, instruction: String) {
        aiTargetClip = clip
        let clipText = clip.contentText
        // Streams partial text into `aiRunner.partialText` (AI-12).
        aiRunner.run(action: action, on: clipText, instruction: instruction)
    }

    /// Apply an approved AI proposal to its source clip.
    func handleAIProposal(_ proposal: AIProposal, for clip: Clip) {
        let text = proposal.proposed
        switch proposal.kind {
        case .category:
            // Suggested category: file the clip into the matched category,
            // leaving the clip body untouched. Match by name against the store.
            if let category = store.categories.first(where: {
                $0.name.caseInsensitiveCompare(text) == .orderedSame
            }), let categoryID = category.id, let clipID = clip.id {
                store.fileClip(id: clipID, intoCategory: categoryID)
                showStatusBanner("Filed under \"\(category.name)\"")
            } else {
                showStatusBanner("No matching category for \"\(text)\"")
            }
        case .rewrite, .title, .summary:
            // proposeEdit disposition: overwrite the clip text in-place.
            store.updateText(of: clip, to: text)
        case .newClip:
            // newClip disposition: insert as a fresh history entry.
            store.saveScriptOutput(text)
        case .copyToClipboard:
            // copyToClipboard disposition: write result to NSPasteboard without
            // touching the source clip, then show a brief status banner.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showStatusBanner("Copied to clipboard")
        }
    }
}
