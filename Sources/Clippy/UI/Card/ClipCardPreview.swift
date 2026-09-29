import SwiftUI

/// Image preview for `ClipCardView`: the shared thumbnail `NSCache`, in-flight
/// decode de-duplication, off-main ImageIO decode and the OCR spinner scrim.
/// `ClipCardView.purgeThumbnailCache()` is called by AppDelegate on memory pressure.
extension ClipCardView {
    /// Body re-evaluates often (hover, selection); thumbnails come from this
    /// cache instead of disk after the first load.
    // nonisolated(unsafe): NSCache is documented thread-safe; the decode task
    // writes from off-main while body reads on the main actor.
    private nonisolated(unsafe) static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // Cap entry count so scrolling through a large history can't accumulate
        // hundreds of decompressed bitmaps in RAM (was the primary 4 GB cause).
        cache.countLimit = 200
        // 64 MB byte budget; cost is set per-object as pixelW*pixelH*4 bytes.
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Evict everything from the thumbnail cache. Called by the memory-pressure
    /// handler in AppDelegate so the OS can reclaim the decoded bitmap pages.
    static func purgeThumbnailCache() {
        thumbnailCache.removeAllObjects()
    }

    // Max pixel size for thumbnail decode. Cards render at maxHeight 72 @2x,
    // so 300 px is ample and avoids decompressing full-resolution originals.
    private nonisolated static let thumbnailMaxPixelSize = 300

    /// Cache-only lookup so body stays cheap; never touches disk.
    static func cachedThumbnail(for filename: String) -> NSImage? {
        thumbnailCache.object(forKey: filename as NSString)
    }

    /// In-flight decode tasks keyed by filename, so several cards appearing at
    /// once for the same image share one decode instead of racing. MainActor
    /// confined: every request originates from a view `.task` block.
    @MainActor
    private static var inflightDecodes: [String: Task<NSImage?, Never>] = [:]

    /// Async thumbnail load: cache hit, or join the in-flight decode, or start
    /// a new one. The synchronous ImageIO decode (ShouldCacheImmediately) used
    /// to run inside body on first appearance and stalled scrolling; it now
    /// runs on a detached background task.
    @MainActor
    static func thumbnail(for filename: String) async -> NSImage? {
        if let cached = cachedThumbnail(for: filename) { return cached }
        if let inflight = inflightDecodes[filename] { return await inflight.value }
        let decode = Task<NSImage?, Never>.detached(priority: .userInitiated) {
            decodeThumbnail(filename)
        }
        inflightDecodes[filename] = decode
        let image = await decode.value
        inflightDecodes[filename] = nil
        return image
    }

    // nonisolated: runs on the detached decode task, never on the main actor.
    // NSCache and ImageIO are thread-safe, so no isolation is needed.
    private nonisolated static func decodeThumbnail(_ filename: String) -> NSImage? {
        let key = filename as NSString
        let url = ClipDatabase.shared.media.url(for: filename)

        // Downsample at decode time via ImageIO so the decompressed bitmap is
        // small from the start; NSImage(contentsOf:) would decompress at full
        // resolution and hold the entire uncompressed image in the cache.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }

        let width = cgThumb.width
        let height = cgThumb.height
        let image = NSImage(cgImage: cgThumb,
                            size: NSSize(width: width, height: height))

        // Cost = estimated decoded bytes so the totalCostLimit budget is accurate.
        let cost = width * height * 4
        thumbnailCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    var imagePreview: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Consistent box, aspect-fit, checkerboard behind for alpha (LAY-10).
            PreviewCheckerboard(tileSize: 12) {
                if let filename = clip.thumbFilename,
                   let nsImage = Self.cachedThumbnail(for: filename) ?? decodedThumbnail {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: placeholderIconSize, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tokens.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: 220)
            .frame(height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .task(id: clip.thumbFilename) {
                guard let filename = clip.thumbFilename,
                      Self.cachedThumbnail(for: filename) == nil else { return }
                decodedThumbnail = nil
                decodedThumbnail = await Self.thumbnail(for: filename)
            }
            if let width = clip.pixelWidth, let height = clip.pixelHeight {
                Text("\(width)\u{00D7}\(height)")
                    .font(PanelTypography.micro(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .monospacedDigit()
            }
        }
        .overlay {
            if isProcessingOCR {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tokens.surfaceElevated.opacity(0.85))
                    .overlay {
                        VStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Extracting Text\u{2026}")
                                .font(PanelTypography.metadata(settings))
                                .foregroundStyle(tokens.textPrimary)
                        }
                    }
                    .transition(.opacity)
            }
        }
    }

    /// URL of the full-size media for Quick Look (LAY-11 hook); nil when the
    /// clip has none or the clip is sensitive.
    static func previewURL(for clip: Clip) -> URL? {
        guard !CardSensitivity.isSensitive(clip) else { return nil }
        if let path = clip.filePath, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        guard let name = clip.mediaFilename else { return nil }
        let url = ClipDatabase.shared.media.url(for: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - FEAT-14 rich preview hooks

/// Hooks for the card body (integrator wires them into `cardContent`): link metadata and highlighted code.
extension ClipCardView {
    /// Link card: title and icon only when link previews are opted in; never for sensitive clips.
    /// Falls back to the host/address layout otherwise, so it is safe to use for every link clip.
    @ViewBuilder
    var richLinkPreview: some View {
        if LinkPreviewPreferences.isEnabled, !model.isSensitive,
           let url = ClipPreviewProvider.singleLink(clip.previewText) {
            LinkPreviewCard(url: url)
        } else {
            linkPreview
        }
    }

    /// Syntax-highlighted code preview capped to `lines` lines (default 6); plain text preview when the text is not code.
    @ViewBuilder
    func richCodePreview(lines: Int = 6) -> some View {
        if !model.isSensitive, case .code(let text, let language, _) = ClipPreviewProvider.textItem(clip.contentText, lineLimit: lines) {
            Text(CodePreviewStyler.attributed(text, language: language, tokens: tokens))
                .font(.system(size: CGFloat(settings.fontSizeBase) - 1, design: .monospaced))
                .lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            textPreview
        }
    }
}
