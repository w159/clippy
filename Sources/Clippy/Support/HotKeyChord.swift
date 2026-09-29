import AppKit
import Carbon.HIToolbox

/// A global shortcut: a virtual key code plus a Carbon modifier mask
/// (`cmdKey | shiftKey | optionKey | controlKey`). Pure value type so encoding,
/// display and conflict checks are testable without registering anything.
struct HotKeyChord: Codable, Equatable, Hashable {
    /// Carbon virtual key code (kVK_*).
    var keyCode: UInt32
    /// Carbon modifier mask.
    var modifiers: UInt32

    /// The four modifier bits a chord may contain.
    static let modifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    /// Creates a chord, dropping modifier bits that are not cmd/shift/option/control.
    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    /// Converts AppKit modifier flags to a Carbon mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    /// A global chord needs at least one of cmd/option/control, otherwise it
    /// would swallow ordinary typing. Shift alone is not enough.
    var isValid: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 && Self.keyNames[keyCode] != nil
    }

    /// Symbolic label such as "⌃⌥⇧⌘V", in the standard macOS modifier order.
    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "\u{2303}" }
        if modifiers & UInt32(optionKey) != 0 { text += "\u{2325}" }
        if modifiers & UInt32(shiftKey) != 0 { text += "\u{21E7}" }
        if modifiers & UInt32(cmdKey) != 0 { text += "\u{2318}" }
        return text + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    /// Spoken form for VoiceOver, e.g. "Command Shift V".
    var spokenString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        parts.append(Self.keyNames[keyCode] ?? "key \(keyCode)")
        return parts.joined(separator: " ")
    }

    // MARK: - Persistence

    /// JSON encoding used for UserDefaults storage.
    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Decodes a stored chord; nil for corrupt data.
    static func decode(_ data: Data?) -> HotKeyChord? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(HotKeyChord.self, from: data)
    }

    // MARK: - Key names

    /// Printable names for the keys a chord may use.
    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [:]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"),
            (kVK_ANSI_9, "9"), (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"),
            (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"), (kVK_ANSI_Backslash, "\\"),
            (kVK_ANSI_Grave, "`"), (kVK_Space, "Space"), (kVK_Return, "Return"), (kVK_Tab, "Tab"),
            (kVK_Delete, "Delete"), (kVK_LeftArrow, "\u{2190}"), (kVK_RightArrow, "\u{2192}"),
            (kVK_UpArrow, "\u{2191}"), (kVK_DownArrow, "\u{2193}"), (kVK_F1, "F1"), (kVK_F2, "F2"),
            (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
            (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12")
        ]
        for (code, name) in letters { names[UInt32(code)] = name }
        return names
    }()
}

/// The named global actions Clippy registers.
enum HotKeyAction: String, CaseIterable, Codable {
    case showPanel
    case pastePlain
    case pastePrevious
    case pasteStackToggle
    case pasteStackNext

    /// Stable Carbon hotkey id (1-based).
    var carbonID: UInt32 {
        switch self {
        case .showPanel: return 1
        case .pastePlain: return 2
        case .pastePrevious: return 3
        case .pasteStackToggle: return 4
        case .pasteStackNext: return 5
        }
    }

    /// Reverse lookup for the Carbon event handler.
    static func action(forCarbonID id: UInt32) -> HotKeyAction? { allCases.first { $0.carbonID == id } }

    /// Settings label.
    var title: String {
        switch self {
        case .showPanel: return "Show Clippy"
        case .pastePlain: return "Paste last clip as plain text"
        case .pastePrevious: return "Paste previous clip"
        case .pasteStackToggle: return "Toggle paste stack"
        case .pasteStackNext: return "Paste next item from stack"
        }
    }

    /// UserDefaults key holding the JSON-encoded chord.
    var defaultsKey: String { "hotkey.chord.\(rawValue)" }

    /// UserDefaults key marking an explicitly disabled binding.
    var disabledKey: String { "hotkey.disabled.\(rawValue)" }

    /// Factory chord; only the panel has one, the paste shortcuts are opt-in.
    var defaultChord: HotKeyChord? {
        switch self {
        case .showPanel: return HotKeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
        case .pastePlain, .pastePrevious, .pasteStackToggle, .pasteStackNext: return nil
        }
    }
}

/// Well-known chords other software already owns.
enum HotKeyConflicts {
    /// A reserved chord and who owns it.
    struct Entry: Equatable {
        let chord: HotKeyChord
        let owner: String
    }

    /// System and common-app chords that cannot or should not be taken.
    static let known: [Entry] = {
        let cmd = UInt32(cmdKey), ctrl = UInt32(controlKey), opt = UInt32(optionKey), shift = UInt32(shiftKey)
        func entry(_ key: Int, _ mods: UInt32, _ owner: String) -> Entry {
            Entry(chord: HotKeyChord(keyCode: UInt32(key), modifiers: mods), owner: owner)
        }
        return [
            entry(kVK_Space, cmd, "Spotlight"),
            entry(kVK_Space, cmd | opt, "Finder search"),
            entry(kVK_Space, ctrl, "Input source switching"),
            entry(kVK_Tab, cmd, "the app switcher"),
            entry(kVK_ANSI_Q, cmd, "Quit"),
            entry(kVK_ANSI_Q, cmd | ctrl, "Lock Screen"),
            entry(kVK_Return, cmd, "Paste and keep panel open"),
            entry(kVK_ANSI_P, cmd, "Pin in Clippy / Print in editors"),
            entry(kVK_ANSI_S, cmd | ctrl, "Toggle Clippy sidebar"),
            entry(kVK_ANSI_W, cmd, "Close Window"),
            entry(kVK_ANSI_H, cmd, "Hide"),
            entry(kVK_ANSI_M, cmd, "Minimize"),
            entry(kVK_ANSI_C, cmd, "Copy"),
            entry(kVK_ANSI_V, cmd, "Paste"),
            entry(kVK_ANSI_X, cmd, "Cut"),
            entry(kVK_ANSI_Z, cmd, "Undo"),
            entry(kVK_ANSI_A, cmd, "Select All"),
            entry(kVK_ANSI_3, cmd | shift, "Screenshot"),
            entry(kVK_ANSI_4, cmd | shift, "Screenshot selection"),
            entry(kVK_ANSI_5, cmd | shift, "Screenshot toolbar"),
            entry(kVK_ANSI_Grave, cmd, "Window switching"),
            entry(kVK_Escape, cmd | opt, "Force Quit")
        ]
    }()

    /// Description of the conflicting owner, or nil when the chord is free.
    static func conflict(for chord: HotKeyChord) -> String? {
        known.first { $0.chord == chord }?.owner
    }
}
