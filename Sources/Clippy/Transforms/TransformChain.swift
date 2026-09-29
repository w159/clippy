import Foundation

/// An ordered pipeline of transforms; each step receives the previous step's output.
struct TransformChain {
    /// Outcome of running a chain.
    struct Result: Equatable {
        /// Output after each completed step (one entry per step that succeeded).
        let intermediates: [String]
        /// Index of the step that threw, if any.
        let failedStep: Int?
        /// The failure, if any.
        let error: TransformError?

        /// Final text, or nil when a step failed.
        var output: String? { failedStep == nil ? (intermediates.last) : nil }
    }

    /// Steps in execution order.
    var steps: [any TextTransform]

    /// Creates a chain.
    init(steps: [any TextTransform] = []) { self.steps = steps }

    /// Creates a chain from registry ids; unknown ids are skipped.
    init(ids: [String]) { self.steps = ids.compactMap { TransformRegistry.transform(id: $0) } }

    /// Runs every step; stops at the first failure. An empty chain returns the input unchanged.
    func run(_ input: String) -> Result {
        var current = input
        var outputs: [String] = []
        for (index, step) in steps.enumerated() {
            do {
                current = try step.apply(current)
                outputs.append(current)
            } catch let failure as TransformError {
                return Result(intermediates: outputs, failedStep: index, error: failure)
            } catch {
                return Result(intermediates: outputs, failedStep: index, error: .invalid(error.localizedDescription))
            }
        }
        return Result(intermediates: steps.isEmpty ? [input] : outputs, failedStep: nil, error: nil)
    }

    /// Bounded before/after preview of the whole chain.
    func preview(for input: String) -> TransformPreview {
        let cap = TransformLimits.previewCharacters
        let before = FunctionTransform.clip(input, to: cap)
        let result = run(input)
        if let error = result.error {
            return TransformPreview(before: before.text, after: error.errorDescription ?? "Failed", isTruncated: before.cut, error: error)
        }
        let after = FunctionTransform.clip(result.output ?? input, to: cap)
        return TransformPreview(before: before.text, after: after.text, isTruncated: before.cut || after.cut, error: nil)
    }
}
