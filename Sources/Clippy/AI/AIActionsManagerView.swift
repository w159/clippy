import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Actions manager (shown inside Settings AI tab)

/// A list of all AI actions (built-in + custom) with full create/edit/delete
/// support. Built-ins are editable but non-deletable and restorable to defaults.
struct AIActionsManagerView: View {
    @ObservedObject private var store = AIActionStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var editingAction: AIAction?
    @State private var isCreating = false
    @State private var deletingAction: AIAction?
    @State private var draggingOverActionID: String?
    @State private var transferMessage: String?

    @Environment(\.colorSchemeContrast) private var contrast

    /// Semantic tokens resolved from the current theme so rows keep AA contrast (AI-13).
    private var tokens: ClippyTokens { ClippyTokens.resolve(from: settings.theme, contrast: contrast) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            listHeader
            Divider()
            if store.actions.isEmpty {
                emptyState
            } else {
                actionList
            }
        }
        .alert("Actions", isPresented: Binding(
            get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(transferMessage ?? "")
        }
        .sheet(isPresented: $isCreating) {
            AIActionEditorView(action: nil) { newAction in
                store.add(newAction)
                isCreating = false
            } onCancel: {
                isCreating = false
            }
        }
        .sheet(item: $editingAction) { action in
            AIActionEditorView(action: action) { updated in
                store.update(updated)
                editingAction = nil
            } onCancel: {
                editingAction = nil
            }
        }
    }

    // MARK: Import / export

    private func exportActions() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clippy-actions.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AIActionTransfer.export(store.actions).write(to: url, options: .atomic)
        } catch {
            transferMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importActions() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try AIActionTransfer.importActions(from: Data(contentsOf: url))
            result.actions.forEach { store.add($0) }
            var message = "Imported \(result.actions.count) action(s)."
            if !result.skipped.isEmpty { message += " Skipped: " + result.skipped.joined(separator: "; ") + "." }
            transferMessage = message
        } catch {
            transferMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: Header

    private var listHeader: some View {
        HStack(spacing: tokens.metrics.space.two) {
            Text("AI Actions").font(.headline).foregroundStyle(tokens.textPrimary)
            Spacer()
            Menu {
                Button("Import actions...", action: importActions)
                Button("Export actions...", action: exportActions)
            } label: {
                Label("Import / Export", systemImage: "square.and.arrow.up.on.square")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Import or export actions")
            Button {
                isCreating = true
            } label: {
                Label("New Action", systemImage: "plus")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(tokens.accent)
        }
        .padding(.horizontal, tokens.metrics.space.three)
        .padding(.vertical, tokens.metrics.space.two)
    }

    // MARK: Empty state

    private var emptyState: some View {
        EmptyState(systemImage: "wand.and.sparkles", title: "No actions yet",
                   message: "Create an action to run a prompt on any clip.", actionTitle: "New Action") { isCreating = true }
    }

    // MARK: Action list

    private var actionList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(store.actions) { action in
                    actionRow(action)
                        .reorderDraggable(id: action.id.uuidString)
                        .reorderDropDestination(
                            id: action.id.uuidString,
                            draggingOver: $draggingOverActionID
                        ) { draggedStr, targetStr in
                            if let draggedID = UUID(uuidString: draggedStr),
                               let targetID = UUID(uuidString: targetStr) {
                                store.moveAction(draggedID: draggedID, before: targetID)
                            }
                        }
                }
            }
            .padding(8)
        }
        .confirmationDialog(
            "Delete \"\(deletingAction?.name ?? "")\"?",
            isPresented: Binding(
                get: { deletingAction != nil },
                set: { if !$0 { deletingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let action = deletingAction { store.delete(id: action.id) }
                deletingAction = nil
            }
            Button("Cancel", role: .cancel) { deletingAction = nil }
        } message: {
            Text("This action cannot be recovered.")
        }
    }

    private func actionRow(_ action: AIAction) -> some View {
        HStack(spacing: tokens.metrics.space.three) {
            ActionIconView(kind: action.iconKind, value: action.symbolName)
                .frame(width: 22)
                .foregroundStyle(tokens.accentText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: tokens.metrics.space.two) {
                    Text(action.name).font(.body.weight(.medium)).foregroundStyle(tokens.textPrimary)
                    if action.isBuiltIn { ReasonChip(title: "Built-in", systemImage: "lock", explanation: "Built-in actions can be edited but not deleted.") }
                }
                Text(AIActionEditorSupport.dispositionBadge(action.outputDisposition))
                    .font(.caption).foregroundStyle(tokens.textSecondary)
            }
            Spacer()
            Button("Edit") { editingAction = action }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Edit \(action.name)")
            if !action.isBuiltIn {
                Button("Delete", role: .destructive) { deletingAction = action }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(tokens.danger)
                    .accessibilityLabel("Delete \(action.name)")
            } else {
                Button("Restore") {
                    if var original = AIAction.builtIns.first(where: { $0.id == action.id }) {
                        // Keep the action's current position; the built-in template
                        // carries its original seed sortOrder which would otherwise
                        // reshuffle a list the user has reordered.
                        original.sortOrder = action.sortOrder
                        store.update(original)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Restore \(action.name) to its default")
            }
        }
        .padding(.horizontal, tokens.metrics.space.three)
        .padding(.vertical, tokens.metrics.space.two)
        .background(tokens.surfaceElevated, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
        .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm).strokeBorder(tokens.stroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .help(dispositionHelp(for: action.outputDisposition))
    }

    private func dispositionHelp(for disposition: AIActionOutputDisposition) -> String {
        switch disposition {
        case .proposeEdit:
            return "Propose Edit: shows a before/after diff and asks you to confirm before overwriting."
        case .newClip:
            return "New Clip: inserts the result as a new clip in your history."
        case .copyToClipboard:
            return "Copy to Clipboard: copies the result directly to the clipboard."
        }
    }
}
