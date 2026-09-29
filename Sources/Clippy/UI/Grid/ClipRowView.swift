import SwiftUI

/// Compact (~32pt) and comfortable (two-line) clip row (LAY-08). Shares the
/// model, accessibility contract and masking rules with `ClipCardView`.
struct ClipRowView: View {
    let clip: Clip
    let model: ClipCardModel
    let density: ClipDensity
    let query: String
    let actions: ClipRowActions
    let isPinnedCategoryIcon: Category?
    @Binding var isRenaming: Bool
    let onRename: (String?) -> Void

    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let settings = AppSettings.shared
    @State private var isHovering = false
    @State private var revealHeld = false
    @State private var thumbnail: NSImage?

    private var comfortable: Bool { density == .comfortable }
    private var showsActions: Bool { isHovering || model.isSelected }
    private var kind: ClipKind { clip.kind }
    private var hue: Color {
        if case .colorValue(let swatch) = kind { return swatch }
        return tokens.kind(ClipCardView.style(for: kind, clip: clip))
    }

    /// Creates a row for `density` (.compact or .comfortable).
    init(
        clip: Clip, model: ClipCardModel, density: ClipDensity, query: String, actions: ClipRowActions,
        pinnedCategory: Category? = nil, isRenaming: Binding<Bool> = .constant(false),
        onRename: @escaping (String?) -> Void = { _ in }
    ) {
        self.clip = clip
        self.model = model
        self.density = density
        self.query = query
        self.actions = actions
        self.isPinnedCategoryIcon = pinnedCategory
        self._isRenaming = isRenaming
        self.onRename = onRename
    }

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(hue).frame(width: 3).padding(.vertical, 6).accessibilityHidden(true)
            leadingGlyph
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming { renameField } else { contentLine }
                if comfortable { metaLine }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailingSlot
        }
        .padding(.trailing, 8)
        .frame(minHeight: comfortable ? 48 : GridMetrics.compactRowHeight)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.accent, lineWidth: model.isSelected ? 2 : 0)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if !hovering { revealHeld = false }
            if hovering, model.isImageLike { OCRWarmupPolicy.shared.noteImageVisible() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in isHovering = false }
        .onDisappear { revealHeld = false }
        .onAppear { if model.isImageLike { OCRWarmupPolicy.shared.noteImageVisible() } }
        .animation(reduceMotion ? nil : ClippyMotion.animation(.quick, reduce: false), value: showsActions)
        .clipAccessibility(model: model, actions: actions)
    }

    // MARK: - Pieces

    private var rowBackground: Color {
        model.isSelected ? tokens.selection : (isHovering ? tokens.textPrimary.opacity(0.06) : Color.clear)
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if model.isImageLike, !model.isSensitive {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(tokens.textSecondary)
                }
            }
            .frame(width: 24, height: 24)
            .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .task(id: clip.thumbFilename) {
                guard let name = clip.thumbFilename else { return }
                thumbnail = ClipCardView.cachedThumbnail(for: name)
                if thumbnail == nil { thumbnail = await ClipCardView.thumbnail(for: name) }
            }
        } else {
            Image(systemName: model.isSensitive ? "lock.fill" : kind.iconName)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.isSensitive ? tokens.textSecondary : hue)
                .frame(width: 24)
                .help(model.isSensitive ? "Sensitive" : kind.label)
        }
    }

    @ViewBuilder
    private var contentLine: some View {
        if model.isSensitive {
            HStack(spacing: 6) {
                ClippyBadge("Sensitive")
                Text(MaskedTextLogic.isVisible(sensitive: true, revealHeld: revealHeld)
                     ? clip.previewText.replacingOccurrences(of: "\n", with: " ")
                     : CardSensitivity.maskedLine(clip))
                    .foregroundStyle(tokens.textPrimary)
                    .lineLimit(1)
            }
            .font(PanelTypography.body(settings))
            .help("Hold to reveal")
            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 12, pressing: { revealHeld = $0 }, perform: {})
        } else {
            let text = rowText
            Text(HighlightedPreview.attributed(text, query: query, color: tokens.accent))
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(comfortable ? 2 : 1)
                .truncationMode(.tail)
        }
    }

    private var rowText: String {
        if let title = clip.userTitle { return title }
        if model.isImageLike {
            let size = [clip.pixelWidth, clip.pixelHeight].compactMap { $0 }.map(String.init).joined(separator: "\u{00D7}")
            return size.isEmpty ? "Image" : "Image \(size)"
        }
        if clip.contentKind == .file { return clip.contentText }
        return clip.previewText.replacingOccurrences(of: "\n", with: " ")
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if let name = clip.sourceAppName { Text(name).lineLimit(1) }
            Text(model.kindLabel)
            if model.matchedInOCR { ClippyBadge("OCR match") }
        }
        .font(PanelTypography.micro(settings))
        .foregroundStyle(tokens.textSecondary)
    }

    private var renameField: some View {
        SelectAllTextField(
            initialText: clip.userTitle ?? clip.displayTitle,
            font: PanelTypography.nsTitleFont(settings),
            textColor: NSColor(tokens.textPrimary),
            accessibilityLabel: "Rename clip",
            onCommit: { value in
                isRenaming = false
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                onRename(trimmed.isEmpty || trimmed == clip.sourceAppName ? nil : trimmed)
            },
            onCancel: { isRenaming = false }
        )
        .frame(minHeight: 18)
    }

    // MARK: - Trailing slot (metadata crossfades with actions)

    private var trailingSlot: some View {
        ZStack(alignment: .trailing) {
            ViewThatFits(in: .horizontal) {
                metadata(showApp: true)
                metadata(showApp: false)
            }
            .opacity(showsActions ? 0 : 1)
            hoverActions
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(3)
    }

    private func metadata(showApp: Bool) -> some View {
        HStack(spacing: 6) {
            if showApp, !comfortable, let name = clip.sourceAppName {
                Text(name).font(PanelTypography.metadata(settings)).foregroundStyle(tokens.textSecondary).lineLimit(1).frame(maxWidth: 90)
            }
            if model.matchedInOCR, !comfortable { ClippyBadge("OCR") }
            if model.isPinned { Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(tokens.accentText) }
            if let digit = model.quickPasteDigit { KeyCap("\u{2325}\u{2318}\(digit)") }
            Text(RelativeTime.string(for: clip.createdAt))
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            rowButton("arrow.down.doc", "Paste", actions.paste)
            rowButton(model.isPinned ? "pin.slash" : "pin", model.isPinned ? "Unpin" : "Pin", actions.togglePin)
            Menu {
                if let edit = actions.edit { Button("Edit", action: edit) }
                Button("Paste as Plain Text", action: actions.pastePlain)
                Button("Rename", action: actions.beginRename)
                if let extract = actions.extractText { Button("Extract Text", action: extract) }
                if let similar = actions.findSimilar { Button("Find Similar", action: similar) }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden)
            .foregroundStyle(tokens.textSecondary)
            .help("More actions")
            rowButton("trash", "Delete", actions.delete, destructive: true)
        }
    }

    private func rowButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(destructive ? tokens.danger : tokens.textSecondary)
        .help(help)
    }
}
