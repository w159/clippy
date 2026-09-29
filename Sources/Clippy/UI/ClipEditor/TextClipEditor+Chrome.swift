import AppKit
import SwiftUI

// Footer and AI menu.
extension TextClipEditor {
    // MARK: Chrome

    var footer: some View {
        HStack {
            if let statusMessage {
                Text(statusMessage)
                    .font(PanelTypography.metadata(settings))
                    .foregroundStyle(tokens.accent)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .transition(.opacity)
            }
            if let saveError {
                // System red for the error state, mirroring the image editor;
                // ThemeTokens has no dedicated danger token.
                Text(saveError)
                    .font(PanelTypography.metadata(settings))
                    .foregroundStyle(dsTokens.danger)
                    .accessibilityLabel("Error: \(saveError)")
                    .lineLimit(2)
                    .layoutPriority(-1)
                    .help(saveError)
            }
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel) {
                if isDirty {
                    showingDiscardPrompt = true
                } else {
                    onClose()
                }
            }
            .keyboardShortcut(.cancelAction)
            .fixedSize()
            Button("Save") { if save() { onClose() } }
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                .disabled(!isDirty || clipDeleted)
            // Cmd-S save path. The NSTextView swallows Return, so the
            // .defaultAction shortcut above is unreachable while the body
            // editor has focus; the window still resolves this key
            // equivalent regardless of first responder.
            Button("") { if save() { onClose() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || clipDeleted)
                .hidden()
                .frame(width: 0, height: 0)
        }
        .padding(12)
    }

    /// Title field with the unsaved dot and the AI menu.
    var titleBar: some View {
        HStack(spacing: 8) {
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Clip title")
            if isDirty {
                HStack(spacing: 4) {
                    Circle().fill(dsTokens.accent).frame(width: 8, height: 8)
                    Text("unsaved").font(.caption).foregroundStyle(dsTokens.textSecondary)
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Unsaved changes")
                .help("Unsaved changes")
            }
            if settings.aiEnabled { aiMenu }
        }
        .padding(10)
    }

    /// Caret, counts, encoding, language and source.
    var statusBar: some View {
        EditorStatusBarView(
            snapshot: statusSnapshot, languageName: richMode ? "Rich Text" : language.displayName,
            wordCount: wordCount, sourceSummary: clip.sourceAppName.map { "Source: \($0)" },
            showsCaret: !richMode)
    }

    var aiMenu: some View {
        Menu {
            // Custom actions from the store - same execution path as ClipListView.
            ForEach(actionStore.actions) { action in
                Button {
                    runAction(action)
                } label: {
                    HStack {
                        ActionIconView(kind: action.iconKind, value: action.symbolName)
                        Text(action.name)
                    }
                }
            }
            if actionStore.actions.isEmpty {
                Text("No actions configured.")
            }
        } label: {
            Label("AI", systemImage: "sparkles")
        }
        // Native bordered pull-down so the menu reads as a control in a titled
        // editor rather than a borderless web-style affordance.
        .menuStyle(.button)
        .fixedSize()
    }
}
