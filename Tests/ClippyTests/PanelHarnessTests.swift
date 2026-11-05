import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Clippy

/// Drives the real panel (`ClipListView`) in a real AppKit window with real key
/// and mouse events, and saves screenshots. Needs a window server, so it only
/// runs when `CLIPPY_UI_HARNESS=1` (CI sets it on macOS runners). Screenshots go
/// to `CLIPPY_SCREENSHOT_DIR` (default: a temporary folder, printed).
@MainActor
final class PanelHarnessTests: XCTestCase {
    var window: NSWindow!
    var store: ClipStore!
    var pasted: [String] = []
    /// Texts of each multi-clip paste, in call order.
    var pastedMany: [[String]] = []
    var shotDirectory: URL!

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
        forceActivate()
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        store = nil
    }

    // MARK: - Fixture

    func seededStore() throws -> ClipStore {
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

    func openPanel(appearance: NSAppearance.Name, size: NSSize = NSSize(width: 1000, height: 620)) throws {
        store = try seededStore()
        pasted = []
        pastedMany = []
        let view = ClipListView(
            store: store,
            onPaste: { [weak self] clip, _ in self?.pasted.append(clip.contentText) },
            onPasteMany: { [weak self] clips, _, _ in self?.pastedMany.append(clips.map(\.contentText)) },
            onPasteFile: { _, _ in },
            onPrimary: { [weak self] clip in self?.pasted.append(clip.contentText) },
            onSendKeystrokes: { _ in },
            onEdit: { _ in },
            onClose: {},
            onOpenSettings: {}
        )
        show(view.clippyDesignSystem(), size: size, appearance: appearance, panelChrome: true)
        pump(until: "clips loaded") { self.store.clips.count == 8 && !self.store.categories.isEmpty }
        pump(until: "search field focused") { self.window.firstResponder is NSTextView }
    }

    func show<V: View>(_ content: V, size: NSSize, appearance: NSAppearance.Name, panelChrome: Bool = false) {
        // CI runners cannot always activate the test host, which draws accent controls grey; capture them active.
        let view = content.environment(\.appearsActive, true)
        NSApp.appearance = NSAppearance(named: appearance)
        let window = PastePanel(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                                 styleMask: PastePanel.chromeStyleMask,
                                 backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false  // as PanelController configures the real panel
        if panelChrome {
            // Dressed as PanelController dresses the real panel: no titlebar strip.
            window.applyChrome()
            window.contentView = PanelController.clearHostingView(view)
        } else {
            window.contentView = NSHostingView(rootView: view)
        }
        present(window)
    }

    func present(_ window: NSWindow) {
        self.window = window
        makeKeyInActiveApp(window)
        pump(seconds: 0.5)
        if !window.isKeyWindow { print("HARNESS warning: window is not key (appActive=\(NSApp.isActive))") }
    }

    /// Cooperative `NSApp.activate()` does not take focus from Finder on CI runners. Force it, and fall back to
    /// `NSRunningApplication.activate(options:)` when the process is still inactive.
    func forceActivate() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.isActive { _ = NSRunningApplication.current.activate(options: [.activateAllWindows]) }
    }

    /// Accent controls draw grey while the app is inactive or the window is not key. Activate the app, make the
    /// window key and wait (bounded) for both so captures show the controls as a user sees them.
    func makeKeyInActiveApp(_ window: NSWindow) {
        forceActivate()
        window.makeKeyAndOrderFront(nil)
        let end = Date().addingTimeInterval(3)
        while !(window.isKeyWindow && NSApp.isActive), Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if !NSApp.isActive { forceActivate() }
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        }
    }

    // MARK: - Run loop and events

    func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func pump(until description: String, timeout: TimeInterval = 5, _ condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if !condition() {
            dumpDiagnostics(description)
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
        }
    }

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

    // MARK: - On-screen text lookup

    /// One recognized line of text with its box in normalized image space
    /// (origin bottom-left, as Vision reports it).
    private struct RecognizedLine {
        let text: String
        let box: CGRect
    }

    /// The SwiftUI tree is not reachable through `accessibilityChildren` of the
    /// hosting view, so assertions read what is actually drawn: render the content
    /// view at 2x and run text recognition over it.
    private func recognizedLines() -> [RecognizedLine] {
        guard let view = window?.contentView else { return [] }
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return [] }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let cgImage = rep.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Native-size 13 pt text is below Vision's default minimum text height (1/32 of the image).
        request.minimumTextHeight = 0.008
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            print("HARNESS ocr failed: \(error)")
            return []
        }
        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { RecognizedLine(text: $0.string, box: observation.boundingBox) }
        }
        if lines.isEmpty { print("HARNESS ocr found no text in a \(cgImage.width)x\(cgImage.height) px render") }
        return lines
    }

    private func isShown(_ fragment: String) -> Bool {
        recognizedLines().contains { $0.text.localizedCaseInsensitiveContains(fragment) }
    }

    private func assertShown(_ fragment: String, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        guard !isShown(fragment) else { return }
        dumpDiagnostics("expected on screen: \(fragment)")
        XCTFail("\"\(fragment)\" is not on screen. \(message)", file: file, line: line)
    }

    private func assertNotShown(_ fragment: String, _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        guard isShown(fragment) else { return }
        dumpDiagnostics("expected absent from screen: \(fragment)")
        XCTFail("\"\(fragment)\" is on screen. \(message)", file: file, line: line)
    }

    /// Window-coordinate center of the leftmost recognized line containing `fragment`. The detail pane on the
    /// right can repeat the selected clip's text; the list row is always the leftmost match.
    private func centerOfText(_ fragment: String) -> NSPoint? {
        guard let view = window?.contentView,
              let line = recognizedLines().filter({ $0.text.localizedCaseInsensitiveContains(fragment) })
                  .min(by: { $0.box.midX < $1.box.midX })
        else { return nil }
        let bounds = view.bounds
        let y = view.isFlipped ? (1 - line.box.midY) * bounds.height : line.box.midY * bounds.height
        return view.convert(NSPoint(x: line.box.midX * bounds.width, y: y), to: nil)
    }

    // MARK: - Screenshots and diagnostics

    /// Saves `name.png` as the window server composites the window, so Liquid Glass and system materials are
    /// drawn as a user sees them. Falls back to `cacheDisplay` when the capture fails, and logs which path ran.
    /// `compositedOnly` is kept for existing call sites; every screenshot now prefers the composited capture.
    func screenshot(_ name: String, compositedOnly: Bool = false) {
        guard let view = window.contentView else { return }
        if !(window.isKeyWindow && NSApp.isActive) { makeKeyInActiveApp(window) }
        window.orderFrontRegardless()
        pump(seconds: 0.4)
        let target = shotDirectory.appendingPathComponent("\(name).png")
        if captureWindow(to: target) {
            print("capture=window \(name)")
            return
        }
        try? FileManager.default.removeItem(at: target)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: target)
            }
        }
        print("capture=cache \(name)")
    }

    /// `screencapture -x -o -l <window id>`: no sound, no shadow. True when the file exists and is not blank.
    private func captureWindow(to url: URL) -> Bool {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        let errors = Pipe()
        capture.standardError = errors
        do { try capture.run() } catch {
            print("HARNESS screencapture failed to start: \(error)")
            return false
        }
        let deadline = Date().addingTimeInterval(8)
        while capture.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if capture.isRunning {
            capture.terminate()
            print("HARNESS screencapture timed out")
            return false
        }
        guard capture.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            print("HARNESS screencapture exit \(capture.terminationStatus): \(message)")
            return false
        }
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              !Self.isBlank(cg)
        else {
            print("HARNESS screencapture produced a missing or blank image")
            return false
        }
        return true
    }

    /// True when the image is fully transparent or a single color.
    private static func isBlank(_ image: CGImage) -> Bool {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return true }
        let first = Array(pixels[0..<4])
        if first[3] == 0, stride(from: 3, to: pixels.count, by: 4).allSatisfy({ pixels[$0] == 0 }) { return true }
        for i in stride(from: 4, to: pixels.count, by: 4) where Array(pixels[i..<i + 4]) != first { return false }
        return true
    }

    private func dumpDiagnostics(_ context: String) {
        let lines = ["context: \(context)",
                     "query: \(store?.query ?? "-")",
                     "clips: \(store?.clips.map(\.contentText) ?? [])",
                     "pasted: \(pasted)",
                     "firstResponder: \(String(describing: window?.firstResponder))",
                     "isKey: \(window?.isKeyWindow ?? false)",
                     "onScreen: \(recognizedLines().map(\.text))"]
        let text = lines.joined(separator: "\n")
        print("HARNESS diagnostics\n\(text)")
        try? text.write(to: shotDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString.prefix(6)).txt"),
                        atomically: true, encoding: .utf8)
    }

    // MARK: - Panel flows

    func testSearchFlowsInTheRealPanel() throws {
        try openPanel(appearance: .aqua)
        screenshot("01-panel-light")
        screenshot("panel-history-detail")
        assertNotShown("Quarterly invoice", "a filed clip stays out of History while browsing")

        // 1. Typing searches, and a filed clip is found from History.
        typeText("invoice")
        XCTAssertEqual(store.query, "invoice")
        pump(seconds: 0.8)  // debounce plus the search itself
        screenshot("02-search-results-light")
        assertShown("Quarterly invoice", "filed clip found from History search")
        assertShown("invoice reminder")
        assertNotShown("pad thai")

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
        assertShown("No clips match")
        pressEscape()
        pump(until: "Escape cleared the query") { self.store.query.isEmpty }

        // 5. Typing while the list has focus keeps every character.
        pump(seconds: 0.3)
        let card = try XCTUnwrap(centerOfText("pad thai"), "card for the lunch clip on screen")
        click(at: card)
        pump(seconds: 0.7)  // the double-click gesture delays the single tap
        pump(until: "list focused after a card click") { !(self.window.firstResponder is NSTextView) }
        XCTAssertFalse(window.firstResponder is NSTextView, "the click moved focus off the search field to the list")
        typeText("deck")
        pump(seconds: 0.3)
        XCTAssertEqual(store.query, "deck", "first character must not be replaced by the second")
        if store.query != "deck" { dumpDiagnostics("typing from the list") }
        pump(seconds: 0.8)
        XCTAssertEqual(store.clips.map(\.contentText), ["Send the deck to jo@example.com before the review"])
    }

    // MARK: - Keyboard-only journeys

    /// Clip texts in the order History shows them (the filed clip is not listed).
    private var historyOrder: [String] {
        store.clips.map(\.contentText).filter { !$0.hasPrefix("Quarterly") }
    }

    private var focusIsInTextField: Bool { window.firstResponder is NSTextView }

    /// Every clip action without touching the mouse: navigation, paste, focus
    /// moves, plain-text copy, rename, preview, multi-select and the actions key.
    func testKeyboardOnlyJourneys() throws {
        try openPanel(appearance: .aqua)
        let order = historyOrder
        XCTAssertGreaterThanOrEqual(order.count, 4, "fixture lists at least four clips in History: \(order)")

        // Down, Down, Up lands on the second clip; Return pastes it.
        press(.downArrow)
        press(.downArrow)
        press(.upArrow)
        pressReturn()
        pump(until: "Return pasted the clip under the cursor") { !self.pasted.isEmpty }
        XCTAssertEqual(pasted, [order[1]], "Down, Down, Up then Return pastes the second History clip")

        // Tab moves focus from the search field to the list, Shift-Tab brings it back.
        press(.tab)
        pump(until: "Tab moved focus off the search field") { !self.focusIsInTextField }
        press(.tab, flags: .shift)
        pump(until: "Shift-Tab returned focus to the search field") { self.focusIsInTextField }
        press(.tab)
        pump(until: "Tab moved focus to the list again") { !self.focusIsInTextField }

        // Cmd-Shift-C copies the clip under the cursor as plain text.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sentinel", forType: .string)
        pressCommand("c", extra: .shift)
        pump(until: "Cmd-Shift-C wrote the clip to the pasteboard") {
            NSPasteboard.general.string(forType: .string) == order[1]
        }
        XCTAssertNil(NSPasteboard.general.data(forType: .rtf), "plain-text copy leaves out RTF")
        XCTAssertNil(NSPasteboard.general.data(forType: .html), "plain-text copy leaves out HTML")

        // Cmd-R opens the inline rename for the same clip; typing and Return commit it.
        pressCommand("r")
        pump(until: "Cmd-R put focus in the rename field") {
            (self.window.firstResponder as? NSTextView)?.delegate is FocusSelectTextField
        }
        pump(seconds: 0.3)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate is FocusSelectTextField,
                      "the rename field keeps focus instead of the list taking it back")
        typeText("kw")
        pressReturn()
        pump(until: "Return saved the typed title") {
            self.store.clips.first { $0.contentText == order[1] }?.userTitle == "kw"
        }
        pump(until: "focus returned to the list after the rename") { !self.focusIsInTextField }

        // Space opens the preview; Escape in the preview closes it and the list keeps focus.
        press(.space)
        pump(until: "Space opened the preview") { QuickLookController.shared.isVisible }
        let preview = NSApp.windows.first { $0 !== window && $0.isVisible && $0.title == "kw" } ?? NSApp.keyWindow
        press(.escape, to: preview)
        pump(until: "Escape closed the preview") { !QuickLookController.shared.isVisible }
        pump(until: "the panel is key again after the preview closed") { self.window.isKeyWindow }
        pump(until: "list focus after the preview closed") { !self.focusIsInTextField }
        pump(seconds: 0.5)  // SwiftUI restores list focus on the next turns; a key sent sooner is dropped
        XCTAssertFalse(focusIsInTextField, "closing the preview leaves keyboard focus on the list, not the search field")

        // Shift-Down selects two clips; Cmd-Return takes the cursor row back out.
        press(.downArrow, flags: .shift)
        pressReturn()
        pump(until: "Return pasted the two selected clips") { !self.pastedMany.isEmpty }
        XCTAssertEqual(pastedMany, [[order[1], order[2]]], "Shift-Down extends the selection by one clip")
        pasted = []
        press(.returnKey, flags: .command)
        pressReturn()
        pump(until: "Return pasted the remaining clip") { !self.pasted.isEmpty }
        XCTAssertEqual(pasted, [order[1]], "Cmd-Return toggled the cursor clip out, leaving only the second clip")
        XCTAssertEqual(pastedMany.count, 1, "no second multi-clip paste after the toggle")

        // Shift-F10 opens the actions for the clip; Escape closes them.
        press(.f10, flags: .shift)
        pump(until: "Shift-F10 opened the actions") { self.isShown("Copy as Plain Text") }
        assertShown("Rename", "the actions list offers the menu-only Rename")
        pressEscape()
        pump(until: "Escape closed the actions") { !self.isShown("Copy as Plain Text") }
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
        let work = try XCTUnwrap(store.categories.first { $0.name == "Work" }?.id)
        XCTAssertEqual(SidebarCounts.displayedCategoryCount(store: store, categoryID: work), 0,
                       "the Work badge must match its empty pane while nothing matches")
        screenshot("06-no-results-dark")
    }

    // MARK: - Other windows

    func testSettingsAndOnboardingScreenshots() throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            show(SettingsView(), size: Self.settingsWindowSize, appearance: appearance)
            pump(seconds: 0.8)
            // cacheDisplay cannot draw the split view's sidebar material.
            screenshot("07-settings-\(suffix)", compositedOnly: true)
            window.orderOut(nil)

            let defaults = try XCTUnwrap(UserDefaults(suiteName: "clippy.harness.onboarding.\(UUID())"))
            NSApp.appearance = NSAppearance(named: appearance)
            let onboarding = OnboardingWindowController.makeWindow(
                rootView: OnboardingView(viewModel: OnboardingViewModel(defaults: defaults)).clippyDesignSystem()
                    .environment(\.appearsActive, true))
            onboarding.appearance = NSAppearance(named: appearance)
            present(onboarding)
            pump(seconds: 0.8)
            screenshot("08-onboarding-\(suffix)")
            window.orderOut(nil)
        }
    }
}
