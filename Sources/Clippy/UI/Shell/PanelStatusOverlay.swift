import SwiftUI

/// One transient or persistent status line shown at the bottom of the panel.
struct PanelStatusItem: Equatable {
    /// Distinguishes repeated messages so an older dismissal timer cannot clear a replacement.
    var id = UUID()
    var message: String
    var severity: BannerSeverity
    var actionTitle: String?
    /// Persistent items use the solid banner and stay until dismissed.
    var isPersistent: Bool

    static func == (lhs: PanelStatusItem, rhs: PanelStatusItem) -> Bool {
        lhs.id == rhs.id && lhs.message == rhs.message && lhs.severity == rhs.severity
            && lhs.actionTitle == rhs.actionTitle && lhs.isPersistent == rhs.isPersistent
    }
}

/// Bottom overlay rendering `PanelStatusItem` with the design-system toast
/// (transient) or banner (persistent), and announcing it to VoiceOver.
struct PanelStatusOverlay: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: PanelStatusItem?
    let action: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        Group {
            if let item {
                Group {
                    if item.isPersistent {
                        ClippyBanner(item.message, severity: item.severity, actionTitle: item.actionTitle,
                                     action: action, dismiss: dismiss)
                    } else {
                        ClippyToast(item.message, severity: item.severity, actionTitle: item.actionTitle,
                                    action: action, dismiss: dismiss)
                    }
                }
                .padding(.horizontal, tokens.metrics.space.three)
                .padding(.bottom, tokens.metrics.space.two)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(ClippyMotion.animation(.toastIn, reduce: reduceMotion), value: item)
        .onChange(of: item) { _, newValue in
            guard let newValue else { return }
            AccessibilityNotification.Announcement(newValue.message).post()
        }
    }
}
