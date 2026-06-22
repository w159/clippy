import SwiftUI

/// Popover for creating or editing a category: name, color, and an icon
/// chosen from curated SF Symbols, an emoji grid, or app logos already seen
/// in the user's history.
struct CategoryEditorView: View {
    /// nil means "create new".
    let category: Category?
    /// Bundle IDs with icons available, for the App logos tab.
    let knownBundleIDs: [String]
    /// Existing category names, used to warn on duplicates. Defaults to empty
    /// so callers that do not supply a list compile unchanged; the side pane
    /// passes `store.categories.map { $0.name }`.
    let existingNames: [String]
    let onSave: (_ name: String, _ colorHex: String, _ iconKind: CategoryIconKind, _ iconValue: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorHex: String
    @State private var iconKind: CategoryIconKind
    @State private var iconValue: String

    init(
        category: Category?,
        knownBundleIDs: [String],
        existingNames: [String] = [],
        onSave: @escaping (String, String, CategoryIconKind, String) -> Void
    ) {
        self.category = category
        self.knownBundleIDs = knownBundleIDs
        self.existingNames = existingNames
        self.onSave = onSave
        _name = State(initialValue: category?.name ?? "")
        _colorHex = State(initialValue: category?.colorHex ?? CategoryPalette.hexes[0])
        _iconKind = State(initialValue: category?.iconKind ?? .symbol)
        _iconValue = State(initialValue: category?.iconValue ?? "pin.fill")
    }

    /// Audit finding: duplicate category names make AI Suggest Category
    /// ambiguous. The trimmed name is a duplicate when it case-insensitively
    /// matches an existing name other than this category's own (so editing a
    /// category and keeping its name does not trigger the warning).
    private var duplicateNameMessage: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let collides = existingNames.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        let isOwnName = (category?.name ?? "").caseInsensitiveCompare(trimmed) == .orderedSame
        return (collides && !isOwnName)
            ? "A category named \"\(trimmed)\" already exists."
            : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Category name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
                          duplicateNameMessage == nil else { return }
                    onSave(name.trimmingCharacters(in: .whitespaces), colorHex, iconKind, iconValue)
                    dismiss()
                }

            // Audit finding: warn on duplicate category names.
            if let message = duplicateNameMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Warning: \(message)")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Array(CategoryPalette.hexes.enumerated()), id: \.element) { index, hex in
                        colorSwatch(hex, index: index + 1)
                    }
                    // Audit finding: palette was limited to 10 fixed swatches.
                    // A Custom swatch opens the system color picker; the chosen
                    // color is written back to colorHex as "#RRGGBB".
                    customColorSwatch
                }
            }

            IconPickerView(
                iconKind: $iconKind,
                iconValue: $iconValue,
                knownBundleIDs: knownBundleIDs,
                accentHex: colorHex
            )

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(category == nil ? "Create" : "Save") {
                    onSave(
                        name.trimmingCharacters(in: .whitespaces),
                        colorHex,
                        iconKind,
                        iconValue
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || duplicateNameMessage != nil)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func colorSwatch(_ hex: String, index: Int) -> some View {
        let isSelected = colorHex == hex
        return Button {
            colorHex = hex
        } label: {
            Circle()
                .fill(Color(hexString: hex))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.primary.opacity(isSelected ? 0.7 : 0), lineWidth: 2))
        }
        .buttonStyle(.plain)
        // Audit finding: swatches did not expose selected state for a11y.
        // Add the isSelected trait and a label that includes the hex so
        // VoiceOver announces both the position and the concrete value.
        .accessibilityLabel("Color \(index), \(hex)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// "Custom..." swatch backed by the system ColorPicker. The binding converts
    /// between the persisted hex string and the SwiftUI Color used by the picker.
    private var customColorSwatch: some View {
        let isInPalette = CategoryPalette.hexes.contains(colorHex.uppercased())
        return ColorPicker(
            "Custom",
            selection: Binding(
                get: { Color(hexString: colorHex) },
                set: { colorHex = $0.themeHexString }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .accessibilityLabel("Custom color, \(colorHex)")
        .accessibilityAddTraits(!isInPalette ? .isSelected : [])
    }

}
