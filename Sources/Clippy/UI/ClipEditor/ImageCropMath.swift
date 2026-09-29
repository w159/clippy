import CoreGraphics
import Foundation

/// Aspect presets offered by the image editor crop bar (EDT-08).
enum CropAspect: String, CaseIterable, Identifiable {
    case free, square, fourThree, sixteenNine, threeTwo, original

    var id: String { rawValue }

    /// Short menu / chip title.
    var label: String {
        switch self {
        case .free: return "Free"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        case .threeTwo: return "3:2"
        case .original: return "Original"
        }
    }

    /// Width / height, or nil for a free crop. `imageSize` supplies `.original`.
    func ratio(imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .threeTwo: return 3.0 / 2.0
        case .original: return imageSize.height > 0 && imageSize.width > 0 ? imageSize.width / imageSize.height : nil
        }
    }
}

/// The eight grips around a crop rectangle.
enum CropHandle: CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var id: Self { self }

    /// Spoken name for VoiceOver.
    var label: String {
        switch self {
        case .topLeft: return "top left"
        case .top: return "top"
        case .topRight: return "top right"
        case .right: return "right"
        case .bottomRight: return "bottom right"
        case .bottom: return "bottom"
        case .bottomLeft: return "bottom left"
        case .left: return "left"
        }
    }

    var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
    fileprivate var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    fileprivate var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    fileprivate var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    fileprivate var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

/// Crop rectangle math in image space (y grows downward). Pure and clamped to
/// `[0, bounds]`, so a resize of the window or view never moves the selection.
enum CropGeometry {
    /// Smallest crop edge in image pixels.
    static let minimumSide: CGFloat = 8

    /// Centered starting selection covering 80% of the image, honoring `ratio`.
    static func initialRect(bounds: CGSize, ratio: CGFloat?) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        var width = bounds.width * 0.8
        var height = bounds.height * 0.8
        if let ratio, ratio > 0 {
            if width / height > ratio { width = height * ratio } else { height = width / ratio }
        }
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// Reshapes an existing selection to `ratio`, keeping its center and the
    /// largest area that fits inside both it and the image.
    static func applying(ratio: CGFloat?, to rect: CGRect, bounds: CGSize) -> CGRect {
        guard let ratio, ratio > 0, rect.width > 0, rect.height > 0 else { return rect }
        var width = rect.width
        var height = rect.height
        if width / height > ratio { width = height * ratio } else { height = width / ratio }
        let centered = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        return moved(centered, by: .zero, bounds: bounds)
    }

    /// Translates `rect` by `delta`, clamped so it stays inside the image.
    static func moved(_ rect: CGRect, by delta: CGSize, bounds: CGSize) -> CGRect {
        let maxX = max(0, bounds.width - rect.width)
        let maxY = max(0, bounds.height - rect.height)
        return CGRect(x: min(max(0, rect.minX + delta.width), maxX),
                      y: min(max(0, rect.minY + delta.height), maxY),
                      width: rect.width, height: rect.height)
    }

    /// Drags `handle` of `rect` to `point` (image space). The opposite edge or
    /// corner stays fixed; with `ratio` the aspect is preserved (edge grips
    /// grow symmetrically on the cross axis); the result never leaves `bounds`
    /// and never drops below `minimumSide` (or its aspect equivalent).
    static func resized(_ rect: CGRect, handle: CropHandle, to point: CGPoint, ratio: CGFloat?, bounds: CGSize) -> CGRect {
        let clamped = CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
        guard let ratio, ratio > 0 else { return freeResize(rect, handle, clamped, bounds) }
        return handle.isCorner ? lockedCorner(rect, handle, clamped, ratio, bounds) : lockedEdge(rect, handle, clamped, ratio, bounds)
    }

