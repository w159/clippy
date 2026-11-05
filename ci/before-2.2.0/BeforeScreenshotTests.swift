import AppKit
import SwiftUI
import XCTest
@testable import Clippy

/// Screenshots of Clippy 2.2.0 (b8aa9a0), for the "Version comparison" job in
/// .github/workflows/ci.yml. This file is copied into a checkout of 2.2.0 under
/// Tests/ClippyTests/; it is not part of the current package and is written
/// only against APIs that exist at b8aa9a0 (each call is cited file:line from
/// that commit). Same gate as the current harness: it needs a window server, so
/// it runs only with CLIPPY_UI_HARNESS=1. Files go to CLIPPY_SCREENSHOT_DIR, one
/// per screen and appearance:
///   before-panel-history-{light,dark}.png
///   before-panel-search-{light,dark}.png
///   before-settings-<pane>-{light,dark}.png   (every SettingsPaneID)
///   before-onboarding-{light,dark}.png
///   before-editor-clip-{light,dark}.png
///   before-palette-{light,dark}.png
/// Screens 2.2.0 does not have (empty-state and error-state panels, the other
/// panel panes, the sheets) are not captured.
@MainActor
final class BeforeScreenshotTests: XCTestCase {
    private static let appearances: [(name: NSAppearance.Name, suffix: String)] = [(.aqua, "light"), (.darkAqua, "dark")]

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
    }

    override func tearDown() async throws {
        unsetenv("CLIPPY_SETTINGS_SECTION")
        window?.orderOut(nil)
        window = nil
        store = nil
    }

    // MARK: - Fixture (same clips as PanelHarnessTests.seededStore on the current branch)

    // makeTestDatabase: Tests/ClippyTests/TestSupport.swift:6; makeTextClip: :38.
    // ClipDatabase.saveCapturedClip(_:cap:) Storage/ClipDatabase.swift:164, allClips() :443,
    // createCategory ClipDatabase+Categories.swift:61, setClip(_:inCategory:_:) :165.
    // ClipStore.init(database:monitor:pasteboard:recognizer:) UI/ClipStore.swift:121;
    // ClipStore.clips :23, categories :29, query :19.
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

    private func loadSeededStore() throws -> ClipStore {
        let store = try seededStore()
        self.store = store
        pump(until: "clips loaded") { store.clips.count == 8 && !store.categories.isEmpty }
        return store
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

    // MARK: - Windows

    /// A plain titled window hosting `view`, as the current harness does for non-panel screens.
    private func show<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name) {
        NSApp.appearance = NSAppearance(named: appearance)
        let host = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        host.appearance = NSAppearance(named: appearance)
        host.isReleasedWhenClosed = false
        host.contentView = NSHostingView(rootView: view)
        host.makeKeyAndOrderFront(nil)
        window = host
    }

    /// The panel dressed as the app dresses it. PastePanel(contentRect:styleMask:backing:defer:) is an
    /// NSPanel subclass (Panel/PastePanel.swift), chromeStyleMask :13, applyChrome() :17. Hosted the way
    /// PanelController.clearHostingView does (Panel/PanelController+Content.swift:50): clear layer, no
    /// titlebar safe area.
    private func showPanel<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name) {
        NSApp.appearance = NSAppearance(named: appearance)
        let panel = PastePanel(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                               styleMask: PastePanel.chromeStyleMask, backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: appearance)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.applyChrome()
        let hosting = NSHostingView(rootView: view.clippyDesignSystem())  // UI/DesignSystem/ClippyEnvironment.swift:42
        hosting.safeAreaRegions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)
        window = panel
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

    private func close() {
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Panel

    /// ClipListView memberwise init: UI/ClipListView.swift:9-22 (store, onPaste, onPasteMany,
    /// onPasteFile, onPrimary, onSendKeystrokes, onEdit, onClose, onOpenSettings).
    private func clipList(_ store: ClipStore) -> ClipListView {
        ClipListView(
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
    }

    func testPanelScreenshots() throws {
        // 640x480 is the 2.2.0 default (Support/AppSettings+Defaults.swift:11-12, panelWidth, panelHeight).
        let size = NSSize(width: 640, height: 480)
        for (appearance, suffix) in Self.appearances {
            let store = try loadSeededStore()
            showPanel(clipList(store), size: size, appearance: appearance)
            pump(seconds: 1.3)
            capture("before-panel-history-\(suffix)")

            // The store debounces and refilters off `query` (UI/ClipStore.swift:19-21).
            store.query = "invoice"
            pump(until: "the search to filter the list") { store.clips.count < 8 }
            pump(seconds: 0.8)
            capture("before-panel-search-\(suffix)")
            close()
        }
    }

    // MARK: - Settings (every pane)

    /// SettingsPaneID.allCases: UI/Settings/SettingsPaneRegistry.swift:7; the pane is chosen from
    /// CLIPPY_SETTINGS_SECTION by SettingsShellModel.init (UI/Settings/SettingsShellModel.swift:35-38);
    /// SettingsView(): UI/SettingsView.swift:6.
    func testSettingsPaneScreenshots() throws {
        for pane in SettingsPaneID.allCases {
            for (appearance, suffix) in Self.appearances {
                setenv("CLIPPY_SETTINGS_SECTION", pane.rawValue, 1)
                show(SettingsView(), size: NSSize(width: 1000, height: 700), appearance: appearance)
                pump(seconds: 1.0)
                // cacheDisplay cannot draw the split view's sidebar material.
                capture("before-settings-\(pane.rawValue)-\(suffix)", compositedOnly: true)
                close()
            }
        }
    }

    // MARK: - Onboarding

    /// OnboardingViewModel(defaults:): UI/Onboarding/OnboardingViewModel.swift:33; OnboardingView(viewModel:):
    /// UI/Onboarding/OnboardingView.swift:5-6. 2.2.0 has no makeWindow helper, so the window is built the way
    /// OnboardingWindowController.show builds it (UI/Onboarding/OnboardingWindowController.swift:20-31).
    func testOnboardingScreenshots() throws {
        for (appearance, suffix) in Self.appearances {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "clippy.before.onboarding.\(UUID())"))
            NSApp.appearance = NSAppearance(named: appearance)
            let onboarding = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 720, height: 520),
                                      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            onboarding.titlebarAppearsTransparent = true
            onboarding.titleVisibility = .hidden
            onboarding.isReleasedWhenClosed = false
            onboarding.backgroundColor = .clear
            onboarding.appearance = NSAppearance(named: appearance)
            onboarding.contentView = NSHostingView(
                rootView: OnboardingView(viewModel: OnboardingViewModel(defaults: defaults)))
            onboarding.makeKeyAndOrderFront(nil)
            window = onboarding
            pump(seconds: 1.0)
            capture("before-onboarding-\(suffix)")
            close()
        }
    }

    // MARK: - Clip editor

    /// ClipEditorView(clip:store:dirtyBridge:draft:onClose:): UI/ClipEditorView.swift:10-18; the middle two
    /// have defaults.
    func testClipEditorScreenshots() throws {
        for (appearance, suffix) in Self.appearances {
            let store = try loadSeededStore()
            let clip = try XCTUnwrap(store.clips.first)
            show(ClipEditorView(clip: clip, store: store, onClose: {}),
                 size: NSSize(width: 720, height: 560), appearance: appearance)
            pump(seconds: 1.0)
            capture("before-editor-clip-\(suffix)")
            close()
        }
    }

    // MARK: - Command palette

    /// PanelCommandContext memberwise init: UI/Shell/BuiltInCommands.swift:6-28 (featureCommands has a default);
    /// BuiltInCommands.all(_:) :40; CommandPaletteHost(commands:onDismiss:): UI/Shell/CommandPaletteHost.swift:6-20;
    /// ClipDensity.comfortable: UI/Grid/GridPreferences.swift:33.
    func testPaletteScreenshots() throws {
        let context = PanelCommandContext(
            hasSelectedClip: true, hasQuery: true, canExtractText: false, canFindSimilar: true, isPinned: false,
            paste: {}, pastePlain: {}, togglePin: {}, deleteSelection: {}, findSimilar: {}, openSettings: {},
            toggleSidebar: {}, currentDensity: .comfortable, setDensity: { _ in }, suggestionsEnabled: true,
            toggleSuggestions: {}, clearSearch: {}, extractText: {}, newCategory: {})
        for (appearance, suffix) in Self.appearances {
            show(CommandPaletteHost(commands: BuiltInCommands.all(context), onDismiss: {}).clippyDesignSystem(),
                 size: NSSize(width: 640, height: 480), appearance: appearance)
            pump(seconds: 1.0)
            capture("before-palette-\(suffix)")
            close()
        }
    }
}
