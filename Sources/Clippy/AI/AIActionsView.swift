import SwiftUI
import AppKit

/// Drives one AI action through its lifecycle (running -> proposal -> applied or
/// failed) and publishes state for a sheet. Building the service from settings,
/// running the async call, and surfacing errors all live here so call sites stay
/// a one-liner. The actual write happens in the caller's `onApply`, after the
/// user approves: the preview + confirm contract.
@MainActor
final class AIActionRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case proposal(AIProposal)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// Text streamed so far by `run(action:on:instruction:)`, shown while running.
    @Published private(set) var partialText = ""

    /// The in-flight action task so a user can cancel a long run (audit [MEDIUM]).
    private var runningTask: Task<Void, Never>?
    /// The last work closure, kept so the failed phase can offer Retry.
    private var lastWork: ((AIService) async throws -> AIProposal?)?

    var isPresenting: Bool {
        switch phase { case .idle: return false; default: return true }
    }

    /// Start an action. `work` builds the proposal from the configured service;
    /// returning nil means "nothing to propose" (e.g. no matching category).
    func run(_ work: @escaping (AIService) async throws -> AIProposal?) {
        guard phase != .running else { return }
        lastWork = work
        partialText = ""
        switch AIService.fromSettings() {
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        case .success(let service):
            phase = .running
            runningTask = Task { [weak self] in
                do {
                    if let proposal = try await work(service) {
                        self?.phase = .proposal(proposal)
                    } else {
                        self?.phase = .failed("No suggestion was available.")
                    }
                } catch is CancellationError {
                    // Cancelled by the user; drop back to idle, not failed.
                    self?.phase = .idle
                } catch {
                    self?.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Run a custom action with streamed output: the sheet shows the reply as it
    /// arrives instead of a spinner (AI-12).
    func run(action: AIAction, on text: String, instruction: String = "") {
        run { [weak self] service in
            try await service.run(action: action, on: text, instruction: instruction) { partial in
                Task { @MainActor in self?.partialText = partial }
            }
        }
    }

    /// Re-run the last action from the failed phase (audit [MEDIUM]).
    func retry() {
        guard let work = lastWork else { return }
        run(work)
    }

    /// Cancel an in-flight run. Resets to idle so the sheet dismisses cleanly.
    func cancel() {
        runningTask?.cancel()
        runningTask = nil
        if case .running = phase { phase = .idle }
    }

    func reset() {
        runningTask?.cancel()
        runningTask = nil
        phase = .idle
    }
}

/// The preview + confirm surface. Shows progress, the proposed change (with a
/// before/after when the action edits existing content), and Apply / Cancel.
struct AIActionSheet: View {
    @ObservedObject var runner: AIActionRunner
    // Theme tokens so the sheet's surfaces/text track a theme switch like the panel.
    @ObservedObject private var settings = AppSettings.shared
    private var tokens: ThemeTokens { settings.theme }
    /// Called with the approved text when the user taps Apply.
    let onApply: (AIProposal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .foregroundStyle(tokens.textPrimary)
        .padding(20)
        .frame(minWidth: 460, idealWidth: 480)
    }

    @ViewBuilder
    private var content: some View {
        switch runner.phase {
        case .idle:
            EmptyView()
        case .running:
            // Reserve the result area before the first token arrives; streaming then fills it in place.
            box(runner.partialText, minHeight: 180)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Asking the model...")
                Spacer()
                // Audit [MEDIUM]: let the user abandon a long run instead of
                // waiting on a stuck request.
                Button("Stop") { runner.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
        case .failed(let message):
            Label("AI action failed", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(tokens.textSecondary)
                .textSelection(.enabled)
            HStack {
                // Audit [MEDIUM]: retry from the failed phase instead of closing
                // and re-triggering the action from the source view.
                Button("Retry") { runner.retry() }
                Spacer()
                Button("Close") { runner.reset() }.keyboardShortcut(.cancelAction)
            }
        case .proposal(let proposal):
            Text(proposal.label)
                .font(.headline)
            if proposal.showsDiff, let original = proposal.original {
                diff(original: original, proposed: proposal.proposed)
            } else {
                box(proposal.proposed)
            }
            HStack {
                Spacer()
                Button("Cancel") { runner.reset() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(proposal)
                    runner.reset()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func box(_ text: String, minHeight: CGFloat = 0) -> some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(tokens.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: minHeight, maxHeight: 220)
            .padding(8)
            .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tokens.cardBorder))
            // Audit [POLISH]: copy-button overlay on each diff/proposal box.
            if !text.isEmpty {
                ClipboardCopyButton(text: text, tokens: tokens)
                    .padding(6)
            }
        }
    }

    /// In-place rewrites only (the caller passes `original` just for those): a
    /// word-level diff with removals struck through in red and additions in green,
    /// followed by the clean result with a copy button.
    private func diff(original: String, proposed: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changes").font(.caption.weight(.semibold)).foregroundStyle(tokens.textSecondary)
            ScrollView {
                Text(Self.attributedDiff(original: original, proposed: proposed, tokens: tokens))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            .padding(8)
            .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tokens.cardBorder))
            Text("Result").font(.caption.weight(.semibold)).foregroundStyle(tokens.textSecondary)
            box(proposed)
        }
    }

    static func attributedDiff(original: String, proposed: String, tokens: ThemeTokens) -> AttributedString {
        var out = AttributedString()
        for span in AIWordDiff.diff(old: original, new: proposed) {
            var piece = AttributedString(span.text)
            switch span.kind {
            case .same:
                break
            case .removed:
                piece.foregroundColor = tokens.danger
                piece.strikethroughStyle = .single
            case .added:
                piece.foregroundColor = tokens.success
                piece.backgroundColor = tokens.success.opacity(0.15)
            }
            out += piece
        }
        return out
    }
}

/// A small copy-to-clipboard button with a transient checkmark confirmation.
/// Used on action diff/proposal boxes and on markdown code blocks.
/// (Audit [POLISH]: no copy affordance on code/diff content.)
private struct ClipboardCopyButton: View {
    let text: String
    let tokens: ThemeTokens
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            // Revert the checkmark after a short delay, cancelling an older reset.
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy")
        .onDisappear { resetTask?.cancel() }
    }
}
