import SwiftUI

/// Visual crop selection: dimmed surround, border, rule-of-thirds guides and eight grips.
/// Purely presentational; the canvas gesture owns interaction. `rect` is in the overlay's own space.
struct ImageCropOverlay: View {
    @Environment(\.clippyTokens) private var tokens
    @ScaledMetric(relativeTo: .caption) private var gripSize: CGFloat = 9
    let rect: CGRect
    let showsThirds: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                dim(in: proxy.size)
                Rectangle().strokeBorder(tokens.accentText, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                if showsThirds { thirds }
                ForEach(CropHandle.allCases) { handle in
                    let point = CropGeometry.point(of: handle, in: rect)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tokens.accent)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(tokens.onAccent, lineWidth: 1))
                        .frame(width: gripSize, height: gripSize)
                        .position(point)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func dim(in size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(rect)
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
    }

    private var thirds: some View {
        let lines = CropGeometry.thirds(in: rect)
        return Path { path in
            for lineX in lines.xs {
                path.move(to: CGPoint(x: lineX, y: rect.minY))
                path.addLine(to: CGPoint(x: lineX, y: rect.maxY))
            }
            for lineY in lines.ys {
                path.move(to: CGPoint(x: rect.minX, y: lineY))
                path.addLine(to: CGPoint(x: rect.maxX, y: lineY))
            }
        }
        .stroke(tokens.onAccent.opacity(0.75), lineWidth: 0.75)
    }
}

#Preview("Crop overlay") {
    ImageCropOverlay(rect: CGRect(x: 40, y: 30, width: 200, height: 120), showsThirds: true)
        .frame(width: 300, height: 200).background(Color.gray).clippyDesignSystem()
}
