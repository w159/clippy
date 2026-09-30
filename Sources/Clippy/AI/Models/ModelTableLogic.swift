import Foundation

struct ModelFilter: Sendable, Equatable {
    var search = ""
    var tools = false
    var vision = false
    var reasoning = false
    var free = false
    var loaded = false
    var minimumContext = 0

    func matches(_ model: ModelInfo) -> Bool {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (term.isEmpty || model.id.localizedCaseInsensitiveContains(term)
                || model.displayName.localizedCaseInsensitiveContains(term))
            && (!tools || model.supportsTools == true)
            && (!vision || model.supportsVision == true)
            && (!reasoning || model.supportsReasoning == true)
            && (!free || model.isFree)
            && (!loaded || model.isLoaded == true)
            && (minimumContext == 0 || (model.contextLength ?? 0) >= minimumContext)
    }
}

enum ModelColumn: String, CaseIterable, Identifiable, Sendable {
    case name, context, maxOutput, inputPrice, outputPrice, modalities, tools, reasoning
    case size, quantization, released, ttft, throughput, source
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .context: return "Context"
        case .maxOutput: return "Max output"
        case .inputPrice: return "$/M in"
        case .outputPrice: return "$/M out"
        case .modalities: return "Modalities"
        case .tools: return "Tools"
        case .reasoning: return "Reasoning"
        case .size: return "Size / params"
        case .quantization: return "Quantization"
        case .released: return "Released"
        case .ttft: return "TTFT (ms)"
        case .throughput: return "tok/s"
        case .source: return "Source"
        }
    }
    /// Token counts as 8.2K / 128K / 1.05M (decimal thousands, as providers quote them).
    static func compactCount(_ value: Int) -> String {
        func trim(_ amount: Double, _ digits: Int) -> String {
            var text = String(format: "%.\(digits)f", amount)
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return text
        }
        if value >= 1_000_000 { return trim(Double(value) / 1_000_000, 2) + "M" }
        if value >= 100_000 { return trim(Double(value) / 1_000, 0) + "K" }
        if value >= 1_000 { return trim(Double(value) / 1_000, 1) + "K" }
        return String(value)
    }

    /// True when at least one row has a real value; all-unknown columns are hidden by the browser.
    func hasData(in models: [ModelInfo]) -> Bool {
        self == .name || self == .source || models.contains { text($0) != "—" }
    }

    func text(_ model: ModelInfo) -> String {
        switch self {
        case .name: return model.displayName
        case .context: return model.contextLength.map(ModelColumn.compactCount) ?? "—"
        case .maxOutput: return model.maxOutput.map(ModelColumn.compactCount) ?? "—"
        case .inputPrice: return model.promptPricePerM.map { String(format: "$%.4g", $0) } ?? "—"
        case .outputPrice: return model.completionPricePerM.map { String(format: "$%.4g", $0) } ?? "—"
        case .modalities: return model.inputModalities.isEmpty && model.outputModalities.isEmpty ? "—"
                : "\(model.inputModalities.joined(separator: ", ")) → \(model.outputModalities.joined(separator: ", "))"
        case .tools: return model.supportsTools.map { $0 ? "Yes" : "No" } ?? "—"
        case .reasoning: return model.supportsReasoning.map { $0 ? "Yes" : "No" } ?? "—"
        case .size: return model.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                ?? model.parameterSize ?? "—"
        case .quantization: return model.quantization ?? "—"
        case .released: return model.created.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
        case .ttft: return model.ttftMs.map { String(format: "%.0f", $0) } ?? "—"
        case .throughput: return model.tokensPerSec.map { String(format: "%.1f", $0) } ?? "—"
        case .source: return model.source
        }
    }
}

struct ModelSort: SortComparator, Sendable {
    var column: ModelColumn = .name
    var order: SortOrder = .forward

    /// Optional comparator deliberately keeps nil last regardless of direction.
    static func optional<T: Comparable>(_ left: T?, _ right: T?, order: SortOrder) -> ComparisonResult {
        switch (left, right) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (.some(let leftValue), .some(let rightValue)):
            if leftValue == rightValue { return .orderedSame }
            let before = order == .forward ? leftValue < rightValue : leftValue > rightValue
            return before ? .orderedAscending : .orderedDescending
        }
    }

    func compare(_ lhs: ModelInfo, _ rhs: ModelInfo) -> ComparisonResult {
        switch column {
        case .context: return Self.optional(lhs.contextLength, rhs.contextLength, order: order)
        case .maxOutput: return Self.optional(lhs.maxOutput, rhs.maxOutput, order: order)
        case .inputPrice: return Self.optional(lhs.promptPricePerM, rhs.promptPricePerM, order: order)
        case .outputPrice: return Self.optional(lhs.completionPricePerM, rhs.completionPricePerM, order: order)
        case .tools: return Self.optional(lhs.supportsTools.map { $0 ? 1 : 0 }, rhs.supportsTools.map { $0 ? 1 : 0 }, order: order)
        case .reasoning: return Self.optional(lhs.supportsReasoning.map { $0 ? 1 : 0 }, rhs.supportsReasoning.map { $0 ? 1 : 0 }, order: order)
        case .size: return Self.optional(lhs.sizeBytes, rhs.sizeBytes, order: order)
        case .released: return Self.optional(lhs.created, rhs.created, order: order)
        case .ttft: return Self.optional(lhs.ttftMs, rhs.ttftMs, order: order)
        case .throughput: return Self.optional(lhs.tokensPerSec, rhs.tokensPerSec, order: order)
        case .quantization: return Self.optional(lhs.quantization, rhs.quantization, order: order)
        case .modalities:
            return Self.optional(lhs.inputModalities.isEmpty && lhs.outputModalities.isEmpty ? nil : column.text(lhs),
                                 rhs.inputModalities.isEmpty && rhs.outputModalities.isEmpty ? nil : column.text(rhs), order: order)
        default:
            let result = column.text(lhs).localizedStandardCompare(column.text(rhs))
            if order == .forward { return result }
            return result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
        }
    }
}
