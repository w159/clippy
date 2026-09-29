import Foundation

/// Hard limits that keep every local transform bounded in time and memory.
enum TransformLimits {
    /// Largest input, in UTF-8 bytes, any transform accepts.
    static let maxInputBytes = 2_000_000
    /// Characters kept on each side of a `TransformPreview`.
    static let previewCharacters = 400
}

/// Why a transform could not produce output.
enum TransformError: Error, Equatable, LocalizedError {
    /// The input is not valid for the transform. `line`/`column` are 1-based when known.
    case invalidInput(reason: String, line: Int?, column: Int?)
    /// The input exceeds `TransformLimits.maxInputBytes`.
    case inputTooLarge(bytes: Int)
    /// A regex pattern was rejected or exceeded its time/match budget.
    case unsafePattern(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let reason, let line, let column):
            if let line, let column { return "\(reason) (line \(line), column \(column))" }
            return reason
        case .inputTooLarge(let bytes):
            return "The text is too large to transform (\(bytes) bytes)."
        case .unsafePattern(let reason):
            return reason
        }
    }

    /// Convenience for errors without a position.
    static func invalid(_ reason: String) -> TransformError { .invalidInput(reason: reason, line: nil, column: nil) }
}

/// A bounded before/after rendering of one transform on one input.
struct TransformPreview: Equatable {
    /// The (possibly truncated) input.
    let before: String
    /// The (possibly truncated) output, or the error message when `error` is set.
    let after: String
    /// True when either side was cut to `TransformLimits.previewCharacters`.
    let isTruncated: Bool
    /// The failure, when the transform threw.
    let error: TransformError?
}

/// Broad grouping used by the picker.
enum TransformCategory: String, CaseIterable {
    case textCase = "Case"
    case cleanup = "Cleanup"
    case json = "JSON"
    case encoding = "Encoding"
    case hash = "Hashes"
    case lines = "Lines"
    case extract = "Extract"
    case regex = "Regex"
    case date = "Date"
}

/// A pure, local, deterministic text transform.
protocol TextTransform: Sendable {
    /// Stable identifier.
    var id: String { get }
    /// Name shown in the picker.
    var title: String { get }
    /// Grouping.
    var category: TransformCategory { get }
    /// Extra search terms.
    var keywords: [String] { get }
    /// Transforms `input`; throws `TransformError` on invalid or oversized input.
    func transform(_ input: String) throws -> String
}

extension TextTransform {
    var keywords: [String] { [] }

    /// Runs `transform` after enforcing the global input cap.
    func apply(_ input: String) throws -> String {
        let bytes = input.utf8.count
        guard bytes <= TransformLimits.maxInputBytes else { throw TransformError.inputTooLarge(bytes: bytes) }
        return try transform(input)
    }

    /// Bounded before/after diff; never throws (failures are folded into the preview).
    func preview(for input: String) -> TransformPreview {
        let cap = TransformLimits.previewCharacters
        let before = Self.clip(input, to: cap)
        do {
            let output = try apply(input)
            let after = Self.clip(output, to: cap)
            return TransformPreview(before: before.text, after: after.text,
                                    isTruncated: before.cut || after.cut, error: nil)
        } catch let failure as TransformError {
            return TransformPreview(before: before.text, after: failure.errorDescription ?? "Failed",
                                    isTruncated: before.cut, error: failure)
        } catch {
            return TransformPreview(before: before.text, after: error.localizedDescription,
                                    isTruncated: before.cut, error: .invalid(error.localizedDescription))
        }
    }

    /// Cuts `text` to `limit` characters without copying the whole string.
    static func clip(_ text: String, to limit: Int) -> (text: String, cut: Bool) {
        guard let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex),
              end != text.endIndex else { return (text, false) }
        return (String(text[..<end]) + "…", true)
    }
}

/// Closure-backed transform used for the simple built-ins.
struct FunctionTransform: TextTransform {
    let id: String
    let title: String
    let category: TransformCategory
    let keywords: [String]
    private let body: @Sendable (String) throws -> String

    /// Creates a transform from a throwing closure.
    init(id: String, title: String, category: TransformCategory, keywords: [String] = [],
         body: @escaping @Sendable (String) throws -> String) {
        self.id = id
        self.title = title
        self.category = category
        self.keywords = keywords
        self.body = body
    }

    func transform(_ input: String) throws -> String { try body(input) }
}

/// Catalogue of every built-in transform.
enum TransformRegistry {
    /// All transforms in picker order.
    static let all: [any TextTransform] =
        CaseTransforms.all + CleanupTransforms.all + EncodingTransforms.all + HashTransforms.all
        + LineTransforms.all + ExtractTransforms.all

    /// The transform with `id`, if any.
    static func transform(id: String) -> (any TextTransform)? { all.first { $0.id == id } }

    /// Transforms whose title, category or keywords contain every word of `query`.
    static func search(_ query: String) -> [any TextTransform] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { item in
            let haystack = ([item.title, item.category.rawValue, item.id] + item.keywords).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
