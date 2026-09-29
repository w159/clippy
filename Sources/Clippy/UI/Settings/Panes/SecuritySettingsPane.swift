import SwiftUI

/// Security settings: app lock, managed status, sensitive content, retention, audit log, MCP token, sandbox, capture guards.
struct SecuritySettingsPane: View {
    @State private var notice: PaneNotice?

    /// Creates the pane.
    init() {}

    var body: some View {
        PaneScroll(title: "Security", notice: $notice) {
            SecurityAppLockSection(notice: $notice)
            SecuritySensitiveSection(notice: $notice)
            SecurityRetentionSection(notice: $notice)
            SecurityAuditSection(notice: $notice)
            SecurityAccessSection(notice: $notice)
        }
    }
}

#Preview("Security settings") {
    SecuritySettingsPane().frame(width: 640, height: 800)
}
