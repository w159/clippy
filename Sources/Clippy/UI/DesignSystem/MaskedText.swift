import SwiftUI

/// Pure sensitivity presentation rules; no content is copied into logs or labels.
enum MaskedTextLogic {
    /// Reveals plaintext only when the content is not sensitive or reveal is held.
    static func isVisible(sensitive: Bool, revealHeld: Bool) -> Bool { !sensitive || revealHeld }

    /// Content or a fixed safe placeholder, never a length-preserving mask.
    static func displayedText(_ text: String, sensitive: Bool, revealHeld: Bool) -> String {
        isVisible(sensitive: sensitive, revealHeld: revealHeld) ? text : "Sensitive content"
    }
}

/// Text preview that renders no clipboard text until the user explicitly holds
/// the reveal affordance; releasing, losing focus or removing the view remasks it.
struct MaskedText: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealHeld = false
    @FocusState private var focused: Bool
    let text: String
    let sensitive: Bool

    /// Creates a sensitive-aware text preview. Non-sensitive content is shown normally.
    init(_ text: String, sensitive: Bool) {
        self.text = text
        self.sensitive = sensitive
    }

    private var visible: Bool { MaskedTextLogic.isVisible(sensitive: sensitive, revealHeld: revealHeld) }

    var body: some View {
        Group {
            if visible {
                Text(text)
                    .font(.body)
                    .foregroundStyle(tokens.textPrimary)
                    .textSelection(.enabled)
            } else {
                HStack(spacing: tokens.metrics.space.two) {
                    Image(systemName: "lock.fill").foregroundStyle(tokens.textSecondary)
                    Text("Sensitive").font(.body.weight(.medium)).foregroundStyle(tokens.textPrimary)
                    Rectangle().fill(tokens.masked).frame(height: 12).clipShape(Capsule()).accessibilityHidden(true)
                }
                .padding(tokens.metrics.space.two)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tokens.surfaceElevated)
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 12, pressing: { down in
            guard sensitive else { return }
            withAnimation(ClippyMotion.animation(.masked, reduce: reduceMotion)) { revealHeld = down }
        }, perform: {})
        .focused($focused)
        .onChange(of: focused) { _, hasFocus in
            if !hasFocus { revealHeld = false }
        }
        .onDisappear { revealHeld = false }
        .accessibilityLabel(sensitive && !revealHeld ? "Sensitive clip. Hold to reveal." : (sensitive ? "Sensitive clip revealed" : "Text preview"))
        .accessibilityAction(named: Text(visible ? "Remask sensitive content" : "Reveal sensitive content")) {
            guard sensitive else { return }
            revealHeld.toggle()
        }
        .accessibilityHidden(sensitive && revealHeld)
        .privacySensitive(sensitive)
    }
}
