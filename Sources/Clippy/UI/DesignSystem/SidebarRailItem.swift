import SwiftUI

/// Solid icon-rail navigation button with selection, focus and disabled states.
struct SidebarRailItem: View {
    @Environment(\.clippyTokens) private var tokens
    @State private var hovered = false
    @FocusState private var focused: Bool
    let title: String
    let systemImage: String
    let count: Int?
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    /// Creates an accessible sidebar rail item; tooltip includes count when supplied.
    init(_ title: String, systemImage: String, count: Int? = nil, selected: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.selected = selected
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? tokens.onAccent : .secondary)
                .frame(width: 44, height: 38)
                .background(selected ? tokens.accent : hovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { if focused { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tokens.focusRing, lineWidth: 2).padding(-2) } }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityValue(count.map(String.init) ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(count.map { "\(title), \($0)" } ?? title)
    }
}
