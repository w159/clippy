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
                     sensitive: Bool) -> ClipPreviewMetadata {
        var rows: [(String, String)] = [("Kind", item.kindLabel)]
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
            content.frame(width: width)
        }
        .background(tokens.surfaceSidebar)
    }

    @ViewBuilder
    private var content: some View {
        if let clip {
            let sensitive = CardSensitivity.isSensitive(clip)
            let item = ClipPreviewProvider.item(for: clip, isSensitive: { _ in sensitive })
            let meta = ClipPreviewMetadata.make(for: clip, item: item, query: query, sensitive: sensitive)
            VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
                ScrollView { ClipPreviewView(item: item, lineLimit: 60) }
                Divider()
                ForEach(Array(meta.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).font(.caption).foregroundStyle(tokens.textSecondary).frame(width: 74, alignment: .leading)
                        Text(row.value).font(.caption).foregroundStyle(tokens.textPrimary).textSelection(.enabled)
                    }
                }
                HStack {
                    if let onQuickLook, !sensitive { Button("Quick Look", action: onQuickLook) }
                    if let onPaste { Button("Paste", action: onPaste) }
                }
            }
            .padding(tokens.metrics.space.three)
        } else {
            Text("Select a clip to preview").font(.callout).foregroundStyle(tokens.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var resizeHandle: some View {
        Rectangle().fill(tokens.stroke).frame(width: 1)
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
