import SwiftUI

// Shared row helpers for the settings panes: token-backed notes, search anchors that
// flash, and the managed-preference lock badge (SET-01, SET-09, SEC-01).

/// Row id currently flashed after a search jump.
private struct SettingsFlashKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Anchor id of the row to highlight, set by the settings window after a search jump.
    var settingsFlashRow: String? {
        get { self[SettingsFlashKey.self] }
        set { self[SettingsFlashKey.self] = newValue }
    }
}

/// Explanatory caption under a row, in the secondary text role.
struct SettingsNote: View {
    @Environment(\.clippyTokens) private var tokens
    private let text: Text

    init(_ text: String) { self.text = Text(text) }
    init(_ text: Text) { self.text = text }

    var body: some View {
        text.font(.caption).foregroundStyle(tokens.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Success/failure/neutral status line with an icon.
struct SettingsStatusLine: View {
    enum Kind { case success, warning, failure, neutral }

    @Environment(\.clippyTokens) private var tokens
    let kind: Kind
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .symbolRenderingMode(.hierarchical)
            .textSelection(.enabled)
    }

    private var symbol: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.circle.fill"
        case .neutral: return "circle.dashed"
        }
    }

    private var color: Color {
        switch kind {
        case .success: return tokens.success
        case .warning: return tokens.warning
        case .failure: return tokens.danger
        case .neutral: return tokens.textSecondary
        }
    }
}

private struct SettingsRowAnchor: ViewModifier {
    @Environment(\.settingsFlashRow) private var flashRow
    @Environment(\.clippyTokens) private var tokens
    let id: String

    func body(content: Content) -> some View {
        content
            .id(id)
            .listRowBackground(flashRow == id ? tokens.selection : nil)
            .animation(.easeInOut(duration: 0.25), value: flashRow)
    }
}

private struct SettingsManagedModifier: ViewModifier {
    @Environment(\.clippyTokens) private var tokens
    let state: SettingsForcedState

    func body(content: Content) -> some View {
        HStack(spacing: tokens.metrics.space.two) {
            content.disabled(state.isDisabled)
            if let symbol = state.lockSymbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
                    .help(state.help ?? "")
                    .accessibilityLabel(state.help ?? "")
            }
        }
    }
}

extension View {
    /// Marks a row as a search jump target and flashes it when it is the target.
    func settingsRow(_ id: String) -> some View { modifier(SettingsRowAnchor(id: id)) }

    /// Disables the control and shows a lock badge when `key` is managed by policy.
    func settingsManaged(_ key: String) -> some View {
        modifier(SettingsManagedModifier(state: SettingsForcedState(key: key)))
    }
}

/// Collapsed "Advanced" group for rarely used rows. It opens itself when a settings
/// search jump targets one of its `anchors`, so search never lands on a hidden row.
struct SettingsAdvanced<Content: View>: View {
    @Environment(\.settingsFlashRow) private var flashRow
    @State private var expanded = false
    let anchors: Set<String>
    let content: Content

    init(anchors: Set<String>, @ViewBuilder content: () -> Content) {
        self.anchors = anchors
        self.content = content()
    }

    var body: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $expanded) { content }
        }
        .onChange(of: flashRow) { _, row in
            if let row, anchors.contains(row) { expanded = true }
        }
    }
}
