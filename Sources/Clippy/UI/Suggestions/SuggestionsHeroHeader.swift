import SwiftUI
import AppKit

/// Hero header of the Suggestions pane: title, context summary chip, "On-device"
/// lock badge, refresh, and the Diagnostics popover (INT-01).
struct SuggestionsHeroHeader: View {
    @Environment(\.clippyTokens) private var tokens
    /// Human summary of the context (never raw screen text). Nil hides the chip.
    let contextSummary: String?
    let onRefresh: () -> Void
    @State private var showDiagnostics = false

    var body: some View {
        HStack(spacing: tokens.metrics.space.two) {
            Image(systemName: "sparkles")
                .font(.headline)
                .foregroundStyle(tokens.accentText)
                .accessibilityHidden(true)
            Text("Suggested")
                .font(.headline)
                .foregroundStyle(tokens.textPrimary)
            if let contextSummary, !contextSummary.isEmpty {
                ReasonChip(title: contextSummary, systemImage: "app.dashed", explanation: "Context these suggestions were ranked against")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            ClippyBadge("On-device")
                .help("Runs entirely on this Mac. Screen text is never saved or sent anywhere.")
                .accessibilityLabel("On-device. Runs entirely on this Mac.")
            IconButton("arrow.clockwise", label: "Refresh suggestions", action: onRefresh)
            IconButton("stethoscope", label: "Context diagnostics", help: "Diagnostics: last context capture") {
                showDiagnostics.toggle()
            }
            .popover(isPresented: $showDiagnostics, arrowEdge: .bottom) {
                SuggestionDiagnosticsPopover(diagnostics: .current())
            }
        }
        .padding(.horizontal, tokens.metrics.space.three)
        .padding(.vertical, tokens.metrics.space.two)
        .accessibilityElement(children: .contain)
    }
}

/// Popover listing counts and timings for the last capture. Never shows screen text.
struct SuggestionDiagnosticsPopover: View {
    @Environment(\.clippyTokens) private var tokens
    let diagnostics: SuggestionDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.two) {
            Text("Context diagnostics").font(.headline).foregroundStyle(tokens.textPrimary)
            ForEach(Array(diagnostics.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label).foregroundStyle(tokens.textSecondary)
                    Spacer(minLength: tokens.metrics.space.three)
                    Text(row.value).foregroundStyle(tokens.textPrimary).multilineTextAlignment(.trailing)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
            Button("Copy diagnostics") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(diagnostics.copyText, forType: .string)
            }
            .help("Copies counts and timings only, never screen text")
        }
        .padding(tokens.metrics.space.three)
        .frame(width: 280)
    }
}

#Preview("Suggestions header") {
    SuggestionsHeroHeader(contextSummary: "Xcode: Clippy", onRefresh: {})
        .frame(width: 520)
}
