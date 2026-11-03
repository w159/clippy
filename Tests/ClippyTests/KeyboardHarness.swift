import AppKit
import XCTest
@testable import Clippy

/// A physical key as `NSEvent.keyEvent` needs it: the character it types and its virtual key code.
struct HarnessKey {
    let characters: String
    let code: UInt16
    /// Arrow and function keys arrive with these flags from the hardware.
    var implicitFlags: NSEvent.ModifierFlags = []

    static func function(_ scalar: Int, code: UInt16) -> HarnessKey {
        HarnessKey(characters: String(UnicodeScalar(scalar).map(Character.init) ?? " "), code: code,
                   implicitFlags: [.function])
    }

    static func arrow(_ scalar: Int, code: UInt16) -> HarnessKey {
        HarnessKey(characters: String(UnicodeScalar(scalar).map(Character.init) ?? " "), code: code,
                   implicitFlags: [.function, .numericPad])
    }

    static let returnKey = HarnessKey(characters: "\r", code: 36)
    static let escape = HarnessKey(characters: "\u{1b}", code: 53)
    static let space = HarnessKey(characters: " ", code: 49)
    static let tab = HarnessKey(characters: "\t", code: 48)
    static let delete = HarnessKey(characters: "\u{7F}", code: 51)
    static let leftArrow = arrow(0xF702, code: 123)
    static let rightArrow = arrow(0xF703, code: 124)
    static let downArrow = arrow(0xF701, code: 125)
    static let upArrow = arrow(0xF700, code: 126)
    static let f10 = function(0xF70D, code: 109)

    /// Virtual key codes for the characters `typeText` and `letter(_:)` can send.
    static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, "+": 24, "@": 19,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    ]

    /// The key that types `character`.
    static func letter(_ character: Character) -> HarnessKey {
        HarnessKey(characters: String(character), code: codes[character] ?? 0)
    }
}

/// Key-event driving shared by the panel harness tests. Events go through
/// `NSWindow.sendEvent`, the path real keystrokes take after the main menu.
extension PanelHarnessTests {
    /// Sends one key press (down then up) to `target`, default the panel window.
    func press(_ key: HarnessKey, flags: NSEvent.ModifierFlags = [], to target: NSWindow? = nil) {
        let destination = target ?? window!
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags.union(key.implicitFlags),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: destination.windowNumber,
                context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
                isARepeat: false, keyCode: key.code)
            else { return XCTFail("could not make a key event for code \(key.code)") }
            destination.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    /// Cmd (plus `extra`) with a letter, e.g. `pressCommand("r")` for Cmd+R.
    func pressCommand(_ letter: Character, extra: NSEvent.ModifierFlags = []) {
        let shifted = extra.contains(.shift)
        let character = shifted ? Character(letter.uppercased()) : letter
        let key = HarnessKey(characters: String(character), code: HarnessKey.codes[letter] ?? 0)
        press(key, flags: NSEvent.ModifierFlags.command.union(extra))
    }

    func typeText(_ text: String) {
        for character in text { press(.letter(character)) }
    }

    func pressReturn() { press(.returnKey) }
    func pressEscape() { press(.escape) }
}
