import Foundation
import Observation

/// An observable, UserDefaults-persisted setting whose writes can be vetoed
/// (SEC-01: an MDM-forced key is read-only).
///
/// Why not a plain stored property with a revert in `didSet`: observers are
/// told about a change before `didSet` can run, so an observer such as
/// `McpServerController` would see (and act on) a value the policy rejected, and
/// re-assigning inside `didSet` fights the observation machinery. Here a
/// rejected write changes nothing: no persistence and no observer notification.
///
/// Declare it `@ObservationIgnored @GatedPublished(...)` inside an `@Observable`
/// class (the macro cannot wrap a property that already has a property wrapper).
/// The enclosing-instance subscript reports reads and writes to the class's
/// registrar, so `withObservationTracking` and SwiftUI see accepted changes only.
@MainActor
@propertyWrapper
final class GatedPublished<Value> {

    private var value: Value
    private let key: String
    private let isForced: (String) -> Bool
    private let sanitize: (Value) -> Value
    private let persist: (String, Value) -> Void

    /// - Parameters:
    ///   - initial: the stored value, already read from UserDefaults (a forced key reads as the managed value).
    ///   - sanitize: normalises accepted writes (for example range clamping).
    ///   - isForced: reports managed-preference locks; defaults to `AppSettings.isForced`.
    ///   - persist: writes an accepted value; defaults to `UserDefaults.standard`.
    init(key: String,
         initial: Value,
         sanitize: @escaping (Value) -> Value = { $0 },
         isForced: @escaping (String) -> Bool = { AppSettings.isForced($0) },
         persist: @escaping (String, Value) -> Void = { UserDefaults.standard.set($1, forKey: $0) }) {
        self.key = key
        self.value = sanitize(initial)
        self.sanitize = sanitize
        self.isForced = isForced
        self.persist = persist
    }

    /// Fallback accessor required by the wrapper grammar; inside a class the
    /// enclosing-instance subscript below is used instead.
    var wrappedValue: Value {
        get { value }
        set { apply(newValue) { $0() } }
    }

    /// Applies an accepted write. Returns false (and does nothing) when the key is forced.
    /// `mutate` runs the change; the subscript wraps it in `withMutation`.
    @discardableResult
    fileprivate func apply(_ newValue: Value, mutate: (() -> Void) -> Void) -> Bool {
        guard !isForced(key) else { return false }
        let sanitized = sanitize(newValue)
        mutate {
            persist(key, sanitized)
            value = sanitized
        }
        return true
    }

    static subscript<EnclosingSelf: ObservationNotifying>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, GatedPublished<Value>>
    ) -> Value {
        get {
            instance.access(keyPath: wrappedKeyPath)
            return instance[keyPath: storageKeyPath].value
        }
        set {
            instance[keyPath: storageKeyPath].apply(newValue) { change in
                instance.withMutation(keyPath: wrappedKeyPath) { change() }
            }
        }
    }
}
