import SwiftUI

extension AssistantPanelBody {
    // MARK: Attach chip

    /// Explicit context chip (AI-03): an attached clip, or a one-tap offer for the selected clip.
    @ViewBuilder
    var attachRow: some View {
        if let clip = viewModel.contextClip {
            attachChip(title: clip.displayTitle, detail: clip.previewText, symbol: "paperclip", actionLabel: "Detach clip from conversation",
                       actionSymbol: "xmark.circle.fill") { viewModel.contextClip = nil }
                .accessibilityLabel("Attached clip: \(clip.displayTitle)")
        } else if let clip = contextClip {
            attachChip(title: "Add \"\(clip.displayTitle)\" as context", detail: nil, symbol: "paperclip.badge.plus",
                       actionLabel: "Attach selected clip to conversation", actionSymbol: "plus.circle.fill") { viewModel.contextClip = clip }
        }
    }

    private func attachChip(title: String, detail: String?, symbol: String, actionLabel: String, actionSymbol: String,
                            action: @escaping () -> Void) -> some View {
        HStack(spacing: tokens.metrics.space.two) {
            Image(systemName: symbol).foregroundStyle(tokens.accentText)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(tokens.textPrimary).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(tokens.textSecondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            IconButton(actionSymbol, label: actionLabel, action: action)
        }
        .padding(.horizontal, tokens.metrics.space.three)
        .padding(.vertical, tokens.metrics.space.one)
        .background(tokens.surfaceInset, in: Capsule())
        .overlay(Capsule().strokeBorder(tokens.stroke, lineWidth: 0.75))
        .padding(.horizontal, tokens.metrics.space.three)
        .help("Attached clips are sent to the provider as context for your messages")
    }

    // MARK: Input bar

    var inputBar: some View {
        let streaming = viewModel.state == .streaming
        let canSend = AssistantPresentation.canSend(viewModel.inputText)
        return VStack(spacing: tokens.metrics.space.one) {
            attachRow
            GlassSurface(in: RoundedRectangle(cornerRadius: tokens.metrics.radius.lg, style: .continuous)) {
                HStack(alignment: .bottom, spacing: tokens.metrics.space.two) {
                    TextField("Ask about your clips...", text: $viewModel.inputText, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .foregroundStyle(tokens.textPrimary)
                        .focused($inputFocused)
                        .accessibilityLabel("Message input")
                        .onSubmit { if canSend && viewModel.state == .ready { viewModel.send() } }
                        .onAppear { inputFocused = true }
                    Button {
                        if streaming { viewModel.stop() } else { viewModel.send() }
                    } label: {
                        Image(systemName: streaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(streaming || canSend ? tokens.accentText : tokens.textSecondary)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .frame(minWidth: 28, minHeight: 28)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(streaming ? "Stop (Esc)" : "Send (Return)")
                    .accessibilityLabel(streaming ? "Stop" : "Send")
                    .disabled(!streaming && !canSend)
                }
            }
            .padding(.horizontal, tokens.metrics.space.three)
            Text(streaming ? "Esc stops the reply" : "Return sends")
                .font(.caption2).foregroundStyle(tokens.textSecondary)
        }
        .padding(.vertical, tokens.metrics.space.two)
        .background(tokens.surface)
    }
}
