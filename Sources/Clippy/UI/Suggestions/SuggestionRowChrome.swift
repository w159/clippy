import SwiftUI

/// Chrome around one suggestion card: numbered keycap, reason chip with score bar,
/// optional "Refined with Apple Intelligence" chip, and the per-row menu (INT-06/07).
/// The card itself (masking, drag, selection) is supplied by the caller.
struct SuggestionRowChrome<Card: View>: View {
    @Environment(\.clippyTokens) private var tokens
    @State private var hovered = false
    let suggestion: Suggestion
    let index: Int
    let card: Card
    let onPaste: (_ plain: Bool) -> Void
    let onFeedback: (SuggestionFeedbackAction) -> Void
    let onFindSimilar: () -> Void

    private var isTop: Bool { index == 0 }
    private var excludeAction: SuggestionFeedbackAction? { SuggestionFeedback.excludeAppAction(for: suggestion.clip) }

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            card
            HStack(spacing: tokens.metrics.space.two) {
                if index < 9 { KeyCap("\(index + 1)").help("Press \(index + 1) to paste") }
                ReasonChip(title: suggestion.chipTitle, systemImage: isTop ? "star.fill" : "info.circle", explanation: suggestion.chipExplanation)
                scoreBar
                if suggestion.isRefined {
                    ReasonChip(title: "Refined with Apple Intelligence", systemImage: "apple.intelligence", explanation: "The reason was written by the on-device model")
                }
                Spacer(minLength: 0)
                rowMenu
            }
            .padding(.horizontal, tokens.metrics.space.one)
        }
        .padding(tokens.metrics.space.one)
        .background(isTop ? tokens.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
        .overlay(alignment: .leading) {
            if isTop { Capsule().fill(tokens.accent).frame(width: 3).padding(.vertical, 6) }
        }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Paste") { onPaste(false) }
        .accessibilityAction(named: "Paste as plain text") { onPaste(true) }
        .accessibilityAction(named: "Not relevant") { onFeedback(.notRelevant) }
        .accessibilityAction(named: "Never suggest this clip") { onFeedback(.neverSuggest) }
    }

    private var scoreBar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(tokens.surfaceInset)
            Capsule().fill(tokens.accent).frame(width: 28 * CGFloat(min(max(suggestion.score, 0), 1)))
        }
        .frame(width: 28, height: 4)
        .help("Relevance \(suggestion.scorePercent)%")
        .accessibilityLabel("Relevance \(suggestion.scorePercent) percent")
    }

    private var rowMenu: some View {
        Menu {
            Button("Paste") { onPaste(false) }
            Button("Paste as Plain Text") { onPaste(true) }
            Divider()
            Button("Not Relevant") { onFeedback(.notRelevant) }
            Button("Never Suggest This Clip") { onFeedback(.neverSuggest) }
            if let excludeAction {
                Button("Never Suggest from \(suggestion.clip.sourceAppName ?? "This App")") { onFeedback(excludeAction) }
            }
            if suggestion.clip.contentKind == .text {
                Divider()
                Button("Find Similar Clips", action: onFindSimilar)
            }
        } label: {
            Image(systemName: "ellipsis.circle").frame(minWidth: 24, minHeight: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(hovered || isTop ? 1 : 0.55)
        .help("Suggestion actions")
        .accessibilityLabel("Suggestion actions")
    }
}

#Preview("Suggestion row") {
    var clip = Clip(
        id: 1, contentText: "swift build -c release", contentRTF: nil, contentHTML: nil,
        typeIdentifier: "public.utf8-plain-text", sourceAppBundleID: "com.apple.dt.Xcode",
        sourceAppName: "Xcode", createdAt: Date())
    clip.id = 1
    return VStack {
        ForEach(0..<2, id: \.self) { index in
            SuggestionRowChrome(
                suggestion: Suggestion(clip: clip, score: 0.8 - Double(index) * 0.3, reason: "Same app: Xcode", isRefined: index == 1),
                index: index, card: Text(clip.contentText).frame(maxWidth: .infinity, alignment: .leading).padding(8),
                onPaste: { _ in }, onFeedback: { _ in }, onFindSimilar: {})
        }
    }
    .padding()
    .frame(width: 520)
}
