import SwiftUI

/// Inline rename for `ClipCardView`: the editable title field, its fill color and
/// the begin/commit/cancel handlers driven by the `isRenaming` binding.
extension ClipCardView {
    /// Inline rename field. The background is the standard editable-field color
    /// (white in light themes, dark in dark themes), which contrasts the card
    /// face so the field reads unmistakably as a text entry. Focus and full
    /// selection happen automatically via SelectAllTextField.
    var titleEditor: some View {
        SelectAllTextField(
            initialText: clip.userTitle ?? clip.displayTitle,
            font: PanelTypography.nsTitleFont(settings),
            textColor: NSColor(tokens.textPrimary),
            accessibilityLabel: "Rename clip",
            onCommit: { commitRename($0) },
            onCancel: { cancelRename() }
        )
        // minHeight, not a fixed height, so larger fonts are not clipped.
        .frame(minHeight: 18)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        // Opposite-luminance fill so the field never blends into the card:
        // a dark tint on light themes, a light tint on dark themes.
        .background(renameFieldFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(tokens.accent, lineWidth: 1.5)
        )
    }

    var renameFieldFill: Color {
        // Theme-derived fill so the rename field never relies on hardcoded
        // Color.white/Color.black (which bypassed the token system and could
        // break custom themes). Uses the primary text color at low opacity: on
        // dark themes textPrimary is light so the field reads as a light tint
        // on the dark card; on light themes textPrimary is dark so the field
        // reads as a dark tint on the light card. Opposite-luminance is
        // preserved without hardcoded Color literals.
        tokens.textPrimary.opacity(tokens.scheme == .dark ? 0.16 : 0.08)
    }

    func beginRename() {
        isRenaming = true
    }

    func commitRename(_ value: String) {
        isRenaming = false
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty, or unchanged-from-the-app-name, clears the custom title.
        if trimmed.isEmpty || trimmed == clip.sourceAppName {
            onRename(nil)
        } else {
            onRename(trimmed)
        }
    }

    func cancelRename() {
        isRenaming = false
    }
}