    private static func freeResize(_ rect: CGRect, _ handle: CropHandle, _ point: CGPoint, _ bounds: CGSize) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX = min(point.x, maxX - minimumSide) }
        if handle.movesRight { maxX = max(point.x, minX + minimumSide) }
        if handle.movesTop { minY = min(point.y, maxY - minimumSide) }
        if handle.movesBottom { maxY = max(point.y, minY + minimumSide) }
        minX = max(0, minX); minY = max(0, minY)
        maxX = min(bounds.width, maxX); maxY = min(bounds.height, maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func lockedCorner(_ rect: CGRect, _ handle: CropHandle, _ point: CGPoint, _ ratio: CGFloat, _ bounds: CGSize) -> CGRect {
        let anchor = CGPoint(x: handle.movesLeft ? rect.maxX : rect.minX, y: handle.movesTop ? rect.maxY : rect.minY)
        let signX: CGFloat = handle.movesLeft ? -1 : 1
        let signY: CGFloat = handle.movesTop ? -1 : 1
        let availableW = signX > 0 ? bounds.width - anchor.x : anchor.x
        let availableH = signY > 0 ? bounds.height - anchor.y : anchor.y
        var width = max(abs(point.x - anchor.x), abs(point.y - anchor.y) * ratio)
        width = max(width, minimumSide * max(1, ratio))
        width = min(width, availableW, availableH * ratio)
        let height = width / ratio
        return CGRect(x: signX > 0 ? anchor.x : anchor.x - width, y: signY > 0 ? anchor.y : anchor.y - height,
                      width: width, height: height)
    }

    private static func lockedEdge(_ rect: CGRect, _ handle: CropHandle, _ point: CGPoint, _ ratio: CGFloat, _ bounds: CGSize) -> CGRect {
        let horizontal = handle == .left || handle == .right
        if horizontal {
            let anchorX = handle == .right ? rect.minX : rect.maxX
            let availableW = handle == .right ? bounds.width - anchorX : anchorX
            let crossLimit = 2 * min(rect.midY, bounds.height - rect.midY) * ratio
            var width = abs(point.x - anchorX)
            width = min(max(width, minimumSide * max(1, ratio)), availableW, crossLimit)
            let height = width / ratio
            return CGRect(x: handle == .right ? anchorX : anchorX - width, y: rect.midY - height / 2, width: width, height: height)
        }
        let anchorY = handle == .bottom ? rect.minY : rect.maxY
        let availableH = handle == .bottom ? bounds.height - anchorY : anchorY
        let crossLimit = 2 * min(rect.midX, bounds.width - rect.midX) / ratio
        var height = abs(point.y - anchorY)
        height = min(max(height, minimumSide * max(1, 1 / ratio)), availableH, crossLimit)
        let width = height * ratio
        return CGRect(x: rect.midX - width / 2, y: handle == .bottom ? anchorY : anchorY - height, width: width, height: height)
    }

    /// Position of `handle` on `rect`.
    static func point(of handle: CropHandle, in rect: CGRect) -> CGPoint {
        let x = handle.movesLeft ? rect.minX : (handle.movesRight ? rect.maxX : rect.midX)
        let y = handle.movesTop ? rect.minY : (handle.movesBottom ? rect.maxY : rect.midY)
        return CGPoint(x: x, y: y)
    }

    /// Nearest grip within `tolerance` of `point` (same space as `rect`); corners win ties.
    static func hitHandle(at point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> CropHandle? {
        let ordered = CropHandle.allCases.sorted { $0.isCorner && !$1.isCorner }
        return ordered
            .map { ($0, hypot(self.point(of: $0, in: rect).x - point.x, self.point(of: $0, in: rect).y - point.y)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    /// Rule-of-thirds guide positions inside `rect`: two x values and two y values.
    static func thirds(in rect: CGRect) -> (xs: [CGFloat], ys: [CGFloat]) {
        ([rect.minX + rect.width / 3, rect.minX + rect.width * 2 / 3],
         [rect.minY + rect.height / 3, rect.minY + rect.height * 2 / 3])
    }

    /// "400x300 at 120,80" in whole pixels, for the status bar and VoiceOver.
    static func description(of rect: CGRect) -> String {
        "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded())) at \(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))"
    }
}
