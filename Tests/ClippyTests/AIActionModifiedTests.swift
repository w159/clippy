import XCTest
@testable import Clippy

final class AIActionModifiedTests: XCTestCase {
    func testShippedBuiltInsAreNotModified() {
        for action in AIAction.builtIns { XCTAssertFalse(action.isModifiedFromDefault, action.name) }
    }

    func testReorderingIsNotAModification() {
        var action = AIAction.builtIns[0]
        action.sortOrder = 99
        XCTAssertFalse(action.isModifiedFromDefault)
    }

    func testEditedBuiltInIsModified() {
        var action = AIAction.builtIns[0]
        action.promptTemplate += " Be brief."
        XCTAssertTrue(action.isModifiedFromDefault)
        action = AIAction.builtIns[0]
        action.temperature = 0.9
        XCTAssertTrue(action.isModifiedFromDefault)
    }

    func testCustomActionIsNeverModified() {
        var action = AIAction.builtIns[0]
        action.id = UUID()
        action.isBuiltIn = false
        XCTAssertFalse(action.isModifiedFromDefault)
    }
}
