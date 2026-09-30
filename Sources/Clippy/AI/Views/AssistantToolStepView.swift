import SwiftUI

/// One collapsible tool call row. The header names the tool and its argument
/// KEYS; the expanded body adds a size-only result summary. Argument values and
/// raw results are never rendered here, so clip text cannot leak through it.
struct AssistantToolStepView: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let step: AssistantToolStep
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            Button {
                withAnimation(ClippyMotion.animation(.instant, reduce: reduceMotion)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(AssistantPresentation.stepTitle(step)), \(AssistantPresentation.chipSummary(step)), arguments: \(AssistantPresentation.stepSubtitle(step))")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the result summary")
            if expanded { details }
        }
        .padding(.horizontal, tokens.metrics.space.two)
        .padding(.vertical, tokens.metrics.space.one + 2)
        .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
        .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm).strokeBorder(tokens.stroke, lineWidth: 0.75))
    }

    private var status: AssistantPresentation.StepStatus { AssistantPresentation.status(of: step) }

    /// Status glyph: spinner while running, check when done, warning when failed.
    @ViewBuilder
    private var glyph: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.hierarchical).foregroundStyle(tokens.success)
        case .failed:
            Image(systemName: "xmark.octagon.fill").symbolRenderingMode(.hierarchical).foregroundStyle(tokens.danger)
        }
    }

    /// Collapsed card: glyph, then a running title or the finished one-line chip, then the chevron.
    private var header: some View {
        HStack(spacing: tokens.metrics.space.two) {
            glyph
            if status == .running {
                Text(AssistantPresentation.stepTitle(step))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(tokens.textPrimary)
                Text("Processing...")
                    .font(.caption)
                    .foregroundStyle(tokens.accentText)
            } else {
                Text(AssistantPresentation.chipSummary(step))
                    .font(.callout)
                    .foregroundStyle(status == .failed ? tokens.danger : tokens.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tokens.textSecondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .contentShape(Rectangle())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            detailRow("Arguments", AssistantPresentation.stepSubtitle(step))
            detailRow("Result", step.isRunning ? "Running" : (status == .failed ? "Failed" : AssistantPresentation.resultSummary(step.result)))
        }
        .padding(.leading, tokens.metrics.space.six)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.metrics.space.two) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tokens.textSecondary)
            Text(value).font(.caption).foregroundStyle(tokens.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
