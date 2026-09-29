import XCTest
@testable import Clippy

@MainActor
final class GridMetricsTests: XCTestCase {
    func testRowDensitiesAlwaysSingleColumn() {
        for width in stride(from: CGFloat(300), through: 2400, by: 150) {
            XCTAssertEqual(GridMetrics.columnCount(forWidth: width, preferred: .auto, density: .compact), 1)
            XCTAssertEqual(GridMetrics.columnCount(forWidth: width, preferred: .fixed(4), density: .comfortable), 1)
        }
    }

    func testAutoColumnsTable() {
        let expected: [(CGFloat, Int)] = [
            (300, 1), (420, 2), (520, 2), (720, 3), (923, 3), (1100, 4), (1400, 4), (2200, 7), (2400, 7),
        ]
        for (width, count) in expected {
            let got = GridMetrics.columnCount(forWidth: width, preferred: .auto, density: .cards)
            XCTAssertEqual(got, count, "width \(width)")
        }
    }

    func testAutoNeverExceedsFitAndNeverDropsBelowOne() {
        for width in stride(from: CGFloat(0), through: 3000, by: 37) {
            let count = GridMetrics.columnCount(forWidth: width, preferred: .auto, density: .cards)
            XCTAssertGreaterThanOrEqual(count, 1)
            let usable = width - GridMetrics.listPadding * 2
            if usable > 0, count > 1 {
                let cardWidth = (usable - CGFloat(count - 1) * GridMetrics.spacing) / CGFloat(count)
                XCTAssertGreaterThanOrEqual(cardWidth, GridMetrics.minCardWidth, "width \(width)")
            }
        }
    }

    func testAutoWideCardsStayNearMax() {
        for width in stride(from: CGFloat(700), through: 2400, by: 50) {
            let count = GridMetrics.columnCount(forWidth: width, preferred: .auto, density: .cards)
            let usable = width - GridMetrics.listPadding * 2
            let cardWidth = (usable - CGFloat(count - 1) * GridMetrics.spacing) / CGFloat(count)
            XCTAssertLessThanOrEqual(cardWidth, GridMetrics.maxCardWidth + 0.5, "width \(width)")
        }
    }

    func testFixedIsCappedByWidth() {
        XCTAssertEqual(GridMetrics.columnCount(forWidth: 300, preferred: .fixed(4), density: .cards), 1)
        XCTAssertEqual(GridMetrics.columnCount(forWidth: 520, preferred: .fixed(4), density: .cards), 2)
        XCTAssertEqual(GridMetrics.columnCount(forWidth: 923, preferred: .fixed(4), density: .cards), 4)
        XCTAssertEqual(GridMetrics.columnCount(forWidth: 1400, preferred: .fixed(4), density: .cards), 4)
        XCTAssertEqual(GridMetrics.columnCount(forWidth: 1400, preferred: .fixed(0), density: .cards), 1)
    }

    func testColumnModeStorageRoundTrip() {
        XCTAssertEqual(GridColumnMode(storageValue: GridColumnMode.fixed(3).storageValue), .fixed(3))
        XCTAssertEqual(GridColumnMode(storageValue: "auto"), .auto)
        XCTAssertEqual(GridColumnMode(storageValue: "fixed:x"), .auto)
        XCTAssertEqual(GridColumnMode(storageValue: nil), .auto)
    }

    func testPreferencesDefaultsAndPersistence() throws {
        let suite = "grid-prefs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = GridPreferences(defaults: defaults)
        XCTAssertEqual(prefs.density, .compact)
        XCTAssertEqual(prefs.columnMode, .auto)
        prefs.density = .cards
        prefs.columnMode = .fixed(2)
        let reread = GridPreferences(defaults: defaults)
        XCTAssertEqual(reread.density, .cards)
        XCTAssertEqual(reread.columnMode, .fixed(2))
    }
}
