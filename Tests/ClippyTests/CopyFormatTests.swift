import XCTest
@testable import Clippy

final class CopyFormatTests: XCTestCase {
    func testCountedUsesSingularOnlyForOne() {
        XCTAssertEqual(CopyFormat.counted(1, "clip"), "1 clip")
        XCTAssertEqual(CopyFormat.counted(0, "clip"), "0 clips")
        XCTAssertEqual(CopyFormat.counted(2, "category", plural: "categories"), "2 categories")
    }
}
