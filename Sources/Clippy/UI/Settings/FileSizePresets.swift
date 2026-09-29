import Foundation

// SET-05: preset file-size steps for the size pickers.

/// Discrete MB steps offered instead of a free stepper.
enum FileSizePresets {
    /// Steps in MB, ascending.
    static let stepsMB: [Int] = [1, 5, 25, 100, 250, 500]

    /// Display label such as "25 MB".
    static func label(forMB value: Int) -> String { "\(value) MB" }

    /// The preset closest to `value` (ties go to the smaller step). Non-positive
    /// values map to the first step.
    static func nearest(toMB value: Int, steps: [Int] = stepsMB) -> Int {
        guard let first = steps.first else { return value }
        guard value > 0 else { return first }
        return steps.min { abs($0 - value) < abs($1 - value) } ?? first
    }

    /// Steps to show in a picker: presets, plus the stored value when it is not a
    /// preset, so an existing setting is never silently rewritten.
    static func options(including current: Int, steps: [Int] = stepsMB) -> [Int] {
        steps.contains(current) || current <= 0 ? steps : (steps + [current]).sorted()
    }
}
