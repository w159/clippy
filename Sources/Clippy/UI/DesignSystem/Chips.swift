import SwiftUI

/// Common control interaction states; colors never carry state by themselves.
enum ControlState: Hashable {
    case rest, hover, pressed, selected, focused, disabled
}

/// Label and optional count for a filter chip.
struct FilterChipModel: Identifiable {
    let id: String
    let title: String
    var systemImage: String? = nil
    var count: Int? = nil
    var accessibilityValue: String? = nil
}

/// Floating glass filter control with all standard interaction states.
struct FilterChip: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false
    @FocusState private var focused: Bool
    let model: FilterChipModel
    let state: ControlState
    let action: () -> Void

    /// Creates an actionable filter chip; selected controls expose selected trait.
    init(model: FilterChipModel, state: ControlState = .rest, action: @escaping () -> Void) {
        self.model = model
        self.state = state
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: tokens.metrics.space.one) {
                if let symbol = model.systemImage { Image(systemName: symbol).imageScale(.small) }
                Text(model.title).lineLimit(1)
                if let count = model.count { Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(tokens.textSecondary) }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, tokens.metrics.space.three)
            .padding(.vertical, tokens.metrics.space.one)
            .background {
                if reduceTransparency || contrast == .increased {
                    Capsule().fill(state == .selected ? tokens.selection : chipFill)
                } else {
                    Capsule().fill(.clear).glassEffect(.regular.interactive(), in: Capsule())
                    if state == .selected { Capsule().fill(tokens.selection.opacity(0.24)) }
                }
            }
            .overlay(Capsule().strokeBorder(state == .selected ? tokens.accentText : tokens.stroke, lineWidth: state == .selected ? 1.5 : 0.75))
            .overlay { if focused || state == .focused { Capsule().strokeBorder(tokens.focusRing, lineWidth: 2).padding(-2) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
        .disabled(state == .disabled)
        .animation(ClippyMotion.animation(.instant, reduce: reduceMotion), value: hovered)
        .accessibilityAddTraits(state == .selected ? .isSelected : [])
        .accessibilityValue(model.accessibilityValue ?? (state == .selected ? "Selected" : ""))
        .help(model.accessibilityValue ?? model.title)
    }

    private var chipFill: Color {
        switch state {
        case .selected: return tokens.selection
        case .disabled: return tokens.surfaceInset.opacity(0.55)
        case .pressed: return tokens.surfaceInset
        case .hover: return hovered ? tokens.surfaceInset.opacity(0.7) : tokens.surfaceElevated.opacity(0.72)
        default: return hovered ? tokens.surfaceInset.opacity(0.7) : tokens.surfaceElevated.opacity(0.72)
        }
    }
}

/// Safe, compact reason label for a policy or operation outcome.
struct ReasonChip: View {
    @Environment(\.clippyTokens) private var tokens
    @FocusState private var focused: Bool
    let title: String
    let systemImage: String
    let explanation: String
    let action: (() -> Void)?
    let state: ControlState

    /// Creates a non-accent reason chip from already-safe display text.
    init(title: String, systemImage: String = "info.circle", explanation: String? = nil, state: ControlState = .rest, action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.explanation = explanation ?? title
        self.state = state
        self.action = action
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
                    .focused($focused)
                    .disabled(state == .disabled)
            } else {
                label
            }
        }
        .help(explanation)
        .accessibilityLabel(title)
        .overlay { if focused || state == .focused { Capsule().strokeBorder(tokens.focusRing, lineWidth: 2).padding(-2) } }
    }

    private var label: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tokens.textSecondary)
            .padding(.horizontal, tokens.metrics.space.two)
            .padding(.vertical, tokens.metrics.space.one)
            .background(tokens.surfaceInset, in: Capsule())
            .opacity(state == .disabled ? 0.72 : 1)
    }
}
