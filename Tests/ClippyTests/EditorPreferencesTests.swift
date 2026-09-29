import XCTest
@testable import Clippy

@MainActor
final class EditorPreferencesTests: XCTestCase {
    private func makePrefs() -> EditorPreferences {
        let name = "clippy-editor-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return EditorPreferences(defaults: defaults)
    }

    func testDefaultsDifferForCodeAndProse() {
        let prefs = makePrefs()
        XCTAssertFalse(prefs.checksSpelling(.code))
        XCTAssertTrue(prefs.checksSpelling(.prose))
        XCTAssertFalse(prefs.usesSmartSubstitutions(.code))
        XCTAssertTrue(prefs.usesSmartSubstitutions(.prose))
        XCTAssertFalse(prefs.wraps(.code))
        XCTAssertTrue(prefs.wraps(.prose))
        XCTAssertTrue(prefs.showsLineNumbers)
        XCTAssertNil(prefs.fontSize)
    }

    func testTogglesPersistPerCategory() {
        let prefs = makePrefs()
        prefs.setChecksSpelling(true, for: .code)
        prefs.setWraps(false, for: .prose)
        XCTAssertTrue(prefs.checksSpelling(.code))
        XCTAssertTrue(prefs.checksSpelling(.prose))
        XCTAssertFalse(prefs.wraps(.prose))
        XCTAssertFalse(prefs.wraps(.code))
    }

    func testZoomClampsAndResets() {
        let prefs = makePrefs()
        prefs.zoomIn(from: 13)
        XCTAssertEqual(prefs.fontSize, 14)
        prefs.zoomOut(from: 14)
        prefs.zoomOut(from: 13)
        XCTAssertEqual(prefs.fontSize, 12)
        prefs.zoomOut(from: 8)
        XCTAssertEqual(prefs.fontSize, EditorPreferences.minFontSize)
        prefs.zoomIn(from: 40)
        XCTAssertEqual(prefs.fontSize, EditorPreferences.maxFontSize)
        prefs.resetZoom()
        XCTAssertNil(prefs.fontSize)
    }

    func testCategoryFromLanguage() {
        XCTAssertEqual(EditorContentCategory(language: .markdown), .prose)
        XCTAssertEqual(EditorContentCategory(language: .plain), .prose)
        XCTAssertEqual(EditorContentCategory(language: .swift), .code)
        XCTAssertEqual(EditorContentCategory(language: .csv), .code)
    }
}
