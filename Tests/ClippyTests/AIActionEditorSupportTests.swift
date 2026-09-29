import XCTest
@testable import Clippy

final class AIActionEditorSupportTests: XCTestCase {
    func testVariablesMatchValidatorPlaceholders() {
        XCTAssertEqual(AIActionEditorSupport.variables.map(\.name), AIActionTemplateValidator.knownPlaceholders)
        XCTAssertEqual(AIActionEditorSupport.variables.first?.token, "{clip}")
    }

    func testInsertingPlacesVariableOnOwnLine() throws {
        let clip = try XCTUnwrap(AIActionEditorSupport.variables.first { $0.name == "clip" })
        XCTAssertEqual(AIActionEditorSupport.inserting(clip, into: ""), "{clip}")
        XCTAssertEqual(AIActionEditorSupport.inserting(clip, into: "Summarize:"), "Summarize:\n{clip}")
        XCTAssertEqual(AIActionEditorSupport.inserting(clip, into: "Summarize:\n"), "Summarize:\n{clip}")
    }

    func testInsertedVariableSatisfiesValidator() throws {
        let clip = try XCTUnwrap(AIActionEditorSupport.variables.first { $0.name == "clip" })
        let template = AIActionEditorSupport.inserting(clip, into: "Fix grammar:")
        XCTAssertTrue(AIActionEditorSupport.isUsed(clip, in: template))
        XCTAssertTrue(AIActionTemplateValidator.validate(template).isEmpty)
    }

    func testDispositionBadgesAreDistinct() {
        let badges = AIActionOutputDisposition.allCases.map(AIActionEditorSupport.dispositionBadge)
        XCTAssertEqual(Set(badges).count, badges.count)
    }

    func testTestPlaceholderStates() {
        XCTAssertEqual(AIActionEditorSupport.testPlaceholder(isTesting: true, hasClip: true), "Waiting for the model...")
        XCTAssertEqual(AIActionEditorSupport.testPlaceholder(isTesting: false, hasClip: false), "Choose a clip to test against.")
    }
}
