import XCTest
@testable import Clippy

/// OCR-11: logic behind the in-flight scrim and result sheet (no views).
@MainActor
final class OCRPresenterTests: XCTestCase {
    func testScrimFollowsRunLifecyclePerClip() {
        let presenter = OCRPresenter()
        XCTAssertFalse(presenter.isRunning)
        presenter.begin(clipID: 1)
        XCTAssertTrue(presenter.isScrimVisible(for: 1))
        XCTAssertFalse(presenter.isScrimVisible(for: 2), "other cards stay unveiled")
        presenter.finish(clipID: 1, outcome: .notice("No text found in image."))
        XCTAssertFalse(presenter.isScrimVisible(for: 1))
        XCTAssertFalse(presenter.isRunning)
    }

    func testTextOutcomeOpensSheetAndIsNotReturnedForBanner() {
        let presenter = OCRPresenter()
        presenter.begin(clipID: 5)
        let leftover = presenter.finish(clipID: 5, outcome: .text("one two  three\nfour"))
        XCTAssertNil(leftover)
        XCTAssertEqual(presenter.result?.wordCount, 4)
        XCTAssertEqual(presenter.result?.characterCount, 19)
        presenter.dismiss()
        XCTAssertNil(presenter.result)
    }

    func testFailureIsReturnedForBannerAndClearsScrim() {
        let presenter = OCRPresenter()
        presenter.begin(clipID: 3)
        let leftover = presenter.finish(clipID: 3, outcome: .failure("boom"))
        XCTAssertEqual(leftover, .failure("boom"))
        XCTAssertNil(presenter.result)
        XCTAssertFalse(presenter.isRunning)
    }

    func testAlreadyRunningNoticeKeepsScrimForTheRealRun() {
        let presenter = OCRPresenter()
        presenter.begin(clipID: 9)
        presenter.finish(
            clipID: 9, outcome: .notice("Text extraction is already running for this clip."))
        XCTAssertTrue(presenter.isScrimVisible(for: 9))
    }

    func testAnonymousRunsAreCountedAndNeverGoNegative() {
        let presenter = OCRPresenter()
        presenter.begin(clipID: nil)
        XCTAssertTrue(presenter.isScrimVisible(for: nil))
        presenter.finish(clipID: nil, outcome: .failure("x"))
        presenter.finish(clipID: nil, outcome: .failure("x"))
        XCTAssertFalse(presenter.isRunning)
    }
}
