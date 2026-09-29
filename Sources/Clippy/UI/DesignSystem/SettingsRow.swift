import SwiftUI

/// Aligned settings label/detail/control row that leaves persistence to its caller.
struct SettingsRow<Control: View>: View {
    @Environment(\.clippyTokens) private var tokens
    let title: LocalizedStringKey
    let detail: Text?
    let enabled: Bool
    let control: Control

    /// Creates a settings row with a native caller-owned control.
    init(title: LocalizedStringKey, detail: Text? = nil, enabled: Bool = true, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.enabled = enabled
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: tokens.metrics.space.four) {
            VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
                Text(title).font(.body).foregroundStyle(tokens.textPrimary)
                if let detail { detail.font(.caption).foregroundStyle(tokens.textSecondary) }
            }
            Spacer(minLength: tokens.metrics.space.two)
            control
        }
        .padding(.vertical, tokens.metrics.space.two)
        .frame(minHeight: detail == nil ? 44 : 52)
        .opacity(enabled ? 1 : 0.68)
        .disabled(!enabled)
    }
}
