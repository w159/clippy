import SwiftUI

/// Sidebar section listing smart collections with counts. Embed it in the sidebar and filter History with
/// `selection.activeRule`. Reuses `SmartCollectionEditorSheet` for create/edit.
struct SmartCollectionsSidebarSection: View {
    @Environment(\.clippyTokens) private var tokens
    @ObservedObject var selection: SmartCollectionSelection
    @State private var editing: EditTarget?
    @State private var deleting: SmartCollection?

    /// Sheet target: new or existing collection.
    struct EditTarget: Identifiable {
        let id = UUID()
        var collection: SmartCollection?
    }

    /// Hidden when a collapsible header above already names the section.
    var showsTitle = true

    /// Creates the section on a selection model.
    init(selection: SmartCollectionSelection, showsTitle: Bool = true) {
        self.selection = selection
        self.showsTitle = showsTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            if showsTitle { Text("Smart collections").font(.caption.weight(.semibold)).foregroundStyle(tokens.textSecondary) }
            ForEach(selection.collections) { collection in row(collection) }
            Button { editing = EditTarget(collection: nil) } label: {
                Label("New smart collection", systemImage: "plus")
            }
            .buttonStyle(.plain).foregroundStyle(tokens.accentText).font(.callout)
        }
        .onAppear { selection.reload() }
        .sheet(item: $editing) { target in
            SmartCollectionEditorSheet(collection: target.collection) { selection.reload() }
        }
        .confirmationDialog("Delete this smart collection?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let id = deleting?.id { selection.delete(id) }; deleting = nil }
        } message: { Text("Only the rule is deleted. The clips stay in your history.") }
    }

    private func row(_ collection: SmartCollection) -> some View {
        let isSelected = collection.id == selection.selectedID
        return Button { if let id = collection.id { selection.toggle(id) } } label: {
            HStack {
                Image(systemName: "sparkles.rectangle.stack")
                Text(collection.name).lineLimit(1)
                Spacer()
                Text(collection.id.map(selection.countLabel(for:)) ?? "").font(.caption).monospacedDigit()
                    .foregroundStyle(tokens.textSecondary)
            }
            .padding(.vertical, 4).padding(.horizontal, tokens.metrics.space.one)
            .background(isSelected ? tokens.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(tokens.textPrimary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("Edit\u{2026}") { editing = EditTarget(collection: collection) }
            Button("Delete\u{2026}", role: .destructive) { deleting = collection }
        }
    }
}
