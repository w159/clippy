import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Actions manager (shown inside Settings AI tab)

/// A list of all AI actions (built-in + custom) with full create/edit/delete
/// support. Built-ins are editable but non-deletable and restorable to defaults.
struct AIActionsManagerView: View {
    private let store = AIActionStore.shared
    private let settings = AppSettings.shared
    @State private var editingAction: AIAction?
    @State private var isCreating = false
    @State private var deletingAction: AIAction?
    @State private var draggingOverActionID: String?
    @State private var hoveredActionID: UUID?
    @State private var transferMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            listHeader
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
        HStack(spacing: 10) {
            Label("AI Actions", systemImage: "wand.and.sparkles")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        Button("Import actions\u{2026}", action: importActions)
                        Button("Export actions\u{2026}", action: exportActions)
                    } label: {
                        ChromeMenuLabel("Import / Export", systemImage: "square.and.arrow.up.on.square")
                    }
                    .chromeMenuStyle()
                    .fixedSize()
                    .accessibilityLabel("Import or export actions")
                    Button {
                        isCreating = true
                    } label: {
                        Label("New Action", systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Empty state

    private var emptyState: some View {
        PaneEmptyState(systemImage: "wand.and.sparkles", title: "No actions yet",
                   message: "Create an action to run a prompt on any clip.", actionTitle: "New Action") { isCreating = true }
    }

    // MARK: Action list

    private var actionList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
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
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
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
        HStack(spacing: 12) {
            ActionIconView(kind: action.iconKind, value: action.symbolName)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(action.name).font(.body.weight(.medium))
                    if action.isBuiltIn { ReasonChip(title: "Built-in", systemImage: "lock", explanation: "Built-in actions can be edited but not deleted.") }
                }
                Text(AIActionEditorSupport.dispositionBadge(action.outputDisposition))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Edit") { editingAction = action }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Edit \(action.name)")
                    if !action.isBuiltIn {
                        Button("Delete", role: .destructive) { deletingAction = action }
                            .buttonStyle(.glass)
                            .tint(.red)
                            .accessibilityLabel("Delete \(action.name)")
                    } else if action.isModifiedFromDefault {
                        Button("Restore") {
                            if var original = AIAction.builtIns.first(where: { $0.id == action.id }) {
                                // Keep the action's current position; the built-in template
                                // carries its original seed sortOrder which would otherwise
                                // reshuffle a list the user has reordered.
                                original.sortOrder = action.sortOrder
                                store.update(original)
                            }
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Restore \(action.name) to its default")
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(hoveredActionID == action.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hoveredActionID = $0 ? action.id : (hoveredActionID == action.id ? nil : hoveredActionID) }
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
