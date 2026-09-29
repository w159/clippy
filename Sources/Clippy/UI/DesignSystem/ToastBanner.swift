import SwiftUI

/// Status severity with safe semantic foreground/background roles.
enum BannerSeverity: Hashable {
    case neutral, success, warning, danger

    func foreground(in tokens: ClippyTokens) -> Color {
        switch self {
        case .neutral: return tokens.textSecondary
        case .success: return tokens.success
        case .warning: return tokens.warning
        case .danger: return tokens.danger
        }
    }

    var symbol: String {
        switch self {
        case .neutral: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        }
    }
}

/// Safe transient status message; callers pass metadata only, never clip content.
struct ClippyToast: View {
    @Environment(\.clippyTokens) private var tokens
    let message: String
    let severity: BannerSeverity
    let actionTitle: String?
    let action: (() -> Void)?
    let dismiss: () -> Void

    /// Creates a safe toast with optional one-shot action and dismiss callback.
    init(_ message: String, severity: BannerSeverity = .neutral, actionTitle: String? = nil, action: (() -> Void)? = nil, dismiss: @escaping () -> Void = {}) {
        self.message = message
        self.severity = severity
        self.actionTitle = actionTitle
        self.action = action
        self.dismiss = dismiss
    }

    var body: some View {
        GlassSurface(in: Capsule()) {
            HStack(spacing: tokens.metrics.space.two) {
                Image(systemName: severity.symbol).foregroundStyle(severity.foreground(in: tokens))
                Text(message).font(.callout).lineLimit(1)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(.plain).foregroundStyle(tokens.accentText)
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(minWidth: 24, minHeight: 24)
                }
                .buttonStyle(.plain)
                .help("Dismiss notification")
                .accessibilityLabel("Dismiss notification")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 360)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Persistent solid status banner; message and action remain accessible in all states.
struct ClippyBanner: View {
    @Environment(\.clippyTokens) private var tokens
    let message: String
    let severity: BannerSeverity
    let actionTitle: String?
    let action: (() -> Void)?
    let dismiss: (() -> Void)?

    /// Creates a persistent banner with optional repair action and dismissal.
    init(_ message: String, severity: BannerSeverity = .neutral, actionTitle: String? = nil, action: (() -> Void)? = nil, dismiss: (() -> Void)? = nil) {
        self.message = message
        self.severity = severity
        self.actionTitle = actionTitle
        self.action = action
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(spacing: tokens.metrics.space.two) {
            Image(systemName: severity.symbol).foregroundStyle(severity.foreground(in: tokens))
            Text(message).font(.callout).foregroundStyle(tokens.textPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: tokens.metrics.space.two)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.bordered).help(actionTitle) }
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss notification") }
        }
        .padding(tokens.metrics.space.two)
        .background(severity.foreground(in: tokens).opacity(0.10), in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
        .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm).strokeBorder(severity.foreground(in: tokens).opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
