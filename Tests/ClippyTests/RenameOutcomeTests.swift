import XCTest
@testable import Clippy

final class RenameOutcomeTests: XCTestCase {
    func testUnchangedPlaceholderIsNotSaved() {
        // No user title, no source app: field is seeded with "Unknown app".
        XCTAssertEqual(
            RenameOutcome.resolve(input: "Unknown app", seeded: "Unknown app", sourceAppName: nil),
            .unchanged)
    }

    func testUnchangedExistingUserTitleIsNoChange() {
        XCTAssertEqual(
            RenameOutcome.resolve(input: " Mine ", seeded: "Mine", sourceAppName: "Safari"),
            .unchanged)
    }

    func testEmptyClears() {
        XCTAssertEqual(
            RenameOutcome.resolve(input: "   ", seeded: "Mine", sourceAppName: nil),
            .clear)
    }

    func testSourceAppNameClears() {
        XCTAssertEqual(
            RenameOutcome.resolve(input: "Safari", seeded: "Mine", sourceAppName: "Safari"),
            .clear)
    }

    func testNewTextIsTrimmedAndSet() {
        XCTAssertEqual(
            RenameOutcome.resolve(input: "  Invoice  ", seeded: "Unknown app", sourceAppName: nil),
            .set("Invoice"))
    }

    func testBatchCategoryMenuLabelWording() {
        XCTAssertEqual(BatchCategoryMenuLabel.title(count: 3, allowsMultipleCategories: false), "Move 3 to Category")
        XCTAssertEqual(BatchCategoryMenuLabel.title(count: 2, allowsMultipleCategories: true), "Add 2 to Category")
    }
}
