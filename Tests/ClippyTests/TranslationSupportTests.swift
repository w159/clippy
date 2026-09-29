import NaturalLanguage
import XCTest
@testable import Clippy

final class TranslationSupportTests: XCTestCase {
    func testLanguageMappingHandlesChineseScriptsAndUndetermined() {
        XCTAssertNil(TranslationSupport.language(for: nil))
        XCTAssertNil(TranslationSupport.language(for: .undetermined))
        XCTAssertEqual(TranslationSupport.language(for: .simplifiedChinese)?.script?.identifier, "Hans")
        XCTAssertEqual(TranslationSupport.language(for: .traditionalChinese)?.script?.identifier, "Hant")
        XCTAssertEqual(TranslationSupport.language(for: .french)?.languageCode?.identifier, "fr")
    }

    func testDetectionAndSameLanguage() {
        let detected = TranslationSupport.detectLanguage(of: "The quick brown fox jumps over the lazy dog near the river.")
        XCTAssertEqual(detected?.languageCode?.identifier, "en")
        XCTAssertTrue(TranslationSupport.isSameLanguage(detected, Locale.Language(identifier: "en")))
        XCTAssertFalse(TranslationSupport.isSameLanguage(detected, Locale.Language(identifier: "de")))
        XCTAssertFalse(TranslationSupport.isSameLanguage(nil, Locale.Language(identifier: "en")))
        XCTAssertFalse(TranslationSupport.isSameLanguage(
            Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant")))
    }

    func testGateRefusesSensitiveUntilConfirmedAndEmpty() {
        XCTAssertEqual(TranslateGate.evaluate(text: "  ", isSensitive: false, confirmed: false), .empty)
        XCTAssertEqual(TranslateGate.evaluate(text: "hi", isSensitive: true, confirmed: false), .needsConfirmation)
        XCTAssertEqual(TranslateGate.evaluate(text: "hi", isSensitive: true, confirmed: true), .allowed)
        XCTAssertEqual(TranslateGate.evaluate(text: "hi", isSensitive: false, confirmed: false), .allowed)
    }
}
