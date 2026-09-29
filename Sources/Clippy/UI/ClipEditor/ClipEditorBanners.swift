import SwiftUI

// MARK: - Banners

/// Shown when the stored clip changed under unsaved edits (EDT-02): Reload, Keep mine, Compare.
struct EditorConflictBanner: View {
    @Environment(\.clippyTokens) private var tokens
    let onReload: () -> Void
    let onKeepMine: () -> Void
    let onCompare: () -> Void

    init(onReload: @escaping () -> Void, onKeepMine: @escaping () -> Void, onCompare: @escaping () -> Void) {
        self.onReload = onReload
        self.onKeepMine = onKeepMine
        self.onCompare = onCompare
    }

    var body: some View {
        HStack(spacing: tokens.metrics.space.two) {
            Image(systemName: BannerSeverity.warning.symbol).foregroundStyle(tokens.warning).accessibilityHidden(true)
            Text("This clip changed elsewhere (external editor or another app).")
                .font(.callout).foregroundStyle(tokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: tokens.metrics.space.two)
            Button("Reload", action: onReload).help("Discard your edits and load the stored text").fixedSize()
            Button("Keep mine", action: onKeepMine).help("Keep your edits; Save overwrites the stored text").fixedSize()
            Button("Compare...", action: onCompare).help("Show both versions side by side").fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(tokens.metrics.space.two)
        .background(tokens.warning.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(tokens.warning.opacity(0.35)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conflict: this clip changed elsewhere")
    }
}

/// Shown when the edited clip was deleted while the editor was open.
struct EditorDeletedBanner: View {
    /// Recovery: put the edited text on the pasteboard before closing.
    var onCopy: (() -> Void)?

    var body: some View {
        ClippyBanner("This clip was deleted. Your edits can no longer be saved.", severity: .danger,
                     actionTitle: onCopy == nil ? nil : "Copy text", action: onCopy)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }
}

/// AI staging tray: side effects awaiting Save, each a dismissible chip (EDT-09).
struct EditorPendingBar: View {
    @Environment(\.clippyTokens) private var tokens
    let effects: [PendingEffect]
    let onDismiss: (PendingEffect) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            Label("Staged for Save", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tokens.textSecondary)
            HStack(spacing: tokens.metrics.space.two) {
                ForEach(effects) { effect in
                    HStack(spacing: 4) {
                        ReasonChip(title: effect.label, systemImage: "sparkles")
                        IconButton("xmark.circle", label: "Discard staged action: \(effect.label)", help: "Discard") {
                            onDismiss(effect)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(tokens.metrics.space.two)
        .background(tokens.surfaceInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Staged AI actions")
    }
}
