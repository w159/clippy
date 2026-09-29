import AppKit
import SwiftUI

/// Pixel size and alpha of the working image, computed once per change rather than per render.
struct ImageInfo: Equatable {
    let pixelSize: CGSize
    let hasAlpha: Bool

    init(image: NSImage?) {
        guard let image else {
            pixelSize = .zero
            hasAlpha = false
            return
        }
        if let cgImage = ImageEditing.cgImage(image) {
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
            switch cgImage.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
            default: hasAlpha = true
            }
        } else {
            pixelSize = image.size
            hasAlpha = false
        }
    }
}

/// Label formatting shared by the status bar and the info popover.
enum ImageInfoFormatter {
    /// "1,144 x 961" (locale grouping).
    static func dimensions(_ size: CGSize) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let width = formatter.string(from: NSNumber(value: Int(size.width))) ?? "\(Int(size.width))"
        let height = formatter.string(from: NSNumber(value: Int(size.height))) ?? "\(Int(size.height))"
        return "\(width) x \(height)"
    }

    /// "212 KB" file-style byte count.
    static func byteSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Upper-case format name from a file URL extension; "PNG" when unknown.
    static func formatName(for url: URL?) -> String {
        let ext = url?.pathExtension.uppercased() ?? ""
        return ext.isEmpty ? "PNG" : ext
    }
}

/// Popover listing dimensions, file size, format and transparency.
struct ImageInfoPopover: View {
    @Environment(\.clippyTokens) private var tokens
    let info: ImageInfo
    let byteSize: Int64?
    let format: String
    let isEdited: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.two) {
            Text("Image Info").font(.headline).foregroundStyle(tokens.textPrimary)
            row("Dimensions", ImageInfoFormatter.dimensions(info.pixelSize) + " px")
            row("File size", byteSize.map { ImageInfoFormatter.byteSize($0) + (isEdited ? " (before edits)" : "") } ?? "Unknown")
            row("Format", isEdited ? "\(format) (saved as PNG)" : format)
            row("Transparency", info.hasAlpha ? "Yes" : "No")
        }
        .padding(tokens.metrics.space.four)
        .frame(minWidth: 240, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(tokens.textSecondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(tokens.textPrimary).monospacedDigit()
        }
        .font(.callout)
    }
}

#Preview("Image info") {
    ImageInfoPopover(info: ImageInfo(image: nil), byteSize: 217_000, format: "PNG", isEdited: false).clippyDesignSystem()
}
