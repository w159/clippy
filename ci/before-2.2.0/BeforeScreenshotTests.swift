import AppKit
import SwiftUI
import XCTest
@testable import Clippy

/// Screenshots of Clippy 2.2.0 (b8aa9a0), for the before-and-after job in
/// .github/workflows/ci.yml. This file is copied into a checkout of 2.2.0 under
/// Tests/ClippyTests/; it is not part of the current package and is written
/// only against APIs that exist at b8aa9a0. Same gate as the current harness:
/// needs a window server, so it runs only with CLIPPY_UI_HARNESS=1. Files go to
/// CLIPPY_SCREENSHOT_DIR: before-panel-history.png (and -window.png, composited),
/// before-settings.png.
@MainActor
final class BeforeScreenshotTests: XCTestCase {
    private var window: NSWindow?
    private var store: ClipStore?
    private var directory: URL!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CLIPPY_UI_HARNESS"] == "1" else {
            throw XCTSkip("Set CLIPPY_UI_HARNESS=1 to render the panel in a real window")
        }
        let env = ProcessInfo.processInfo.environment["CLIPPY_SCREENSHOT_DIR"]
        directory = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("clippy-before-shots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("BEFORE screenshots: \(directory.path)")
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate()
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        store = nil
    }

    // MARK: - Fixture (same clips as PanelHarnessTests.seededStore on the current branch)

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
        return ClipStore(database: db, pasteboard: NSPasteboard(name: NSPasteboard.Name("ClippyBefore-\(UUID())")))
    }

    // MARK: - Run loop

    private func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func pump(until description: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if !condition() { XCTFail("Timed out waiting for \(description)") }
    }

    // MARK: - Capture

    /// Saves `<name>.png` (cacheDisplay, no materials) and `<name>-window.png`
    /// (screencapture of the composited window); with `compositedOnly`, only the
    /// composited capture, written as `<name>.png`.
    private func capture(_ name: String, compositedOnly: Bool = false) {
        guard let window, let view = window.contentView else { return }
        pump(seconds: 0.3)
        if !compositedOnly, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name).png"))
        }
        let target = directory.appendingPathComponent(compositedOnly ? "\(name).png" : "\(name)-window.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", target.path]
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if process.isRunning { process.terminate() }
    }

    // MARK: - Panel

    func testPanelHistoryScreenshot() throws {
        let store = try seededStore()
        self.store = store
        let view = ClipListView(
            store: store,
            onPaste: { _, _ in },
            onPasteMany: { _, _, _ in },
            onPasteFile: { _, _ in },
            onPrimary: { _ in },
            onSendKeystrokes: { _ in },
            onEdit: { _ in },
            onClose: {},
            onOpenSettings: {}
        )
        // 640x480 is the 2.2.0 default (AppSettings+Defaults: panelWidth, panelHeight).
        let size = NSSize(width: 640, height: 480)
        let panel = PastePanel(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                               styleMask: PastePanel.chromeStyleMask, backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .aqua)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.applyChrome()
        // Hosted as PanelController.clearHostingView does: clear layer, no titlebar safe area.
        let hosting = NSHostingView(rootView: view.clippyDesignSystem())
        hosting.safeAreaRegions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)
        window = panel
        pump(seconds: 0.5)
        pump(until: "clips loaded") { store.clips.count == 8 && !store.categories.isEmpty }
        pump(seconds: 0.8)
        capture("before-panel-history")
    }

    // MARK: - Settings (General pane, the default selection)

    func testSettingsScreenshot() throws {
        unsetenv("CLIPPY_SETTINGS_SECTION")
        let size = NSSize(width: 1000, height: 700)
        let settings = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        settings.appearance = NSAppearance(named: .aqua)
        settings.isReleasedWhenClosed = false
        settings.contentView = NSHostingView(rootView: SettingsView())
        settings.makeKeyAndOrderFront(nil)
        window = settings
        pump(seconds: 1.3)
        // cacheDisplay cannot draw the split view's sidebar material.
        capture("before-settings", compositedOnly: true)
    }
}
