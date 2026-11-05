import Foundation
import Observation

/// Thread-safe change counter shared with the `@Sendable` onChange closure.
final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

/// Number of change notifications `read` receives while `mutate` runs.
///
/// Observation notifies once per registration, so this is 0 or 1: it answers
/// "did this write notify observers of what `read` touches" (the old
/// `objectWillChange` sink counts, minus repeat counting). A rejected write, or
/// a read of something the write did not touch, yields 0.
@MainActor
func observedChangeCount(tracking read: () -> Void, during mutate: () -> Void) -> Int {
    let counter = ObservationCounter()
    withObservationTracking(read, onChange: { counter.increment() })
    mutate()
    return counter.count
}

/// Continuously counts changes to whatever `track` reads, re-arming after each
/// notification (on the next main-actor turn, so several writes inside one
/// turn count once). The replacement for a long-lived Combine `$property.sink`.
@MainActor
final class ChangeRecorder {
    private let counter = ObservationCounter()
    private let track: @MainActor () -> Void
    private var isActive = true

    var count: Int { counter.count }

    init(tracking track: @escaping @MainActor () -> Void) {
        self.track = track
        arm()
    }

    func cancel() { isActive = false }

    private func arm() {
        guard isActive else { return }
        withObservationTracking {
            track()
        } onChange: { [counter, weak self] in
            counter.increment()
            Task { @MainActor in self?.arm() }
        }
    }
}
