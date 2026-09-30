import Foundation
import Combine

@MainActor
final class ModelBrowserViewModel: ObservableObject {
    @Published var models: [ModelInfo] = []
    @Published var filter = ModelFilter()
    @Published var sortOrder = [ModelSort()]
    @Published var selection: String?
    @Published var customModel: String
    @Published var loading = false
    @Published var error: String?
    @Published var measuring = false
    @Published var measurementError: String?
    @Published var visibleColumns = Set(ModelColumn.allCases)
    let providerID: UUID
    var onSelect: @MainActor (String) -> Void
    var onClose: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?
    private var measurementTask: Task<Void, Never>?
    private var endpointTask: Task<Void, Never>?
    private var generation = UUID()

    init(providerID: UUID, currentModel: String, onSelect: @escaping @MainActor (String) -> Void) {
        self.providerID = providerID
        self.customModel = currentModel
        self.selection = currentModel
        self.onSelect = onSelect
    }

    var rows: [ModelInfo] { models.filter { filter.matches($0) }.sorted(using: sortOrder) }
    var selectedID: String { customModel.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Columns the user enabled AND for which the provider reported something.
    var shownColumns: [ModelColumn] {
        ModelColumn.allCases.filter { $0 != .name && visibleColumns.contains($0) && $0.hasData(in: models) }
    }
    var selected: ModelInfo? { models.first { $0.id == selection } }
    var catalogNote: String {
        if models.contains(where: { $0.source.contains("base models, not") }) {
            return "Azure lists base models, not deployment aliases. Enter your deployment name below; ARM discovery requires separate management credentials."
        }
        if !models.isEmpty, !ModelColumn.allCases.contains(where: { $0 != .name && $0 != .source && $0.hasData(in: models) }) {
            return "This provider returns model ids only or limited metadata. Unknown values are shown as —; no limits, prices or speed are inferred from names."
        }
        return "Prices: USD per million tokens. — means the provider did not report a value. Speed is unknown until published or explicitly measured."
    }

    /// Model discovery must work with AI disabled, no selected model, and public catalogs
    /// without a key. Do not call inference resolution (which validates those prerequisites).
    func resolved() throws -> ResolvedProvider {
        let resolved = try AIProviderStore.shared.resolveForModels(providerID).get()
        if resolved.keychainDeniedStatus != nil, resolved.descriptor.models?.needsAuth == true {
            throw ModelCatalogError.transport("Unlock the Keychain or re-enter the provider key.")
        }
        return resolved
    }

    func load(refresh: Bool = false) {
        task?.cancel()
        generation = UUID()
        let current = generation
        loading = true
        error = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let target = try resolved()
                let list = try await ModelCatalogService.fetch(target, refresh: refresh)
                guard !Task.isCancelled, generation == current else { return }
                models = list
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    func selectionChanged() {
        guard let selection else { return }
        customModel = selection
        endpointTask?.cancel()
        guard let row = selected, let target = try? resolved(),
              target.descriptor.models?.parser == .openRouter, !target.apiKey.isEmpty else { return }
        endpointTask = Task { [weak self] in
            guard let enriched = try? await ModelCatalogService.enrichEndpoint(row, resolved: target),
                  !Task.isCancelled, let self,
                  let index = models.firstIndex(where: { $0.id == row.id }) else { return }
            models[index] = enriched
        }
    }

    func select() {
        guard !selectedID.isEmpty else { return }
        onSelect(selectedID)
        onClose?()
    }

    func measure() {
        guard !selectedID.isEmpty, let target = try? resolved() else { return }
        measurementTask?.cancel()
        measuring = true
        measurementError = nil
        let modelID = selectedID
        measurementTask = Task { [weak self] in
            let result = await ModelLatencyProbe.measure(target, model: modelID)
            guard !Task.isCancelled, let self else { return }
            if let index = models.firstIndex(where: { $0.id == modelID }) {
                models[index].ttftMs = result.ttftMs
                models[index].tokensPerSec = result.tokensPerSec
                models[index].source += "; measured on this Mac \(result.measuredAt.formatted(date: .omitted, time: .shortened))"
            }
            measurementError = result.error
            measuring = false
        }
    }

    func cancel() {
        task?.cancel()
        endpointTask?.cancel()
        measurementTask?.cancel()
        generation = UUID()
    }
}
