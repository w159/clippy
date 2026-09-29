import XCTest
@testable import Clippy

final class OnboardingModelTests: XCTestCase {
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "onboarding.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testStepOrderAndAdvance() {
        var model = OnboardingModel()
        var seen: [OnboardingStep] = [model.current]
        while !model.isFinished {
            model.next()
            if !model.isFinished { seen.append(model.current) }
        }
        XCTAssertEqual(seen, [.welcome, .accessibility, .suggestions, .ocr, .hotkey, .launchAtLogin, .notifications, .privacy])
        XCTAssertEqual(model.current, .privacy)
    }

    func testSkipMarksStepAndAdvances() {
        var model = OnboardingModel()
        model.skip()
        XCTAssertEqual(model.current, .accessibility)
        XCTAssertEqual(model.skipped, [.welcome])
        model.skip()
        XCTAssertEqual(model.current, .suggestions)
        XCTAssertEqual(model.skipped, [.welcome, .accessibility])
    }

    func testBackClearsSkipMark() {
        var model = OnboardingModel()
        model.next()
        model.skip()
        model.back()
        XCTAssertEqual(model.current, .accessibility)
        XCTAssertTrue(model.skipped.isEmpty)
        var first = OnboardingModel()
        first.back()
        XCTAssertTrue(first.isFirst)
    }

    func testSkipAllFinishesAndMarksRemainingSkippable() {
        var model = OnboardingModel()
        model.next()
        model.next()
        model.skipAll()
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(model.skipped, [.suggestions, .ocr, .hotkey, .launchAtLogin, .notifications, .privacy])
    }

    func testPersistenceOnlyWhenFinishedAndReopenDoesNotClearIt() {
        let (defaults, suiteName) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(OnboardingModel.needsOnboarding(defaults: defaults))
        var model = OnboardingModel()
        XCTAssertFalse(model.persistIfFinished(defaults: defaults))
        XCTAssertTrue(OnboardingModel.needsOnboarding(defaults: defaults))
        model.skipAll()
        XCTAssertTrue(model.persistIfFinished(defaults: defaults))
        XCTAssertFalse(OnboardingModel.needsOnboarding(defaults: defaults))
        let reopened = OnboardingModel.reopened()
        XCTAssertEqual(reopened.current, .welcome)
        XCTAssertFalse(reopened.isFinished)
        XCTAssertFalse(OnboardingModel.needsOnboarding(defaults: defaults))
    }

    func testOlderCompletedVersionRetriggersOnboarding() {
        let (defaults, suiteName) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(OnboardingModel.currentVersion - 1, forKey: OnboardingModel.completedVersionKey)
        XCTAssertTrue(OnboardingModel.needsOnboarding(defaults: defaults))
    }
}
