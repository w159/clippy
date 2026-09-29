import Carbon.HIToolbox
import XCTest
@testable import Clippy

@MainActor
final class HotKeyChordTests: XCTestCase {
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "hotkey.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private let cmdShiftV = HotKeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))

    func testEncodeDecodeRoundTrip() {
        XCTAssertEqual(HotKeyChord.decode(cmdShiftV.encoded()), cmdShiftV)
    }

    func testDecodeCorruptDataIsNil() {
        XCTAssertNil(HotKeyChord.decode(Data("nope".utf8)))
        XCTAssertNil(HotKeyChord.decode(nil))
    }

    func testDisplayStringUsesStandardModifierOrder() {
        let chord = HotKeyChord(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(chord.displayString, "\u{2303}\u{2325}\u{21E7}\u{2318}K")
        XCTAssertEqual(cmdShiftV.spokenString, "Shift Command V")
    }

    func testModifierlessOrShiftOnlyChordIsInvalid() {
        XCTAssertFalse(HotKeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: 0).isValid)
        XCTAssertFalse(HotKeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(shiftKey)).isValid)
        XCTAssertTrue(cmdShiftV.isValid)
    }

    func testUnknownModifierBitsAreDropped() {
        XCTAssertEqual(HotKeyChord(keyCode: 9, modifiers: UInt32(cmdKey) | UInt32(1 << 20)).modifiers, UInt32(cmdKey))
    }

    func testKnownConflictsAreDetected() {
        XCTAssertEqual(HotKeyConflicts.conflict(for: HotKeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))), "Spotlight")
        XCTAssertEqual(HotKeyConflicts.conflict(for: HotKeyChord(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey))), "Paste and keep panel open")
        XCTAssertEqual(HotKeyConflicts.conflict(for: HotKeyChord(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | controlKey))), "Toggle Clippy sidebar")
        XCTAssertNil(HotKeyConflicts.conflict(for: cmdShiftV))
    }

    func testCenterRejectsDuplicateAcrossActionsAndSystemChords() {
        let (suite, suiteName) = freshDefaults()
        defer { suite.removePersistentDomain(forName: suiteName) }
        let center = HotKeyCenter(defaults: suite)
        XCTAssertNotNil(center.conflictMessage(for: HotKeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)), action: .showPanel))
        XCTAssertNotNil(center.conflictMessage(for: HotKeyChord(keyCode: 9, modifiers: 0), action: .showPanel))
        XCTAssertNil(center.conflictMessage(for: cmdShiftV, action: .showPanel))
    }

    func testStoredChordFallsBackToDefaultAndHonorsOverrides() {
        let (suite, suiteName) = freshDefaults()
        defer { suite.removePersistentDomain(forName: suiteName) }
        let center = HotKeyCenter(defaults: suite)
        XCTAssertEqual(center.storedChord(for: .showPanel), HotKeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)))
        XCTAssertNil(center.storedChord(for: .pastePlain))
        XCTAssertNil(center.storedChord(for: .pastePrevious))
        XCTAssertNil(center.storedChord(for: .pasteStackToggle))
        let custom = HotKeyChord(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | optionKey))
        suite.set(custom.encoded(), forKey: HotKeyAction.showPanel.defaultsKey)
        XCTAssertEqual(center.storedChord(for: .showPanel), custom)
        suite.set(true, forKey: HotKeyAction.showPanel.disabledKey)
        XCTAssertNil(center.storedChord(for: .showPanel))
    }

    func testCarbonIDsRoundTripAndAreUnique() {
        XCTAssertEqual(Set(HotKeyAction.allCases.map(\.carbonID)).count, HotKeyAction.allCases.count)
        for action in HotKeyAction.allCases { XCTAssertEqual(HotKeyAction.action(forCarbonID: action.carbonID), action) }
    }
}
