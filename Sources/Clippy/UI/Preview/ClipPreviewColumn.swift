import SwiftUI

/// Metadata rows for the preview column, derived purely from the clip.
struct ClipPreviewMetadata: Equatable {
    /// Label/value rows in display order.
    var rows: [(label: String, value: String)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows.count == rhs.rows.count && zip(lhs.rows, rhs.rows).allSatisfy { $0 == $1 }
    }

    /// Builds rows: kind, source app, time, size, dimensions, OCR match. Sensitive clips expose kind and time only.
    static func make(for clip: Clip, item: ClipPreviewItem, query: String = "", now: Date = Date(),
                     sensitive: Bool, kindLabel: String? = nil) -> ClipPreviewMetadata {
        var rows: [(String, String)] = [("Kind", kindLabel ?? item.kindLabel)]
        if !sensitive, let app = clip.sourceAppName { rows.append(("Source", app)) }
        rows.append(("Copied", clip.createdAt.formatted(.relative(presentation: .named, unitsStyle: .wide))))
        guard !sensitive else { return ClipPreviewMetadata(rows: rows) }
        if let bytes = clip.byteSize { rows.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))) }
        if let width = clip.pixelWidth, let height = clip.pixelHeight { rows.append(("Dimensions", "\(width)\u{00D7}\(height)")) }
        let needle = query.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, let ocr = clip.ocrText, ocr.localizedCaseInsensitiveContains(needle) {
            rows.append(("OCR match", "Matches \u{201C}\(needle)\u{201D} in recognised text"))
        }
        return ClipPreviewMetadata(rows: rows)
    }
}

/// Optional right-hand preview column (LAY-11). Show it with
/// `PreviewColumnPreferences.isVisible(panelWidth:enabled:)`; the width is user-resizable and persisted.
struct ClipPreviewColumn: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let clip: Clip?
    var query: String = ""
    /// Called for the "Quick Look" action.
    var onQuickLook: (() -> Void)?
    /// Called for the "Paste" action.
    var onPaste: (() -> Void)?
    @State private var width = PreviewColumnPreferences.width()
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            resizeHandle
            content
                .frame(width: width)
                .background(tokens.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
        }
        .padding(.trailing, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var content: some View {
        if let clip {
            detail(for: clip)
                .transition(.opacity)
                .id(clip.id)
        } else {
            ContentUnavailableView("No Clip Selected", systemImage: "doc.on.clipboard",
                                   description: Text("Select a clip to preview it here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(for clip: Clip) -> some View {
        let sensitive = CardSensitivity.isSensitive(clip)
        let item = ClipPreviewProvider.item(for: clip, isSensitive: { _ in sensitive })
        let visual: ClipVisualKind? = sensitive ? nil : ClipPreviewProvider.visual(for: clip)
        let meta = ClipPreviewMetadata.make(for: clip, item: item, query: query, sensitive: sensitive, kindLabel: visual?.label)
        return VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
            header(for: clip, item: item, visual: visual)
            contentCard(item: item)
            metadataGrid(meta)
            actionBar(sensitive: sensitive)
        }
        .padding(tokens.metrics.space.four)
        .animation(ClippyMotion.animation(.quick, reduce: reduceMotion), value: clip.id)
    }

    /// 40pt kind tile, title (2 lines) and "App \u{00B7} time" subtitle.
    private func header(for clip: Clip, item: ClipPreviewItem, visual: ClipVisualKind?) -> some View {
        let hue: Color = {
            guard let visual else { return tokens.textSecondary }
            if case .colorValue(let swatch) = clip.kind { return swatch }
            return tokens.kind(visual.style)
        }()
        let time = RelativeTime.string(for: clip.createdAt)
        let subtitle = visual == nil ? time : [clip.sourceAppName, time].compactMap { $0 }.joined(separator: " \u{00B7} ")
        return HStack(alignment: .top, spacing: tokens.metrics.space.three) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(visual == nil ? tokens.surfaceInset : hue.opacity(0.18))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: visual?.symbol ?? "lock.fill")
                        .font(.title2.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(hue)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(for: clip, item: item, sensitive: visual == nil))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The user title, else the content's first line; never the content of a sensitive clip.
    static func title(for clip: Clip, item: ClipPreviewItem, sensitive: Bool) -> String {
        if sensitive { return "Sensitive clip" }
        if let title = clip.userTitle, !title.isEmpty { return title }
        switch item {
        case .image(_, let width, let height):
            let size = [width, height].compactMap { $0 }.map(String.init).joined(separator: "\u{00D7}")
            return size.isEmpty ? "Image" : "Image \(size)"
        case .file(_, let name): return name
        default: return clip.previewText.replacingOccurrences(of: "\n", with: " ")
        }
    }

    /// Content in a rounded card on the design-system surface that fills the free height.
    private func contentCard(item: ClipPreviewItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ScrollView { ClipPreviewView(item: item, lineLimit: 60, contentFontSize: 13) }
            .padding(tokens.metrics.space.three)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(0.05), in: shape)
    }

    private func metadataGrid(_ meta: ClipPreviewMetadata) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: tokens.metrics.space.three, verticalSpacing: tokens.metrics.space.one) {
            ForEach(Array(meta.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.label).font(.callout).foregroundStyle(.secondary)
                    Text(row.value).font(.callout).foregroundStyle(.primary)
                        .textSelection(.enabled).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Paste (accent-filled) and Quick Look (bordered) side by side.
    private func actionBar(sensitive: Bool) -> some View {
        HStack(spacing: tokens.metrics.space.two) {
            if let onPaste {
                Button(action: onPaste) {
                    Label("Paste", systemImage: "arrow.down.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(tokens.accent)
                .controlSize(.large)
                .accessibilityLabel("Paste selected clip")
            }
            if let onQuickLook, !sensitive {
                Button(action: onQuickLook) {
                    Label("Quick Look", systemImage: "eye").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityLabel("Quick Look selected clip")
            }
        }
    }

    private var resizeHandle: some View {
        Color.clear.frame(width: 8)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()).onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }.gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { drag in
                let base = dragStartWidth ?? width
                dragStartWidth = base
                width = PreviewColumnPreferences.clamp(base - drag.translation.width)
            }.onEnded { _ in
                dragStartWidth = nil
                PreviewColumnPreferences.setWidth(width)
            }))
    }
}
