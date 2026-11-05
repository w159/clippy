import Foundation
import Observation

// MARK: - Observation bridge
//
// `@Observable` classes cannot apply their macro to a stored property that
// carries a property wrapper, so every wrapped setting is declared
// `@ObservationIgnored @AppDefault(...)`. The wrapper then reports reads and
// writes to the owning class's registrar itself, through the `access` and
// `withMutation` members that `@Observable` generates. This protocol is how the
// wrapper reaches them without knowing the concrete class.

@MainActor
protocol ObservationNotifying: AnyObject, Observable {
    /// Bumped by bulk operations (reset, import) that rewrite UserDefaults behind
    /// the wrappers' backs. Wrapped reads depend on it, so bumping re-renders
    /// every observer of every wrapped setting.
    var storageRevision: Int { get }

    func access<Member>(keyPath: KeyPath<Self, Member>)
    func withMutation<Member, MutationResult>(
        keyPath: KeyPath<Self, Member>, _ mutation: () throws -> MutationResult
    ) rethrows -> MutationResult
}

// MARK: - AppDefault property wrapper
//
// Collapses the repetitive stored property + didSet + UserDefaults.set pattern
// used throughout AppSettings into a single declaration line.
//
// Why the enclosing-instance subscript matters:
//   A plain property wrapper cannot reach the enclosing @Observable class to
//   tell its registrar about reads and writes. Swift exposes a static subscript
//   hook (SE-0258) that the compiler calls instead of the wrappedValue accessor
//   when the wrapper is used inside a class. That hook receives the instance, so
//   we can call `access` on reads and wrap writes in `withMutation`, which is
//   exactly what the @Observable macro generates for a plain stored property.
//
// Two storage strategies (via overloaded inits, not conditional conformance
// -- Swift does not allow conditional conformance on property wrappers):
//   (a) Value is a UserDefaults-native plist type: stored and read directly.
//   (b) Value: RawRepresentable with a plist RawValue: rawValue stored,
//       Value(rawValue:) read back; falls back to the declared default on
//       an unrecognized stored string.
//
// UserDefaults coupling:
//   The wrapper always reads/writes UserDefaults.standard. AppSettings
//   accepts a custom `defaults` injected at init (used only in the
//   private init for the shared singleton via `.standard`). No test
//   constructs AppSettings with a custom UserDefaults -- every test uses
//   AppSettings.shared -- so hardwiring .standard does not break any
//   existing test seam. This is documented explicitly so a future reader
//   knows it is a deliberate trade-off, not an oversight.

@propertyWrapper
struct AppDefault<Value> {

    // MARK: Storage

    let key: String
    let defaultValue: Value

    // How to read/write. Captured at init time so the subscript
    // does not need to know which strategy was chosen.
    private let read: (UserDefaults) -> Value
    private let write: (UserDefaults, Value) -> Void

    // MARK: Inits

    /// Plist-native init: Bool, Int, Double, String, [String], Data.
    init(_ key: String, default defaultValue: Value)
    where Value: UserDefaultsStorable {
        self.key = key
        self.defaultValue = defaultValue
        self.read = { $0.appDefaultRead(forKey: key) ?? defaultValue }
        self.write = { $0.appDefaultWrite($1, forKey: key) }
    }

    /// RawRepresentable init: stores rawValue, reads back via init(rawValue:).
    init<R>(_ key: String, default defaultValue: Value)
    where Value: RawRepresentable, Value.RawValue == R, R: UserDefaultsStorable {
        self.key = key
        self.defaultValue = defaultValue
        self.read = { ud in
            guard let raw: R = ud.appDefaultRead(forKey: key) else { return defaultValue }
            return Value(rawValue: raw) ?? defaultValue
        }
        self.write = { ud, v in ud.appDefaultWrite(v.rawValue, forKey: key) }
    }

    // MARK: wrappedValue (fallback accessor)
    //
    // The compiler calls the static subscript below when the wrapper is
    // inside a class. This accessor is required by the Swift grammar but
    // is never reached via normal AppSettings use.
    var wrappedValue: Value {
        get { read(.standard) }
        set { write(.standard, newValue) }
    }

    // MARK: Enclosing-instance subscript
    //
    // This is the load-bearing path for observation. Called by the compiler
    // instead of `wrappedValue` when the wrapper is declared inside a reference
    // type. Reads register with the registrar (plus the shared storage revision,
    // so bulk resets re-render); writes go through `withMutation` so observers
    // are told before the value changes, matching what @Observable generates.
    @MainActor
    static subscript<EnclosingSelf: ObservationNotifying>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Self>
    ) -> Value {
        get {
            instance.access(keyPath: wrappedKeyPath)
            _ = instance.storageRevision
            let wrapper = instance[keyPath: storageKeyPath]
            return wrapper.read(.standard)
        }
        set {
            instance.withMutation(keyPath: wrappedKeyPath) {
                let wrapper = instance[keyPath: storageKeyPath]
                wrapper.write(.standard, newValue)
            }
        }
    }
}

// MARK: - UserDefaultsStorable
//
// Marker protocol covering every type that UserDefaults can store/retrieve
// without encoding. We provide typed read/write helpers so the wrapper
// above does not need to switch on type at runtime.

protocol UserDefaultsStorable {}

extension Bool:     UserDefaultsStorable {}
extension Int:      UserDefaultsStorable {}
extension Double:   UserDefaultsStorable {}
extension String:   UserDefaultsStorable {}
extension Data:     UserDefaultsStorable {}

// Array-of-String is the only collection AppSettings uses.
extension Array: UserDefaultsStorable where Element == String {}

// MARK: - UserDefaults typed helpers

extension UserDefaults {
    /// Typed read for plist-native values. Returns nil when the key is absent.
    func appDefaultRead<V: UserDefaultsStorable>(forKey key: String) -> V? {
        switch V.self {
        case is Bool.Type:    return bool(forKey: key) as? V
        case is Int.Type:     return integer(forKey: key) as? V
        case is Double.Type:  return double(forKey: key) as? V
        case is String.Type:  return string(forKey: key) as? V
        case is Data.Type:    return data(forKey: key) as? V
        case is [String].Type: return stringArray(forKey: key) as? V
        default:              return object(forKey: key) as? V
        }
    }

    // Bool needs a nil-vs-false sentinel check so we do not return the
    // default false when the key was never written.
    func appDefaultRead(forKey key: String) -> Bool? {
        guard object(forKey: key) != nil else { return nil }
        return bool(forKey: key)
    }

    // Int needs the same sentinel: integer(forKey:) returns 0 for absent keys.
    func appDefaultRead(forKey key: String) -> Int? {
        guard object(forKey: key) != nil else { return nil }
        return integer(forKey: key)
    }

    // Double: double(forKey:) returns 0.0 for absent keys.
    func appDefaultRead(forKey key: String) -> Double? {
        guard object(forKey: key) != nil else { return nil }
        return double(forKey: key)
    }

    /// Typed write for plist-native values.
    func appDefaultWrite<V: UserDefaultsStorable>(_ value: V, forKey key: String) {
        set(value, forKey: key)
    }
}
