import Foundation
import os

/// `UserDefaults` is documented as safe to use from any thread ("you can use a
/// defaults object from any thread"), but the SDK does not declare it `Sendable`.
/// This retroactive conformance states the documented guarantee once so defaults
/// can be captured by `@Sendable` closures and stored in locks.
extension UserDefaults: @retroactive @unchecked Sendable {}

/// A process-wide `UserDefaults` seam: production code reads `.standard`, tests
/// swap in a throwaway suite. The lock lets any thread read while a test (or
/// startup) replaces it, so the seam is not a bare mutable global.
///
/// Usage: `private static let seam = DefaultsSeam()` plus a `static var defaults`
/// that forwards to `seam.value`.
final class DefaultsSeam: Sendable {
    private let slot: OSAllocatedUnfairLock<UserDefaults>

    init(_ initial: UserDefaults = .standard) {
        slot = OSAllocatedUnfairLock(initialState: initial)
    }

    var value: UserDefaults {
        get { slot.withLock { $0 } }
        set { slot.withLock { $0 = newValue } }
    }
}
