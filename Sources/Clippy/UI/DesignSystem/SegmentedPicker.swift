import SwiftUI

/// A typed option for the segmented control.
struct SegmentOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var systemImage: String? = nil
    var id: Value { value }
}

/// Segmented picker drawn from tokens. The native `.segmented` style paints a white label on the
/// tint (about 2.2:1 on the gold accent). Here the selected segment is `tokens.accent` with
/// `tokens.onAccent` (AA by construction) and the rest are secondary text on an inset surface.
/// Each segment is a real Button, so keyboard activation and VoiceOver (label + selected trait) work.
struct ClippySegmentedPicker<Value: Hashable>: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Binding private var selection: Value
    private let options: [SegmentOption<Value>]
    private let label: String
    private let disabled: Bool

    /// Creates a two-to-four-option segmented picker.
    init(_ label: String, selection: Binding<Value>, options: [SegmentOption<Value>], disabled: Bool = false) {
        self.label = label
        self._selection = selection
        self.options = options
        self.disabled = disabled
    }

    var body: some View {
        let small = controlSize == .small || controlSize == .mini
        let radius = tokens.metrics.radius.control
        HStack(spacing: 2) {
            ForEach(options) { option in
                segment(option, small: small, radius: radius - 2)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tokens.surfaceInset))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(tokens.stroke, lineWidth: 1))
        .opacity(isEnabled && !disabled ? 1 : 0.45)
        .disabled(disabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(_ option: SegmentOption<Value>, small: Bool, radius: CGFloat) -> some View {
        let isSelected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            Group {
                if let symbol = option.systemImage {
                    Label(option.title, systemImage: symbol)
                } else {
                    Text(option.title)
                }
            }
            .font(.system(size: small ? 11 : 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? tokens.onAccent : tokens.textSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, small ? 8 : 10)
            .padding(.vertical, small ? 2 : 4)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(isSelected ? tokens.accent : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
