import Observation

/// Re-arming replacement for a Combine `$property.removeDuplicates().dropFirst().receive(on: main).sink`.
///
/// Calls `onChange` on the main actor, with the new value, each time `read()`
/// returns something different after a change to anything it touched. Observation
/// reports a change before the value is written, so the callback runs on the next
/// main-actor turn, when the write has landed. The initial value is not delivered.
///
/// The observation lives as long as the objects `read` touches; there is nothing
/// to cancel. Callers capture owners weakly, as they did for `sink`.
@MainActor
func observeChanges<Value: Equatable & Sendable>(
    of read: @escaping @MainActor () -> Value,
    onChange: @escaping @MainActor (Value) -> Void
) {
    armObservation(last: read(), read: read, onChange: onChange)
}

@MainActor
private func armObservation<Value: Equatable & Sendable>(
    last: Value,
    read: @escaping @MainActor () -> Value,
    onChange: @escaping @MainActor (Value) -> Void
) {
    withObservationTracking {
        _ = read()
    } onChange: {
        Task { @MainActor in
            let value = read()
            if value != last { onChange(value) }
            armObservation(last: value, read: read, onChange: onChange)
        }
    }
}
