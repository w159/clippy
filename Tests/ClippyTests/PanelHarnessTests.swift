import AppKit
import SwiftUI
import XCTest
@testable import Clippy

/// Drives the real panel (`ClipListView`) in a real AppKit window with real key
/// and mouse events, and saves screenshots. Needs a window server, so it only
/// runs when `CLIPPY_UI_HARNESS=1` (CI sets it on macOS runners). Screenshots go
/// to `CLIPPY_SCREENSHOT_DIR` (default: a temporary folder, printed).
@MainActor
final class PanelHarnessTests: XCTestCase {
    private var window: HarnessWindow!
    private var store: ClipStore!
    private var pasted: [String] = []
    private var shotDirectory: URL!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CLIPPY_UI_HARNESS"] == "1" else {
            throw XCTSkip("Set CLIPPY_UI_HARNESS=1 to drive the panel in a real window")
        }
        let env = ProcessInfo.processInfo.environment["CLIPPY_SCREENSHOT_DIR"]
        shotDirectory = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("clippy-shots")
        try FileManager.default.createDirectory(at: shotDirectory, withIntermediateDirectories: true)
        print("HARNESS screenshots: \(shotDirectory.path)")
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate()
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        store = nil
    }

    // MARK: - Fixture

    private func seededStore() throws -> ClipStore {
        let db = try makeTestDatabase(self)
        let base = Date().addingTimeInterval(-3600)
        let texts = [
            "Quarterly invoice for Acme Corp, due Friday",
            "https://github.com/w159/clippy/pull/42",
            "let value = getUserName(id)",
            "Send the deck to jo@example.com before the review",
            "Lunch: pad thai, no peanuts",
            "C++ templates are compile-time code generation",
            "invoice reminder sent",
            "Meeting notes: ship the search fix, then the screenshots",
        ]
        for (offset, text) in texts.enumerated() {
            var clip = makeTextClip(text, createdAt: base.addingTimeInterval(Double(offset) * 60))
            try db.saveCapturedClip(&clip, cap: 1000)
        }
        let filed = try XCTUnwrap(try db.allClips().first { $0.contentText.hasPrefix("Quarterly") }?.id)
        let work = try db.createCategory(named: "Work", colorHex: "#2F6FEB", iconKind: .symbol, iconValue: "briefcase")
        try db.setClip(filed, inCategory: try XCTUnwrap(work.id), true)
        return ClipStore(database: db, pasteboard: NSPasteboard(name: NSPasteboard.Name("ClippyHarness-\(UUID())")))
    }

    private func openPanel(appearance: NSAppearance.Name) throws {
        store = try seededStore()
        pasted = []
        let view = ClipListView(
            store: store,
            onPaste: { [weak self] clip, _ in self?.pasted.append(clip.contentText) },
            onPasteMany: { _, _, _ in },
            onPasteFile: { _, _ in },
            onPrimary: { [weak self] clip in self?.pasted.append(clip.contentText) },
            onSendKeystrokes: { _ in },
            onEdit: { _ in },
            onClose: {},
            onOpenSettings: {}
        )
        show(view.clippyDesignSystem(), size: NSSize(width: 820, height: 600), appearance: appearance)
        pump(until: "clips loaded") { self.store.clips.count == 8 && !self.store.categories.isEmpty }
        pump(until: "search field focused") { self.window.firstResponder is NSTextView }
    }

    private func show<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name) {
        NSApp.appearance = NSAppearance(named: appearance)
        let window = HarnessWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        pump(seconds: 0.5)
    }

    // MARK: - Run loop and events

    private func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func pump(until description: String, timeout: TimeInterval = 5, _ condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if !condition() {
            dumpDiagnostics(description)
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
        }
    }

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

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, "+": 24, "@": 19,
    ]

    private func typeText(_ text: String) {
        for character in text { key(String(character), code: Self.keyCodes[character] ?? 0) }
    }

    private func pressReturn() { key("\r", code: 36) }
    private func pressEscape() { key("\u{1b}", code: 53) }

    private func clearQuery() {
        store.query = ""
        pump(seconds: 0.2)
    }

    private func click(at windowPoint: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return XCTFail("could not make mouse event") }
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    // MARK: - Accessibility lookup

    private func accessibilityNodes(_ root: Any, depth: Int = 0) -> [NSAccessibilityProtocol] {
        guard depth < 40, let node = root as? NSAccessibilityProtocol else { return [] }
        let children = (node.accessibilityChildren() ?? []).flatMap { accessibilityNodes($0, depth: depth + 1) }
        return [node] + children
    }

    private func describe(_ node: NSAccessibilityProtocol) -> String {
        let label = node.accessibilityLabel() ?? ""
        let value = (node.accessibilityValue() as? String) ?? ""
        let title = node.accessibilityTitle() ?? ""
        return [label, value, title].filter { !$0.isEmpty }.joined(separator: " | ")
    }

    private func visibleTexts() -> [String] {
        guard let content = window.contentView else { return [] }
        return accessibilityNodes(content).map(describe).filter { !$0.isEmpty }
    }

    private func isShown(_ fragment: String) -> Bool {
        visibleTexts().contains { $0.localizedCaseInsensitiveContains(fragment) }
    }

    /// Window-coordinate center of the first accessibility node mentioning `fragment`.
    private func centerOfNode(mentioning fragment: String) -> NSPoint? {
        guard let content = window.contentView else { return nil }
        let node = accessibilityNodes(content).last { describe($0).localizedCaseInsensitiveContains(fragment) }
        guard let frame = node?.accessibilityFrame(), frame.width > 0 else { return nil }
        let inWindow = window.convertFromScreen(frame)
        return NSPoint(x: inWindow.midX, y: inWindow.midY)
    }

    // MARK: - Screenshots and diagnostics

    private func screenshot(_ name: String) {
        guard let view = window.contentView else { return }
        pump(seconds: 0.3)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: shotDirectory.appendingPathComponent("\(name).png"))
            }
        }
        // A composited capture as well: cacheDisplay skips materials and vibrancy.
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)",
                             shotDirectory.appendingPathComponent("\(name)-window.png").path]
        guard (try? capture.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(5)
        while capture.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if capture.isRunning { capture.terminate() }
    }

    private func dumpDiagnostics(_ context: String) {
        let lines = ["context: \(context)",
                     "query: \(store?.query ?? "-")",
                     "clips: \(store?.clips.map(\.contentText) ?? [])",
                     "pasted: \(pasted)",
                     "firstResponder: \(String(describing: window?.firstResponder))",
                     "isKey: \(window?.isKeyWindow ?? false)",
                     "ax: \(visibleTexts().prefix(80))"]
        let text = lines.joined(separator: "\n")
        print("HARNESS diagnostics\n\(text)")
        try? text.write(to: shotDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString.prefix(6)).txt"),
                        atomically: true, encoding: .utf8)
    }

    // MARK: - Panel flows

    func testSearchFlowsInTheRealPanel() throws {
        try openPanel(appearance: .aqua)
        screenshot("01-panel-light")
        XCTAssertFalse(isShown("Quarterly invoice"), "a filed clip stays out of History while browsing")

        // 1. Typing searches, and a filed clip is found from History.
        typeText("invoice")
        XCTAssertEqual(store.query, "invoice")
        pump(seconds: 0.8)  // debounce plus the search itself
        screenshot("02-search-results-light")
        XCTAssertTrue(isShown("Quarterly invoice"), "filed clip found from History search")
        XCTAssertTrue(isShown("invoice reminder"))
        XCTAssertFalse(isShown("pad thai"))

        // 2. Return straight after typing pastes the top match of what was typed.
        clearQuery()
        typeText("hub")
        pressReturn()
        pump(until: "Return pasted after the search landed") { !self.pasted.isEmpty }
        XCTAssertEqual(pasted, ["https://github.com/w159/clippy/pull/42"])

        // 3. Fragments and punctuation are literal searches.
        clearQuery()
        typeText("c++")
        pump(seconds: 0.8)
        XCTAssertEqual(store.clips.map(\.contentText), ["C++ templates are compile-time code generation"])

        // 4. No results shows the empty state with a way out.
        clearQuery()
        typeText("zqxj")
        pump(until: "no results") { self.store.clips.isEmpty }
        pump(seconds: 0.3)
        screenshot("03-no-results-light")
        XCTAssertTrue(isShown("No clips match"))
        pressEscape()
        pump(until: "Escape cleared the query") { self.store.query.isEmpty }

        // 5. Typing while the list has focus keeps every character.
        pump(seconds: 0.3)
        let card = try XCTUnwrap(centerOfNode(mentioning: "pad thai"), "card for the lunch clip on screen")
        click(at: card)
        pump(seconds: 0.7)  // the double-click gesture delays the single tap
        pump(until: "list focused after a card click") { !(self.window.firstResponder is NSTextView) }
        typeText("deck")
        pump(seconds: 0.3)
        XCTAssertEqual(store.query, "deck", "first character must not be replaced by the second")
        if store.query != "deck" { dumpDiagnostics("typing from the list") }
        pump(seconds: 0.8)
        XCTAssertEqual(store.clips.map(\.contentText), ["Send the deck to jo@example.com before the review"])
    }

    func testDarkPanelScreenshots() throws {
        try openPanel(appearance: .darkAqua)
        screenshot("04-panel-dark")
        typeText("invoice")
        pump(seconds: 0.8)
        screenshot("05-search-results-dark")
        clearQuery()
        typeText("zqxj")
        pump(until: "no results") { self.store.clips.isEmpty }
        pump(seconds: 0.3)
        screenshot("06-no-results-dark")
    }

    // MARK: - Other windows

    func testSettingsAndOnboardingScreenshots() throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            show(SettingsView(), size: NSSize(width: 1000, height: 700), appearance: appearance)
            pump(seconds: 0.8)
            screenshot("07-settings-\(suffix)")
            window.orderOut(nil)

            let defaults = try XCTUnwrap(UserDefaults(suiteName: "clippy.harness.onboarding.\(UUID())"))
            show(OnboardingView(viewModel: OnboardingViewModel(defaults: defaults)).clippyDesignSystem(),
                 size: NSSize(width: 640, height: 520), appearance: appearance)
            pump(seconds: 0.8)
            screenshot("08-onboarding-\(suffix)")
            window.orderOut(nil)
        }
    }
}

/// A titled window that can become key while the test process is the app.
final class HarnessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
