import XCTest
@testable import Clippy

final class ImageCropMathTests: XCTestCase {
    private let bounds = CGSize(width: 400, height: 300)

    func testInitialRectCentersAndHonorsRatio() {
        let free = CropGeometry.initialRect(bounds: bounds, ratio: nil)
        XCTAssertEqual(free, CGRect(x: 40, y: 30, width: 320, height: 240))
        let square = CropGeometry.initialRect(bounds: bounds, ratio: 1)
        XCTAssertEqual(square.width, square.height, accuracy: 0.001)
        XCTAssertEqual(square.midX, 200, accuracy: 0.001)
        XCTAssertEqual(square.midY, 150, accuracy: 0.001)
    }

    func testFreeResizeMovesOnlyDraggedEdgesAndClamps() {
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        let out = CropGeometry.resized(rect, handle: .bottomRight, to: CGPoint(x: 900, y: 150), ratio: nil, bounds: bounds)
        XCTAssertEqual(out, CGRect(x: 100, y: 100, width: 300, height: 50))
        let edge = CropGeometry.resized(rect, handle: .left, to: CGPoint(x: -50, y: 999), ratio: nil, bounds: bounds)
        XCTAssertEqual(edge, CGRect(x: 0, y: 100, width: 200, height: 100))
    }

    func testResizeNeverCollapsesBelowMinimum() {
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        let out = CropGeometry.resized(rect, handle: .right, to: CGPoint(x: 90, y: 150), ratio: nil, bounds: bounds)
        XCTAssertEqual(out.width, CropGeometry.minimumSide)
        XCTAssertEqual(out.minX, 100)
    }

    func testLockedCornerKeepsAspectAndOppositeCorner() {
        let rect = CGRect(x: 50, y: 50, width: 160, height: 90)
        let out = CropGeometry.resized(rect, handle: .bottomRight, to: CGPoint(x: 250, y: 100), ratio: 16.0 / 9.0, bounds: bounds)
        XCTAssertEqual(out.minX, 50)
        XCTAssertEqual(out.minY, 50)
        XCTAssertEqual(out.width / out.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(out.width, 200, accuracy: 0.001)
    }

    func testLockedCornerClampsToImageEdgeKeepingAspect() {
        let rect = CGRect(x: 300, y: 200, width: 40, height: 40)
        let out = CropGeometry.resized(rect, handle: .bottomRight, to: CGPoint(x: 999, y: 999), ratio: 1, bounds: bounds)
        XCTAssertEqual(out.width, out.height, accuracy: 0.001)
        XCTAssertEqual(out.maxX, 400, accuracy: 0.001)
        XCTAssertLessThanOrEqual(out.maxY, 300)
        XCTAssertEqual(out.width, 100, accuracy: 0.001)
    }

    func testLockedEdgeGrowsSymmetricallyOnCrossAxis() {
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        let out = CropGeometry.resized(rect, handle: .right, to: CGPoint(x: 300, y: 0), ratio: 1, bounds: bounds)
        XCTAssertEqual(out.minX, 100)
        XCTAssertEqual(out.width, out.height, accuracy: 0.001)
        XCTAssertEqual(out.midY, rect.midY, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(out.minY, 0)
        XCTAssertLessThanOrEqual(out.maxY, 300)
    }

    func testMoveClampsInsideImage() {
        let rect = CGRect(x: 10, y: 10, width: 100, height: 50)
        XCTAssertEqual(CropGeometry.moved(rect, by: CGSize(width: -50, height: -50), bounds: bounds).origin, .zero)
        XCTAssertEqual(CropGeometry.moved(rect, by: CGSize(width: 999, height: 999), bounds: bounds).origin, CGPoint(x: 300, y: 250))
    }

    func testApplyingRatioKeepsCenterAndFitsBounds() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let out = CropGeometry.applying(ratio: 1, to: rect, bounds: bounds)
        XCTAssertEqual(out.size, CGSize(width: 300, height: 300))
        XCTAssertEqual(out.midX, 200, accuracy: 0.001)
    }

    func testOriginalAspectUsesImageSize() {
        XCTAssertEqual(CropAspect.original.ratio(imageSize: bounds)!, 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertNil(CropAspect.free.ratio(imageSize: bounds))
        XCTAssertNil(CropAspect.original.ratio(imageSize: .zero))
    }

    func testThirdsAndHandleHitTesting() {
        let rect = CGRect(x: 0, y: 0, width: 90, height: 60)
        let thirds = CropGeometry.thirds(in: rect)
        XCTAssertEqual(thirds.xs, [30, 60])
        XCTAssertEqual(thirds.ys, [20, 40])
        XCTAssertEqual(CropGeometry.hitHandle(at: CGPoint(x: 88, y: 3), in: rect, tolerance: 6), .topRight)
        XCTAssertEqual(CropGeometry.hitHandle(at: CGPoint(x: 45, y: 58), in: rect, tolerance: 6), .bottom)
        XCTAssertNil(CropGeometry.hitHandle(at: CGPoint(x: 45, y: 30), in: rect, tolerance: 6))
        XCTAssertEqual(CropHandle.allCases.count, 8)
    }
}
