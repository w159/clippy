import XCTest
@testable import Clippy

final class ImageZoomMathTests: XCTestCase {
    func testFitScaleShrinksLargeImagesByLimitingAxis() {
        XCTAssertEqual(ImageZoomMath.fitScale(image: CGSize(width: 2000, height: 1000), viewport: CGSize(width: 500, height: 500)), 0.25)
        XCTAssertEqual(ImageZoomMath.fitScale(image: CGSize(width: 1000, height: 2000), viewport: CGSize(width: 500, height: 500)), 0.25)
    }

    func testFitScaleNeverUpscalesPastActualSize() {
        XCTAssertEqual(ImageZoomMath.fitScale(image: CGSize(width: 100, height: 50), viewport: CGSize(width: 800, height: 800)), 1)
    }

    func testFitScaleIsZeroForEmptyGeometry() {
        XCTAssertEqual(ImageZoomMath.fitScale(image: .zero, viewport: CGSize(width: 10, height: 10)), 0)
        XCTAssertEqual(ImageZoomMath.fitScale(image: CGSize(width: 10, height: 10), viewport: .zero), 0)
    }

    func testZoomStepsClampToRange() {
        XCTAssertEqual(ImageZoomMath.zoomedIn(from: 1), 1.25, accuracy: 0.0001)
        XCTAssertEqual(ImageZoomMath.zoomedIn(from: 8), ImageZoomMath.maximumScale)
        XCTAssertEqual(ImageZoomMath.zoomedOut(from: 0.05), ImageZoomMath.minimumScale)
    }

    func testDisplaySizeAndLabel() {
        XCTAssertEqual(ImageZoomMath.displaySize(image: CGSize(width: 200, height: 100), scale: 0.5), CGSize(width: 100, height: 50))
        XCTAssertEqual(ImageZoomMath.percentLabel(1), "100%")
        XCTAssertEqual(ImageZoomMath.percentLabel(0.333), "33%")
    }
}
