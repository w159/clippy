import SwiftUI

/// One clipboard item rendered as a card (LAY-07, LAY-09): the content is the
/// headline, a slim kind-hue accent leads, and a single metadata row carries the
/// source app icon, kind glyph, badges and timestamp. Selection is the only
/// colored stroke. Everything the card shows arrives as values (`model`), so it
/// never observes `AppSettings` or a store (LAY-12).
struct ClipCardView: View {
    let clip: Clip
    let model: ClipCardModel
    /// Colors of the categories this clip belongs to (first three shown as dots).
    let categoryColors: [Color]
    /// First category the clip belongs to; its icon leads the metadata row.
    let pinnedCategory: Category?
    /// Active search text used to highlight matches in previews.
    let query: String

    let onActivate: () -> Void
    let onPaste: () -> Void
    let onPastePlain: () -> Void
    /// Types the clip text as keystrokes into the active app.
    let onSendKeystrokes: () -> Void
    let onEdit: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    /// Receives nil to clear a custom title.
    let onRename: (String?) -> Void
    let onExtractText: (() -> Void)?
    let onFindSimilar: (() -> Void)?
    let onPasteFile: (() -> Void)?
    let onMoveFile: (() -> Void)?
    let onRevealInFinder: (() -> Void)?
    let onExtractZip: (() -> Void)?
    /// Hover sparkles menu content (nil hides the button).
    let aiMenuContent: (() -> AnyView)?

    /// Read once per body, never observed: the parent re-renders on changes.
    let settings = AppSettings.shared
    @Environment(\.clippyTokens) var tokens
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var isHovering = false
    /// Thumbnail decoded off-main on a cache miss.
    @State var decodedThumbnail: NSImage?
    @Binding var isRenaming: Bool
    @ScaledMetric(relativeTo: .body) var placeholderIconSize: CGFloat = 24

    /// Actions stay reachable for keyboard users through selection.
    var showsActions: Bool { isHovering || model.isSelected }
    var iconSize: CGFloat { CGFloat(settings.fontSizeBase) + 1 }
    var isSelected: Bool { model.isSelected }
    var isPinned: Bool { model.isPinned }
    var isProcessingOCR: Bool { model.isOCRRunning }
    var kind: ClipKind { clip.kind }
    var isImage: Bool { clip.isImageLike }
    var isFile: Bool { clip.contentKind == .file && !clip.isImageLike }

    /// Creates a card. New parameters default so older call sites keep compiling.
    init(
        clip: Clip,
        model: ClipCardModel,
        categoryColors: [Color],
        pinnedCategory: Category?,
        query: String = "",
        isRenaming: Binding<Bool> = .constant(false),
        onActivate: @escaping () -> Void,
        onPaste: @escaping () -> Void,
        onPastePlain: @escaping () -> Void,
        onSendKeystrokes: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void,
        onExtractText: (() -> Void)? = nil,
        onFindSimilar: (() -> Void)? = nil,
        onPasteFile: (() -> Void)? = nil,
        onMoveFile: (() -> Void)? = nil,
        onRevealInFinder: (() -> Void)? = nil,
        onExtractZip: (() -> Void)? = nil,
        aiMenuContent: (() -> AnyView)? = nil
    ) {
        self.clip = clip
        self.model = model
        self.categoryColors = categoryColors
        self.pinnedCategory = pinnedCategory
        self.query = query
        self._isRenaming = isRenaming
        self.onActivate = onActivate
        self.onPaste = onPaste
        self.onPastePlain = onPastePlain
        self.onSendKeystrokes = onSendKeystrokes
        self.onEdit = onEdit
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
        self.onRename = onRename
        self.onExtractText = onExtractText
        self.onFindSimilar = onFindSimilar
        self.onPasteFile = onPasteFile
        self.onMoveFile = onMoveFile
        self.onRevealInFinder = onRevealInFinder
        self.onExtractZip = onExtractZip
        self.aiMenuContent = aiMenuContent
    }

    /// Bundle used by the shared accessibility contract.
    var rowActions: ClipRowActions {
        ClipRowActions(
            paste: onPaste, pastePlain: onPastePlain, togglePin: onTogglePin, delete: onDelete,
            beginRename: beginRename,
            edit: (clip.contentKind == .text && !model.isSensitive) ? onEdit : nil,
            extractText: clip.isImageLike ? onExtractText : nil,
            findSimilar: clip.contentKind == .text ? onFindSimilar : nil
        )
    }

    var body: some View {
        // Presentational (no Button): a Button would swallow the press and block
        // .draggable. Clicks are routed by the parent's tap gestures.
        HStack(spacing: 0) {
            if settings.cardStyle != .plain { accentBar }
            VStack(alignment: .leading, spacing: 6) {
                if showsTitleRow { titleRow }
                cardContent
                metadataRow
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(cardStroke)
        .animation(reduceMotion ? nil : ClippyMotion.animation(.quick, reduce: false), value: isHovering)
        .animation(reduceMotion ? nil : ClippyMotion.animation(.quick, reduce: false), value: model.isSelected)
        .contentShape(Rectangle())
        .onHover(perform: updateHover)
        // LAY-06: a resize can strand hover state on a card the pointer left.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in clearHover() }
        .onAppear { if model.isImageLike { OCRWarmupPolicy.shared.noteImageVisible() } }
        .onChange(of: model.isSelected) { _, selected in
            if selected, model.isImageLike { OCRWarmupPolicy.shared.noteImageVisible() }
        }
        .clipAccessibility(model: model, actions: rowActions)
    }

    private func updateHover(_ hovering: Bool) {
        isHovering = hovering
        if hovering, model.isImageLike { OCRWarmupPolicy.shared.noteImageVisible() }
        if hovering, NSCursor.current !== NSCursor.pointingHand {
            NSCursor.pointingHand.push()
        } else if !hovering, NSCursor.current === NSCursor.pointingHand {
            NSCursor.pop()
        }
    }

    private func clearHover() {
        guard isHovering else { return }
        isHovering = false
        if NSCursor.current === NSCursor.pointingHand { NSCursor.pop() }
    }
}
