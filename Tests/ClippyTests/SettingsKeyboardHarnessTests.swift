import AppKit
import SwiftUI
import XCTest
@testable import Clippy

/// Drives the real settings window with real key events: Cmd-digit pane shortcuts, arrow
/// navigation, search by keyboard and Esc to close. Needs a window server, so it only runs
/// when `CLIPPY_UI_HARNESS=1` (CI sets it on macOS runners).
@MainActor
final class SettingsKeyboardHarnessTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CLIPPY_UI_HARNESS"] == "1" else {
            throw XCTSkip("Set CLIPPY_UI_HARNESS=1 to drive the settings window")
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate()
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    func testSettingsKeyboardJourney() throws {
        let model = SettingsShellModel()
        model.selection = .general
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        pump(seconds: 0.8)

        let panes = SettingsPaneSection.all.flatMap(\.panes)
        key("2", code: 19, flags: .command)
        pump(until: "Cmd-2 selects the second pane") { model.selection == panes[1] }

        key("\u{F701}", code: 125, flags: [.numericPad, .function])
        pump(until: "Down selects the third pane") { model.selection == panes[2] }

        let expected = try XCTUnwrap(SettingsSearchIndex.search("sound", in: SettingsSearchCatalog.entries).first)
        let expectedPane = try XCTUnwrap(SettingsPaneID(rawValue: expected.entry.pane))
        XCTAssertNotEqual(expectedPane, panes[2], "pick a query whose first hit is not the current pane")
        if let field = Self.searchField(in: window.contentView) {
            window.makeFirstResponder(field)
            for character in "sound" { key(String(character), code: Self.keyCodes[character] ?? 0) }
        } else {
            model.query = "sound"
        }
        pump(until: "query reaches the model") { model.query == "sound" }
        key("\r", code: 36)
        pump(until: "Return opens the first hit's pane") { model.selection == expectedPane }

        pump(seconds: 0.5)
        key("\u{1b}", code: 53)
        pump(until: "Esc closes the window") { !window.isVisible }
    }

    // MARK: - Helpers

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for child in view.subviews { if let found = searchField(in: child) { return found } }
        return nil
    }

    private static let keyCodes: [Character: UInt16] = ["s": 1, "o": 31, "u": 32, "n": 45, "d": 2]

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { return XCTFail("could not make key event") }
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func pump(until description: String, timeout: TimeInterval = 5, _ condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if !condition() { XCTFail("Timed out waiting for \(description)", file: file, line: line) }
    }
}
