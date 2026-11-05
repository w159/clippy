import AppKit
import SwiftUI
import XCTest
@testable import Clippy

/// Measures the real view hierarchy at the panel's default size and prints one `MEASURE ` line per value, in points.
/// Sizes come from `LayoutProbe` frames reported by the laid-out SwiftUI views (and from the real `NSWindow`s), not
/// from the layout constants. The lines are also written to `measurements.txt` in the screenshot directory, which CI
/// uploads with the screenshots. Same gate as the rest of the harness (`CLIPPY_UI_HARNESS=1`).
extension PanelHarnessTests {
    /// The panel at its default size (`AppSettings.defaultPanelWidth` x `defaultPanelHeight`).
    static var defaultPanelSize: NSSize {
        NSSize(width: AppSettings.defaultPanelWidth, height: AppSettings.defaultPanelHeight)
    }

    /// Content size the Settings window is shown at by the Settings screenshot tests and by the measurement.
    static let settingsWindowSize = NSSize(width: 715, height: 540)

    private func format(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }

    private func format(_ size: CGSize) -> String { "\(format(size.width))x\(format(size.height))" }

    private func frame(_ id: String) -> CGRect? { LayoutProbe.shared.frames[id] }

    func testPanelMeasurements() throws {
        var lines: [String] = []
        func emit(_ text: String) {
            lines.append("MEASURE " + text)
            print("MEASURE " + text)
        }
        func require(_ id: String, file: StaticString = #filePath, line: UInt = #line) -> CGRect {
            guard let found = LayoutProbe.shared.frames[id] else {
                XCTFail("no layout probe reported for \(id)", file: file, line: line)
                return .zero
            }
            return found
        }

        // The registered default, as a first-run user gets it.
        let suite = "clippy.harness.measure.\(UUID())"
        let fresh = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { fresh.removePersistentDomain(forName: suite) }
        AppSettings.registerDefaults(fresh)
        let registered = CGSize(width: fresh.double(forKey: AppSettings.Keys.panelWidth),
                                height: fresh.double(forKey: AppSettings.Keys.panelHeight))
        emit("panel.default.registered \(format(registered)) pt")
        XCTAssertEqual(registered, CGSize(width: 760, height: 480))

        let grid = GridPreferences.shared
        let savedDensity = grid.density
        defer { grid.density = savedDensity }
        grid.density = .comfortable
        LayoutProbe.shared.reset()
        try openPanel(appearance: .aqua, size: Self.defaultPanelSize)
        pump(until: "layout probes reported") {
            ["header", "search", "footer", "row.comfortable", "row.tile", "sidebar.row", "detail", "list.column", "row.text"]
                .allSatisfy { LayoutProbe.shared.frames[$0] != nil }
        }
        pump(seconds: 0.4)

        emit("panel.window.frame \(format(window.frame.size)) pt")
        emit("panel.content.frame \(format(window.contentView?.frame.size ?? .zero)) pt")
        XCTAssertEqual(window.contentView?.frame.size, Self.defaultPanelSize, "the panel opens at 760 x 480")
        let header = require("header"), search = require("search"), footer = require("footer")
        let comfortable = require("row.comfortable"), tile = require("row.tile")
        let sidebarRow = require("sidebar.row"), detail = require("detail")
        emit("header.height \(format(header.height)) pt")
        emit("search.field.height \(format(search.height)) pt")
        emit("footer.height \(format(footer.height)) pt")
        emit("row.comfortable.height \(format(comfortable.height)) pt")
        emit("sidebar.row.height \(format(sidebarRow.height)) pt")
        emit("detail.pane.width \(format(detail.width)) pt")
        let listColumn = require("list.column"), rowText = require("row.text")
        emit("list.column.width \(format(listColumn.width)) pt")
        emit("row.text.width \(format(rowText.width)) pt")
        emit("row.tile.size \(format(tile.size)) pt")

        screenshot("50-panel-default-light")

        grid.density = .compact
        LayoutProbe.shared.reset()
        pump(until: "compact row probe") { LayoutProbe.shared.frames["row.compact"] != nil }
        pump(seconds: 0.3)
        let compact = require("row.compact")
        emit("row.compact.height \(format(compact.height)) pt")
        if let glyph = frame("row.glyph") { emit("row.compact.glyph.size \(format(glyph.size)) pt") }
        window.orderOut(nil)

        grid.density = .comfortable
        try openPanel(appearance: .darkAqua, size: Self.defaultPanelSize)
        pump(seconds: 0.6)
        screenshot("50-panel-default-dark")
        window.orderOut(nil)

        show(SettingsView(), size: Self.settingsWindowSize, appearance: .aqua)
        pump(seconds: 0.8)
        emit("settings.window.frame \(format(window.frame.size)) pt")
        window.orderOut(nil)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "clippy.harness.onboarding.\(UUID())"))
        let onboarding = OnboardingWindowController.makeWindow(
            rootView: OnboardingView(viewModel: OnboardingViewModel(defaults: defaults)).clippyDesignSystem()
                .environment(\.appearsActive, true))
        present(onboarding)
        pump(seconds: 0.8)
        emit("onboarding.window.frame \(format(onboarding.frame.size)) pt")
        window.orderOut(nil)

        try (lines.joined(separator: "\n") + "\n").write(
            to: shotDirectory.appendingPathComponent("measurements.txt"), atomically: true, encoding: .utf8)

        // The density targets, measured on the real layout.
        XCTAssertLessThanOrEqual(header.height, 44.5, "header")
        XCTAssertLessThanOrEqual(search.height, 28.5, "search field")
        XCTAssertLessThanOrEqual(footer.height, 28.5, "footer")
        XCTAssertLessThanOrEqual(comfortable.height, 44.5, "comfortable row")
        XCTAssertGreaterThanOrEqual(comfortable.height, 39.5, "comfortable row")
        XCTAssertLessThanOrEqual(compact.height, 28.5, "compact row")
        XCTAssertLessThanOrEqual(sidebarRow.height, 30, "sidebar row")
        XCTAssertLessThanOrEqual(tile.width, 28.5, "row tile")
        XCTAssertGreaterThanOrEqual(listColumn.width, 300, "clip list column at the default panel size")
        XCTAssertGreaterThanOrEqual(rowText.width, 200, "row title area at the default panel size")
    }
}
