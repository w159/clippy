import SwiftUI

/// Compact tray listing the queued paste-stack items (FEAT-06). Drag rows to
/// reorder, Delete removes the selected row, Return pastes the next item.
struct PasteStackTray: View {
    @Environment(\.clippyTokens) private var tokens
    @Bindable var stack: PasteStack
    /// Pastes the next item into the frontmost app.
    let onPasteNext: () -> Void
    @State private var selection: UUID?
    @State private var confirmClear = false

    init(stack: PasteStack = .shared, onPasteNext: @escaping () -> Void) {
        self.stack = stack
        self.onPasteNext = onPasteNext
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            if stack.items.isEmpty {
                PaneEmptyState(
                    systemImage: "tray", title: "Paste stack is empty",
                    message: stack.isCollecting
                        ? "Copy items to add them to the stack."
                        : "Turn on collecting, then copy items in the order you want to paste them.")
            } else {
                list
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Paste stack, \(CopyFormat.counted(stack.count, "item"))")
        .confirmationDialog("Clear the paste stack?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear \(CopyFormat.counted(stack.count, "Item"))", role: .destructive) { stack.clear(); selection = nil }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: tokens.metrics.space.two) {
            Toggle("Collect", isOn: $stack.isCollecting).toggleStyle(.switch).controlSize(.small)
                .help("While on, every new copy is added to the stack")
            Picker("Order", selection: $stack.order) {
                Text("First in, first out").tag(PasteStackOrder.fifo)
                Text("Last in, first out").tag(PasteStackOrder.lifo)
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            Spacer()
            Text("\(stack.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    IconButton("arrow.down.doc", label: "Paste next", help: "Paste the next item into the frontmost app") { onPasteNext() }
                        .disabled(stack.items.isEmpty)
                    IconButton("trash", label: "Clear stack", help: "Remove every item from the stack") { confirmClear = true }
                        .disabled(stack.items.isEmpty)
                }
            }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(Array(stack.items.enumerated()), id: \.element.id) { index, item in
                row(item, index: index).tag(item.id)
            }
            .onMove { stack.move(fromOffsets: $0, toOffset: $1) }
            .onDelete {
                let removedIDs = $0.compactMap { stack.items.indices.contains($0) ? stack.items[$0].id : nil }
                stack.remove(atOffsets: $0)
                if let selection, removedIDs.contains(selection) { self.selection = nil }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onDeleteCommand { if let selection { _ = stack.remove(id: selection); self.selection = nil } }
        .onKeyPress(.return) { onPasteNext(); return .handled }
        .onChange(of: stack.items.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    private func row(_ item: PasteStackItem, index: Int) -> some View {
        let isNext = stack.upcomingIndex == index
        return HStack(spacing: 10) {
            Image(systemName: Self.symbol(for: item.clip))
                .foregroundStyle(isNext ? Color.clippyAccent : Color.secondary)
                .frame(width: 28, height: 28)
                .background((isNext ? Color.clippyAccent : Color.secondary).opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(for: item.clip)).lineLimit(2).truncationMode(.tail)
                Text(isNext ? "Next to paste" : "Item \(index + 1)").font(.caption)
                    .foregroundStyle(isNext ? Color.clippyAccent : Color.secondary)
            }
            Spacer(minLength: 0)
            IconButton("xmark", label: "Remove from stack") {
                _ = stack.remove(id: item.id)
                if selection == item.id { selection = nil }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Item \(index + 1)\(isNext ? ", next" : ""): \(Self.title(for: item.clip))")
    }

    /// SF Symbol for the clip kind.
    static func symbol(for clip: Clip) -> String {
        switch clip.contentKind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    /// Row text: text preview, or a kind label for image/file clips.
    static func title(for clip: Clip) -> String {
        switch clip.contentKind {
        case .text: return clip.previewText.isEmpty ? "Text" : clip.previewText
        case .image: return "Image"
        case .file: return clip.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "File"
        }
    }
}
