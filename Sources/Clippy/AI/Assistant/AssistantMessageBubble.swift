import SwiftUI
import MarkdownUI

// MARK: - Message bubble

/// One transcript entry: user, assistant, or error bubble with collapsible tool
/// steps, hover reply actions, per-turn usage and a Retry action on errors.
struct AssistantMessageBubble: View {
    let message: AssistantMessage
    let isLive: Bool
    let position: AssistantGroupPosition
    /// Re-send the preceding user message when Retry is activated. nil for non-error bubbles.
    let onRetry: (() -> Void)?
    /// Save the assistant reply as a new history clip. nil hides the action.
    let onSaveAsClip: ((String) -> Void)?
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("fontSizeBase") private var baseFontSize = 13
    @State private var isHovering = false
    @State private var justCopied = false
    @State private var justSaved = false

    private var kind: AssistantBubbleKind { AssistantPresentation.kind(of: message) }
    private var isUser: Bool { kind == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: tokens.metrics.space.one) {
            if position == .single || position == .first {
                Text(AssistantPresentation.roleLabel(for: kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(kind == .error ? tokens.danger : tokens.textSecondary)
                    .padding(.horizontal, tokens.metrics.space.one)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 0) {
                if isUser { Spacer(minLength: 40) }
                bubble
                if !isUser { Spacer(minLength: 40) }
            }
            if showsReplyActions { replyActionRow }
            if !isLive, let usage = AssistantPresentation.turnUsageLabel(message.usage) {
                Text(usage)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(tokens.textSecondary)
                    .padding(.leading, tokens.metrics.space.one)
            }
            if message.isError, let onRetry {
                Button(action: onRetry) { Label("Retry", systemImage: "arrow.clockwise").font(.callout) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Retry sending the last message")
            }
        }
        .padding(.top, position.topSpacing)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { isHovering = $0 }
    }

    // MARK: Bubble

    private var bubble: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.two) {
            if kind == .assistant {
                ForEach(message.toolSteps) { step in AssistantToolStepView(step: step) }
            }
            content
        }
        // Selection while streaming uses the read-only NSTextView; SwiftUI text
        // selection is enabled only for finished bubbles.
        .textSelectionEnabled(!isLive)
        .padding(.horizontal, tokens.metrics.space.three)
        .padding(.vertical, tokens.metrics.space.two)
        .background(fill, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.md, style: .continuous).strokeBorder(border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AssistantPresentation.accessibilityLabel(for: message))
    }

    @ViewBuilder
    private var content: some View {
        let text = message.text
        switch kind {
        case .error:
            Label { Text(text.isEmpty ? " " : text) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(.body)
                .foregroundStyle(tokens.danger)
        case .user:
            Text(text.isEmpty ? " " : text).font(.body).foregroundStyle(tokens.onAccent)
        case .assistant:
            if isLive && text.isEmpty {
                shimmer
            } else if isLive {
                StreamingSelectableText(text: text, font: .systemFont(ofSize: CGFloat(baseFontSize)), color: NSColor(tokens.textPrimary))
            } else {
                Markdown(text.isEmpty ? " " : text)
                    .markdownTheme(.clippyAssistant(tokens: tokens, baseSize: CGFloat(baseFontSize)))
            }
        }
    }

    /// Streaming placeholder shown before the first token arrives.
    private var shimmer: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one + 2) {
            Skeleton(width: 220, height: 10)
            Skeleton(width: 150, height: 10)
        }
        .padding(.vertical, tokens.metrics.space.one)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant is thinking")
    }

    private var fill: Color {
        switch kind {
        case .user: return tokens.accent
        case .error: return tokens.danger.opacity(0.10)
        case .assistant: return tokens.surfaceElevated
        }
    }

    private var border: Color {
        switch kind {
        case .user: return .clear
        case .error: return tokens.danger.opacity(0.5)
        case .assistant: return tokens.stroke
        }
    }

    // MARK: Reply actions

    private var showsReplyActions: Bool {
        kind == .assistant && !isLive && !message.text.isEmpty
    }

    private var replyActionRow: some View {
        HStack(spacing: tokens.metrics.space.one) {
            IconButton(justCopied ? "checkmark" : "doc.on.doc", label: justCopied ? "Copied" : "Copy reply") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                flash($justCopied)
            }
            if let onSaveAsClip {
                IconButton(justSaved ? "checkmark" : "square.and.arrow.down", label: justSaved ? "Saved" : "Save as clip") {
                    onSaveAsClip(message.text)
                    flash($justSaved)
                }
            }
            Spacer()
        }
        // Row stays mounted so hover never reflows the transcript; keyboard focus still reaches it.
        .opacity(isHovering || justCopied || justSaved ? 1 : 0.001)
        .animation(ClippyMotion.animation(.instant, reduce: reduceMotion), value: isHovering)
    }

    private func flash(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            flag.wrappedValue = false
        }
    }
}
