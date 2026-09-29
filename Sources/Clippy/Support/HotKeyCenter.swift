import AppKit
import Carbon.HIToolbox
import Combine

/// Global hotkeys via Carbon RegisterEventHotKey: works from a background
/// (accessory) app and needs no special permissions, unlike NSEvent global
/// monitors. Supports one user-defined chord per `HotKeyAction`, persisted in
/// UserDefaults (`HotKeyAction.defaultsKey`).
@MainActor
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    private var hotKeyRefs: [HotKeyAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private let defaults: UserDefaults

    /// Per-action callbacks, run on the main actor.
    var handlers: [HotKeyAction: () -> Void] = [:]

    /// Latest failure message per action; empty when everything registered.
    /// Observable so Settings and onboarding can show a banner.
    @Published private(set) var errors: [HotKeyAction: String] = [:]

    /// Currently configured chords (nil = binding off). Observable.
    @Published private(set) var chords: [HotKeyAction: HotKeyChord] = [:]

    /// First registration failure message, or nil when all registered.
    var lastError: String? {
        HotKeyAction.allCases.compactMap { errors[$0] }.first
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chords = Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.compactMap { action in
            storedChord(for: action).map { (action, $0) }
        })
    }

    // MARK: - Configuration

    /// The stored chord for `action`, falling back to its default unless disabled.
    func storedChord(for action: HotKeyAction) -> HotKeyChord? {
        if defaults.bool(forKey: action.disabledKey) { return nil }
        return HotKeyChord.decode(defaults.data(forKey: action.defaultsKey)) ?? action.defaultChord
    }

    /// Why `chord` cannot be used for `action`: invalid, taken by another Clippy
    /// action, or a well-known system chord. Nil when free (as far as detectable).
    func conflictMessage(for chord: HotKeyChord, action: HotKeyAction) -> String? {
        if !chord.isValid { return "Use at least one of \u{2318}, \u{2325} or \u{2303} with a supported key." }
        if let other = HotKeyAction.allCases.first(where: { $0 != action && chords[$0] == chord }) {
            return "Already used for \u{201C}\(other.title)\u{201D}."
        }
        if let owner = HotKeyConflicts.conflict(for: chord) { return "Conflicts with \(owner)." }
        return nil
    }

    /// Saves and registers `chord` (nil turns the binding off). Returns false
    /// when the chord is invalid or registration fails; the failure is also in `errors`.
    @discardableResult
    func setChord(_ chord: HotKeyChord?, for action: HotKeyAction) -> Bool {
        guard let chord else {
            defaults.set(true, forKey: action.disabledKey)
            defaults.removeObject(forKey: action.defaultsKey)
            unregister(action)
            return true
        }
        if let conflict = conflictMessage(for: chord, action: action) {
            errors[action] = conflict
            return false
        }
        defaults.removeObject(forKey: action.disabledKey)
        defaults.set(chord.encoded(), forKey: action.defaultsKey)
        return register(action, chord: chord)
    }

    /// Restores the factory chord for `action`.
    func resetChord(for action: HotKeyAction) {
        defaults.removeObject(forKey: action.defaultsKey)
        defaults.removeObject(forKey: action.disabledKey)
        if let chord = action.defaultChord { register(action, chord: chord) } else { unregister(action) }
    }

    // MARK: - Registration

    /// Registers every action that has a stored or default chord.
    func registerAll() {
        for action in HotKeyAction.allCases {
            if let chord = storedChord(for: action) { register(action, chord: chord) } else { unregister(action) }
        }
    }

    /// Removes every registered hotkey (quit).
    func unregisterAll() {
        for action in HotKeyAction.allCases { unregister(action) }
    }

    /// Low-level register of one action; records failure in `errors`.
    @discardableResult
    func register(_ action: HotKeyAction, chord: HotKeyChord) -> Bool {
        unregister(action)
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: 0x434C_5059, id: action.carbonID) // 'CLPY'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(chord.keyCode, chord.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            errors[action] = "\(chord.displayString) could not be registered (OSStatus \(status)). " +
                "Another app may already use this key combination."
            chords[action] = chord
            ClippyLog.error("RegisterEventHotKey failed for \(action.rawValue): OSStatus \(status)", category: ClippyLog.lifecycle)
            return false
        }
        hotKeyRefs[action] = ref
        errors[action] = nil
        chords[action] = chord
        return true
    }

    /// Unregisters one action and clears its error and chord.
    func unregister(_ action: HotKeyAction) {
        if let ref = hotKeyRefs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        errors[action] = nil
        chords[action] = nil
    }

    /// Runs the callback for `action` (also used by tests and menu items).
    @MainActor
    func fire(_ action: HotKeyAction) { handlers[action]?() }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard read == noErr, let action = HotKeyAction.action(forCarbonID: hotKeyID.id) else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in center.fire(action) }
            return noErr
        }, 1, &eventType, selfPointer, &eventHandlerRef)
    }
}

extension Notification.Name {
    /// Posted by the paste-stack hotkey; the paste-stack feature (Wave 4) observes it.
    static let clippyPasteStackToggle = Notification.Name("ClippyPasteStackToggle")
}
