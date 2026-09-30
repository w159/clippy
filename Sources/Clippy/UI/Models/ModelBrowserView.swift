import SwiftUI

struct ModelBrowserView: View {
    @ObservedObject var model: ModelBrowserViewModel
    @Environment(\.clippyTokens) private var tokens
    @FocusState private var searchFocused: Bool
    @State private var confirmMeasure = false

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.two) {
            toolbar
            filters
            Text(model.catalogNote).font(.caption).foregroundStyle(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            catalog
            if let selected = model.selected {
                Text("\(selected.id) · \(selected.source)").font(.caption).foregroundStyle(tokens.textSecondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.measurementError { Text(error).font(.caption).foregroundStyle(tokens.textSecondary) }
            footer
        }
        .padding(tokens.metrics.space.four)
        .foregroundStyle(tokens.textPrimary)
        .frame(minWidth: 720, minHeight: 440)
        .background(tokens.surface)
        .preferredColorScheme(tokens.legacy.isDark ? .dark : .light)
        .background {
            Button("Focus filter") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .onAppear { model.load() }
        .onChange(of: model.selection) { _, _ in model.selectionChanged() }
        .onExitCommand { model.onClose?() }
        .confirmationDialog("Measure this model's latency?", isPresented: $confirmMeasure) {
            Button("Send a small inference request") { model.measure() }
        } message: {
            Text("This sends a short prompt to \(model.selectedID). Remote providers may charge for it. It measures TTFT on this Mac and throughput only when token usage is reported.")
        }
    }

    private var toolbar: some View {
        HStack {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            TextField("Filter by name or model id", text: $model.filter.search)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .accessibilityLabel("Filter models by name or identifier")
            Button { model.load(refresh: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Menu("Columns") {
                ForEach(ModelColumn.allCases.filter { $0 != .name }) { column in
                    Toggle(column.title, isOn: Binding(
                        get: { model.visibleColumns.contains(column) },
                        set: { visible in
                            if visible { model.visibleColumns.insert(column) }
                            else { model.visibleColumns.remove(column) }
                        }))
                }
            }
        }
    }

    private var filters: some View {
        HStack(spacing: tokens.metrics.space.two) {
            chip("Tools", key: \.tools)
            chip("Vision", key: \.vision)
            chip("Reasoning", key: \.reasoning)
            chip("Free", key: \.free)
            chip("Loaded", key: \.loaded)
            Picker("Context ≥", selection: $model.filter.minimumContext) {
                Text("Any context").tag(0)
                Text("32K+").tag(32_000)
                Text("128K+").tag(128_000)
                Text("1M+").tag(1_000_000)
            }.frame(maxWidth: 180).accessibilityLabel("Minimum model context length")
            Spacer()
            Text("\(model.rows.count) models").font(.caption).foregroundStyle(tokens.textSecondary)
        }
    }

    private func chip(_ title: String, key: WritableKeyPath<ModelFilter, Bool>) -> some View {
        FilterChip(model: FilterChipModel(id: title, title: title),
                   state: model.filter[keyPath: key] ? .selected : .rest) {
            model.filter[keyPath: key].toggle()
        }.accessibilityLabel("Filter: \(title)")
    }

    @ViewBuilder private var catalog: some View {
        if model.loading {
            LoadingState("Loading provider models", rows: 5)
        } else if let error = model.error {
            ErrorState(title: "Could not load models", message: error) { model.load(refresh: true) }
        } else if model.rows.isEmpty {
            EmptyState(systemImage: "cpu",
                       title: model.models.isEmpty ? "Provider returned no models" : "No models match",
                       message: model.models.isEmpty
                           ? "Refresh the catalog, or enter a custom model id below."
                           : "Clear the filters, refresh the provider catalog, or enter a custom model id below.")
        } else {
            table
        }
    }

    private static func idealWidth(_ column: ModelColumn) -> CGFloat {
        switch column {
        case .source: return 130
        case .modalities: return 150
        case .size, .quantization, .released: return 100
        case .maxOutput, .reasoning: return 85
        default: return 65
        }
    }

    private var table: some View {
        Table(of: ModelInfo.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", sortUsing: ModelSort(column: .name)) { row in
                VStack(alignment: .leading) {
                    Text(row.displayName).lineLimit(1)
                    if row.displayName != row.id { Text(row.id).font(.caption).foregroundStyle(tokens.textSecondary).lineLimit(1) }
                }.help(row.id).accessibilityLabel("Model: \(row.displayName), identifier \(row.id)")
            }.width(min: 170, ideal: 200)
            TableColumnForEach(model.shownColumns) { column in
                TableColumn(column.title, sortUsing: ModelSort(column: column)) { row in
                    Text(column.text(row)).lineLimit(1)
                        .help(column.text(row))
                        .accessibilityLabel("\(column.title): \(column.text(row) == "—" ? "unknown" : column.text(row))")
                }.width(min: 60, ideal: Self.idealWidth(column))
            }
        } rows: {
            ForEach(model.rows) { row in
                TableRow(row).contextMenu {
                    Button("Select \(row.id)") { model.customModel = row.id; model.select() }
                    Button("Measure latency…") { model.selection = row.id; model.customModel = row.id; confirmMeasure = true }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { selected in
            if let first = selected.first { model.customModel = first; model.select() }
        }
        .accessibilityLabel("Provider model catalog; select a model row")
    }

    private var footer: some View {
        HStack(spacing: tokens.metrics.space.two) {
            TextField("Custom model or Azure deployment id", text: $model.customModel)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Model identifier; custom ids are allowed")
                .onSubmit { model.select() }
            Button(model.measuring ? "Measuring…" : "Measure latency…") { confirmMeasure = true }
                .disabled(model.selectedID.isEmpty || model.measuring)
            Button("Cancel") { model.onClose?() }.keyboardShortcut(.cancelAction)
            Button("Select") { model.select() }.keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(tokens.accent).disabled(model.selectedID.isEmpty)
        }
    }
}
