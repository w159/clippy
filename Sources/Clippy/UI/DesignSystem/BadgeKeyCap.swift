import SwiftUI

/// Small semantic count/status badge with a text label, never color alone.
struct ClippyBadge: View {
    @Environment(\.clippyTokens) private var tokens
    let title: String
    let severity: BannerSeverity

    /// Creates a count/status badge with semantic severity.
    init(_ title: String, severity: BannerSeverity = .neutral) {
        self.title = title
        self.severity = severity
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(severity.foreground(in: tokens))
            .padding(.horizontal, tokens.metrics.space.two)
            .padding(.vertical, tokens.metrics.space.one)
            .background(severity.foreground(in: tokens).opacity(0.12), in: Capsule())
            .accessibilityLabel(title)
    }
}

/// Keyboard shortcut hint in a solid, high-contrast keycap.
struct KeyCap: View {
    @Environment(\.clippyTokens) private var tokens
    let title: String

    /// Creates a typographic keyboard key hint.
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption2.monospaced().weight(.medium))
            .foregroundStyle(tokens.textSecondary)
            .padding(.horizontal, tokens.metrics.space.one)
            .padding(.vertical, 2)
            .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.xs))
            .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.xs).strokeBorder(tokens.stroke, lineWidth: 0.75))
            .accessibilityLabel("Shortcut \(title)")
    }
}
