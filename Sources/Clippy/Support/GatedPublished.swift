import Combine
import Foundation

/// A `@Published`-like, UserDefaults-persisted setting whose writes can be vetoed
/// (SEC-01: an MDM-forced key is read-only).
///
/// Why not `@Published` + a revert in `didSet`: `@Published` publishes the new
/// value in `willSet`, before any veto in `didSet` can run, so subscribers such
/// as `McpServerController` would see (and act on) a value the policy rejected,
/// and re-assigning inside `didSet` fights the wrapper. Here a rejected write
/// changes nothing: no persistence, no `objectWillChange`, no emission.
///
/// `projectedValue` (`$setting`) is an `AnyPublisher` that emits the current value
/// on subscription and then each accepted change, matching `Published`.
@MainActor
@propertyWrapper
final class GatedPublished<Value> {

    private let subject: CurrentValueSubject<Value, Never>
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
        self.subject = CurrentValueSubject(sanitize(initial))
        self.sanitize = sanitize
        self.isForced = isForced
        self.persist = persist
    }

    /// Fallback accessor required by the wrapper grammar; inside a class the
    /// enclosing-instance subscript below is used instead.
    var wrappedValue: Value {
        get { subject.value }
        set { apply(newValue) }
    }

    var projectedValue: AnyPublisher<Value, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Applies an accepted write. Returns false (and does nothing) when the key is forced.
    @discardableResult
    fileprivate func apply(_ newValue: Value, notify: () -> Void = {}) -> Bool {
        guard !isForced(key) else { return false }
        let value = sanitize(newValue)
        notify()
        persist(key, value)
        subject.send(value)
        return true
    }

    static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, GatedPublished<Value>>
    ) -> Value where EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher {
        get { instance[keyPath: storageKeyPath].subject.value }
        set {
            instance[keyPath: storageKeyPath].apply(newValue) { instance.objectWillChange.send() }
        }
    }
}
