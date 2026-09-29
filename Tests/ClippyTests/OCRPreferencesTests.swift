import XCTest
@testable import Clippy

final class OCRPreferencesTests: XCTestCase {
    private var saved: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        saved = OCRPreferences.defaults
        suite = "OCRPreferencesTests-\(UUID().uuidString)"
        OCRPreferences.defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        OCRPreferences.defaults.removePersistentDomain(forName: suite)
        OCRPreferences.defaults = saved
        super.tearDown()
    }

    func testDefaults() {
        XCTAssertEqual(OCRPreferences.level, .accurate)
        XCTAssertEqual(OCRPreferences.pdfMaxPages, OCRPreferences.defaultPDFMaxPages)
        XCTAssertTrue(OCRPreferences.useDocumentRecognition)
    }

    func testPDFPageLimitIsClamped() {
        OCRPreferences.pdfMaxPages = 0
        XCTAssertEqual(OCRPreferences.pdfMaxPages, 1)
        OCRPreferences.pdfMaxPages = 100_000
        XCTAssertEqual(OCRPreferences.pdfMaxPages, OCRPreferences.maxPDFMaxPages)
        OCRPreferences.pdfMaxPages = 7
        XCTAssertEqual(OCRPreferences.pdfMaxPages, 7)
    }

    func testLevelRoundTripAndUnknownValueFallsBack() {
        OCRPreferences.level = .fast
        XCTAssertEqual(OCRPreferences.level, .fast)
        OCRPreferences.defaults.set("bogus", forKey: "ocr.level")
        XCTAssertEqual(OCRPreferences.level, .accurate)
    }

    func testDocumentRecognitionCanBeDisabled() {
        OCRPreferences.useDocumentRecognition = false
        XCTAssertFalse(OCRPreferences.useDocumentRecognition)
    }
}
