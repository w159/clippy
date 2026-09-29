import XCTest
@testable import Clippy

final class TransformChainTests: XCTestCase {
    func testCompositionRunsInOrder() {
        let chain = TransformChain(ids: ["cleanup.trim", "case.upper", "base64.encode"])
        let result = chain.run("  hi ")
        XCTAssertEqual(result.intermediates, ["hi", "HI", "SEk="])
        XCTAssertEqual(result.output, "SEk=")
        XCTAssertNil(result.failedStep)
    }

    func testEmptyChainReturnsInput() {
        XCTAssertEqual(TransformChain().run("x").output, "x")
    }

    func testFailureStopsAtStep() {
        let result = TransformChain(ids: ["case.upper", "json.validate", "base64.encode"]).run("nope")
        XCTAssertEqual(result.failedStep, 1)
        XCTAssertNil(result.output)
        XCTAssertEqual(result.intermediates, ["NOPE"])
        XCTAssertNotNil(TransformChain(ids: ["json.validate"]).preview(for: "{").error)
    }

    func testUnknownIDsSkipped() {
        XCTAssertEqual(TransformChain(ids: ["nope", "case.lower"]).run("AB").output, "ab")
    }

    func testRegexCaptureGroupsAndSafetyCaps() throws {
        let swap = RegexReplaceTransform(pattern: "(\\w+)@(\\w+)", template: "$2 at $1")
        XCTAssertEqual(try swap.apply("joe@corp and amy@lab"), "corp at joe and lab at amy")
        XCTAssertEqual(try RegexReplaceTransform(pattern: "A", template: "b", ignoreCase: true).apply("aA"), "bb")
        XCTAssertThrowsError(try RegexReplaceTransform(pattern: "(", template: "").apply("x"))
        XCTAssertThrowsError(try RegexReplaceTransform(pattern: "", template: "").apply("x"))
        XCTAssertThrowsError(try RegexReplaceTransform(pattern: String(repeating: "a", count: 501), template: "").apply("x"))
        XCTAssertThrowsError(try RegexReplaceTransform(pattern: "a", template: "").apply(String(repeating: "a", count: 20_000)))
        let big = String(repeating: "a", count: RegexReplaceTransform.Limits.maxInputBytes + 1)
        XCTAssertThrowsError(try RegexReplaceTransform(pattern: "a", template: "b").apply(big))
        XCTAssertThrowsError(try RegexReplaceTransform(pattern: "(a+)+$", template: "", maxSeconds: 0.05)
            .apply(String(repeating: "a", count: 40) + "!")) {
            guard case .unsafePattern = $0 as? TransformError else { return XCTFail("wrong error \($0)") }
        }
    }
}
