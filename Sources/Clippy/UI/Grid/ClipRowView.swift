import SwiftUI

/// Compact (28pt) and comfortable (two-line, 42pt) clip row (LAY-08). Shares the
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
    /// Kind style, label and symbol from the preview classifier (code, rich text and email included).
    private let visual: ClipVisualKind
    private var hue: Color {
        if case .colorValue(let swatch) = kind { return swatch }
        return tokens.kind(visual.style)
    }
    /// Symbol drawn on a selected (filled) tile: white on the light-theme hues, near-black on the dark-theme pastels.
    private var onHue: Color { tokens.scheme == .dark ? Color.black.opacity(0.8) : Color.white }

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
        self.visual = model.isSensitive ? ClipVisualKind(style: .text, label: "Sensitive", symbol: "lock.fill")
            : ClipPreviewProvider.visual(for: clip)
        self._isRenaming = isRenaming
        self.onRename = onRename
    }

    var body: some View {
        HStack(spacing: 8) {
            leadingGlyph
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming { renameField } else { contentLine }
                if comfortable { metaLine }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutProbe("row.text")
            trailingSlot
        }
        .padding(.horizontal, 8)
        .padding(.vertical, comfortable ? 3 : 2)
        .overlay(alignment: .trailing) { hoverActionsOverlay }
        .frame(minHeight: comfortable ? GridMetrics.comfortableRowHeight : GridMetrics.compactRowHeight)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: Self.rowRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.rowRadius, style: .continuous)
                .strokeBorder(tokens.accent.opacity(0.7), lineWidth: model.isSelected ? 1.5 : 0)
        )
        .layoutProbe(comfortable ? "row.comfortable" : "row.compact")
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if !hovering { revealHeld = false }
            if hovering, model.isImageLike { OCRWarmupPolicy.shared.noteImageVisible() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in isHovering = false }
        .onDisappear { revealHeld = false }
        .onAppear { if model.isImageLike { OCRWarmupPolicy.shared.noteImageVisible() } }
        .animation(ClippyMotion.animation(.quick, reduce: reduceMotion), value: showsActions)
        .clipAccessibility(model: model, actions: actions)
    }

    // MARK: - Pieces

    /// Rows are rounded cards: calm elevated fill at rest, accent wash on hover and selection.
    static let rowRadius: CGFloat = 8

    private var rowBackground: Color {
        if model.isSelected { return tokens.accent.opacity(0.18) }
        return isHovering ? tokens.accent.opacity(0.10) : tokens.surfaceElevated
    }

    private var glyphSide: CGFloat { comfortable ? 28 : 20 }

    /// Source app icon, when icons are on and the app is known.
    private var appIcon: NSImage? {
        settings.showAppIcons ? AppIconProvider.shared.icon(forBundleID: clip.sourceAppBundleID) : nil
    }

    /// Comfortable rows: a 28pt rounded tile. App icon with a kind badge in its corner,
    /// or the kind symbol on a tile tinted with the kind color.
    private var kindTile: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return ZStack(alignment: .bottomTrailing) {
            if !model.isSensitive, let icon = appIcon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 28, height: 28)
                Image(systemName: visual.symbol)
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(onHue)
                    .frame(width: 11, height: 11)
                    .background(hue, in: Circle())
                    .offset(x: 2, y: 2)
            } else {
                shape.fill(tileFill)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: visual.symbol)
                            .font(.callout.weight(.semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(tileSymbol)
                    }
            }
        }
        .frame(width: 28, height: 28)
        .layoutProbe("row.tile")
        .accessibilityHidden(true)
        .help(visual.label)
    }

    /// Tinted by kind; filled with the kind color when the row is selected. Sensitive stays neutral.
    private var tileFill: Color {
        if model.isSensitive { return tokens.surfaceInset }
        return model.isSelected ? hue : hue.opacity(0.16)
    }

    private var tileSymbol: Color {
        if model.isSensitive { return tokens.textSecondary }
        return model.isSelected ? onHue : hue
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if comfortable, !(model.isImageLike && !model.isSensitive) {
            kindTile
        } else if model.isImageLike, !model.isSensitive {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(tokens.textSecondary)
                }
            }
            .frame(width: glyphSide, height: glyphSide)
            .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: comfortable ? 7 : ClippyRadius.xs, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: comfortable ? 7 : ClippyRadius.xs, style: .continuous))
            .task(id: clip.thumbFilename) {
                guard let name = clip.thumbFilename else { return }
                thumbnail = ClipCardView.cachedThumbnail(for: name)
                if thumbnail == nil { thumbnail = await ClipCardView.thumbnail(for: name) }
            }
        } else {
            Image(systemName: visual.symbol)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.isSensitive ? tokens.textSecondary : hue)
                .frame(width: 20, height: 20)
                .layoutProbe("row.glyph")
                .accessibilityHidden(true)
                .help(visual.label)
        }
    }

    @ViewBuilder
    private var contentLine: some View {
        if model.isSensitive {
            HStack(spacing: 6) {
                ClippyBadge("Sensitive")
                Text(MaskedTextLogic.isVisible(sensitive: true, revealHeld: revealHeld || model.isKeyRevealed)
                     ? clip.previewText.replacingOccurrences(of: "\n", with: " ")
                     : CardSensitivity.maskedLine(clip))
                    .foregroundStyle(tokens.textPrimary)
                    .lineLimit(1)
            }
            .font(PanelTypography.body(settings))
            .help("Hold to reveal, or press \u{21E7}\u{2318}R")
            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 12, pressing: { revealHeld = $0 }, perform: {})
        } else {
            let text = rowText
            Text(HighlightedPreview.attributed(text, query: query, color: tokens.accent))
                .font(PanelTypography.body(settings).weight(.medium))
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(1)
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
            if let name = clip.sourceAppName {
                Text(name).lineLimit(1)
                metaDot
            }
            Text(RelativeTime.string(for: clip.createdAt)).monospacedDigit().lineLimit(1).fixedSize()
            metaDot
            Text(visual.label).lineLimit(1)
            if model.matchedInOCR { ClippyBadge("OCR match") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var metaDot: some View {
        Text("\u{00B7}").accessibilityHidden(true)
    }

    private var renameField: some View {
        let seed = clip.userTitle ?? clip.displayTitle
        return SelectAllTextField(
            initialText: seed,
            font: PanelTypography.nsTitleFont(settings),
            textColor: NSColor(tokens.textPrimary),
            accessibilityLabel: "Rename clip",
            onCommit: { value in
                isRenaming = false
                switch RenameOutcome.resolve(input: value, seeded: seed, sourceAppName: clip.sourceAppName) {
                case .unchanged: break
                case .clear: onRename(nil)
                case .set(let title): onRename(title)
                }
            },
            onCancel: { isRenaming = false }
        )
        .frame(minHeight: 16)
    }

    // MARK: - Trailing slot (metadata crossfades with actions)

    private var trailingSlot: some View {
        ViewThatFits(in: .horizontal) {
            metadata(showApp: true)
            metadata(showApp: false)
        }
        .opacity(showsActions ? 0 : 1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(3)
    }

    /// Hover actions float over the row's trailing edge instead of reserving their width, so
    /// titles keep the full row; they sit on the row's own fill and cover the text beneath.
    private var hoverActionsOverlay: some View {
        hoverActions
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .background(tokens.surfaceElevated, in: RoundedRectangle(cornerRadius: Self.rowRadius, style: .continuous))
            .background(rowBackground, in: RoundedRectangle(cornerRadius: Self.rowRadius, style: .continuous))
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
    }

    private func metadata(showApp: Bool) -> some View {
        HStack(spacing: 6) {
            if showApp, !comfortable, let name = clip.sourceAppName {
                Text(name).font(PanelTypography.metadata(settings)).foregroundStyle(tokens.textSecondary).lineLimit(1).frame(maxWidth: 90)
            }
            if model.matchedInOCR, !comfortable { ClippyBadge("OCR") }
            if model.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(tokens.accentText)
                    .accessibilityHidden(true)
            }
            if let digit = model.quickPasteDigit { KeyCap("\u{2325}\u{2318}\(digit)") }
            if !comfortable {
                Text(RelativeTime.string(for: clip.createdAt))
                    .font(PanelTypography.metadata(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
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
                RowOverflowLabel()
            }
            .chromeMenuStyle()
            .help("More actions")
            .accessibilityLabel("More Actions")
            rowButton("trash", "Delete", actions.delete, destructive: true)
        }
    }

    private func rowButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void, destructive: Bool = false) -> some View {
        RowActionButton(systemImage: symbol, help: help, isDestructive: destructive, action: action)
    }
}
