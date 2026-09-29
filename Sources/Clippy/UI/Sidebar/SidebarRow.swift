import SwiftUI

/// One expanded sidebar row: icon, title (or inline rename field), count badge,
/// selection, focus ring and drop indicator. Behavior is supplied by the pane.
struct SidebarRow<Icon: View>: View {
    @Environment(\.clippyTokens) private var tokens
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 32
    @State private var hovered = false
    @FocusState private var fieldFocused: Bool
    @FocusState.Binding var focus: SidebarRowID?
    let rowID: SidebarRowID
    let title: String
    let tint: Color
    let count: Int?
    let isSelected: Bool
    let help: String
    let accessibilityText: String
    let indicator: SidebarDropIndicator
    @Binding var renameText: String?
    let renameError: Bool
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let icon: Icon

    /// Creates a row; `renameText` non-nil switches the title to an editable field.
    init(
        rowID: SidebarRowID, focus: FocusState<SidebarRowID?>.Binding, title: String, tint: Color, count: Int?,
        isSelected: Bool, help: String, accessibilityText: String, indicator: SidebarDropIndicator = .none,
        renameText: Binding<String?> = .constant(nil), renameError: Bool = false,
        onCommitRename: @escaping () -> Void = {}, onCancelRename: @escaping () -> Void = {},
        @ViewBuilder icon: () -> Icon
    ) {
        self.rowID = rowID
        self._focus = focus
        self.title = title
        self.tint = tint
        self.count = count
        self.isSelected = isSelected
        self.help = help
        self.accessibilityText = accessibilityText
        self.indicator = indicator
        self._renameText = renameText
        self.renameError = renameError
        self.onCommitRename = onCommitRename
        self.onCancelRename = onCancelRename
        self.icon = icon()
    }

    private var radius: CGFloat { tokens.metrics.radius.sm }
    private var isFocused: Bool { focus == rowID }

    var body: some View {
        HStack(spacing: 8) {
            icon.symbolRenderingMode(.hierarchical).foregroundStyle(isSelected ? tokens.accentText : tint).frame(width: 18)
            titleView
            Spacer(minLength: 2)
            if let count, count > 0 { countBadge(count) }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: minimumHeight)
        .background(rowFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay { indicatorOverlay }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(tokens.focusRing, lineWidth: 2).padding(-1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .focusable()
        .focused($focus, equals: rowID)
        .focusEffectDisabled()
        .help(help)
        .accessibilityElement(children: renameText == nil ? .ignore : .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(dropValue)
    }

    private var rowFill: Color {
        if isSelected { return tokens.selection }
        return hovered ? tokens.surfaceInset : .clear
    }

    private var dropValue: String {
        switch indicator {
        case .none: return ""
        case .fileRing: return "Drop to file clips into this category"
        case .unfileRing: return "Drop to unfile clips from categories"
        case .reorderLine: return "Drop to reorder category"
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if renameText != nil {
            TextField("Category name", text: Binding(get: { renameText ?? "" }, set: { renameText = $0 }))
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(renameError ? tokens.danger : tokens.textPrimary)
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onChange(of: fieldFocused) { _, isFocused in if !isFocused { onCommitRename() } }
                .onSubmit(onCommitRename)
                .onExitCommand(perform: onCancelRename)
                .accessibilityLabel("Rename category")
                .accessibilityHint(renameError ? "A category with this name already exists" : "Press Return to save")
        } else {
            Text(title)
                .font(isSelected ? .callout.weight(.semibold) : .callout)
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(2)
        }
    }

    private func countBadge(_ value: Int) -> some View {
        Text("\(value)")
            .font(.caption2)
            .foregroundStyle(tokens.textSecondary)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tokens.surfaceInset, in: Capsule())
    }

    @ViewBuilder
    private var indicatorOverlay: some View {
        switch indicator {
        case .none:
            EmptyView()
        case .fileRing, .unfileRing:
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(tokens.accent, lineWidth: 2)
                .background(tokens.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .reorderLine:
            VStack { Rectangle().fill(tokens.accent).frame(height: 2).padding(.horizontal, 4); Spacer() }
                .offset(y: -1)
        }
    }
}
