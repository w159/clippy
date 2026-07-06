import SwiftUI

/// One clipboard item rendered as a card: colored edge stripe (per-app or
/// per-kind tint), source app icon, content-type badge, preview text or image
/// thumbnail, and hover-revealed quick actions. Selection draws an accent ring.
struct ClipCardView: View {
    let clip: Clip
    let isSelected: Bool
    let isPinned: Bool
    /// Colors of the categories this clip belongs to (first three shown as dots).
    let categoryColors: [Color]
    /// First category the clip belongs to (by sortOrder/createdAt). When set,
    /// its icon replaces the app icon and its color overrides the stripe color.
    let pinnedCategory: Category?

    /// Primary click action: pastes or copies depending on the click-mode setting.
    let onActivate: () -> Void
    let onPaste: () -> Void
    let onPastePlain: () -> Void
    /// Types the clip text as keystrokes into the active app.
    let onSendKeystrokes: () -> Void
    let onEdit: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    /// Called when the user commits a rename. Receives nil to clear a custom
    /// title and revert to the source app name.
    let onRename: (String?) -> Void

    // MARK: - File-clip action overrides (no-op defaults keep existing callers unchanged)
    // These let the parent supply custom implementations; when not supplied the
    // card performs the action itself via its private file-action methods below.
    let onPasteFile: (() -> Void)?
    let onMoveFile: (() -> Void)?
    let onRevealInFinder: (() -> Void)?
    let onExtractZip: (() -> Void)?

    /// Menu items for the hover sparkles button. Supplied by the parent (which
    /// owns the AI action dispatch) so the card shares the exact context-menu
    /// items; nil hides the button (AI off, or non-text clip). Type-erased to
    /// keep the card non-generic.
    let aiMenuContent: (() -> AnyView)?

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    /// Thumbnail decoded off the main thread on a cache miss. Body shows the
    /// placeholder until this lands; subsequent appearances hit the NSCache.
    @State private var decodedThumbnail: NSImage?

    /// When the quick-action buttons are visible and hit-testable. Basing this
    /// on selection (not just hover) makes the actions reachable for keyboard
    /// users, who navigate by moving the selection rather than hovering. The
    /// buttons themselves are real Buttons, so once visible they are
    /// keyboard-focusable and activatable with Space/Return.
    private var showsActions: Bool { isHovering || isSelected }
    // Dynamic Type: scale the placeholder glyph size with system text size.
    // The central PanelTypography fix belongs to Theme (owned separately); this
    // is a local adoption for fonts built directly in this view.
    @ScaledMetric(relativeTo: .body) private var placeholderIconSize: CGFloat = 24

    private var tokens: ThemeTokens { settings.theme }

    /// Icon point size derived from the user's base font so glyphs scale with
    /// text rather than staying fixed at 12/13/14pt.
    private var iconSize: CGFloat { CGFloat(settings.fontSizeBase) + 1 }
    /// Whether the title field is in inline-edit mode. Driven by the parent via
    /// isRenamingBinding so context-menu "Rename..." can trigger it externally.
    @Binding var isRenaming: Bool

    /// Convenience init for callers that do not need external rename control.
    init(
        clip: Clip,
        isSelected: Bool,
        isPinned: Bool,
        categoryColors: [Color],
        pinnedCategory: Category?,
        isRenaming: Binding<Bool> = .constant(false),
        onActivate: @escaping () -> Void,
        onPaste: @escaping () -> Void,
        onPastePlain: @escaping () -> Void,
        onSendKeystrokes: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void,
        onPasteFile: (() -> Void)? = nil,
        onMoveFile: (() -> Void)? = nil,
        onRevealInFinder: (() -> Void)? = nil,
        onExtractZip: (() -> Void)? = nil,
        aiMenuContent: (() -> AnyView)? = nil
    ) {
        self.clip = clip
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.categoryColors = categoryColors
        self.pinnedCategory = pinnedCategory
        self._isRenaming = isRenaming
        self.onActivate = onActivate
        self.onPaste = onPaste
        self.onPastePlain = onPastePlain
        self.onSendKeystrokes = onSendKeystrokes
        self.onEdit = onEdit
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
        self.onRename = onRename
        self.onPasteFile = onPasteFile
        self.onMoveFile = onMoveFile
        self.onRevealInFinder = onRevealInFinder
        self.onExtractZip = onExtractZip
        self.aiMenuContent = aiMenuContent
    }

    private var kind: ClipKind { clip.kind }
    private var isImage: Bool { clip.contentKind == .image }
    private var isFile: Bool { clip.contentKind == .file }

    private var cardColor: Color {
        // Pinned cards take the category color regardless of the global setting.
        if let category = pinnedCategory {
            return Color(hexString: category.colorHex)
        }
        switch settings.cardColorMode {
        case .byApp:
            return AppIconProvider.shared.dominantColor(forBundleID: clip.sourceAppBundleID) ?? kind.tint
        case .byKind:
            return kind.tint
        case .accent:
            return settings.accentColor
        case .neutral:
            return Color(nsColor: .systemGray)
        }
    }

    var body: some View {
        // Presentational card (no Button). A Button would capture the press and
        // its tap, blocking .draggable from ever starting. Clicks are routed at
        // the construction site via .onTapGesture, which composes with the
        // .draggable applied there. onActivate is no longer invoked here.
        HStack(spacing: 0) {
                // Color identity stripe; hidden in plain style (no chrome at all).
                if settings.cardStyle != .plain {
                    Rectangle()
                        .fill(cardColor)
                        .frame(width: 4)
                }

                VStack(alignment: .leading, spacing: 5) {
                    headerRow
                    if isImage {
                        imagePreview
                    } else if isFile {
                        filePreview
                    } else {
                        Text(clip.previewText)
                            .font(PanelTypography.body(settings))
                            .lineLimit(3)
                            .foregroundStyle(tokens.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if case .colorValue(let swatch) = kind {
                        swatchRow(swatch)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Constant-width base border so selection never reflows content. The
            // 1pt strokeBorder insets the same amount whether selected or not.
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(cardBorderColor, lineWidth: 1)
            )
            // Selection ring drawn on top as a centered stroke (no content inset),
            // so toggling selection shifts nothing.
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tokens.accent, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                // The whole card is clickable; show the hand cursor so that
                // affordance is discoverable. Guard against NSCursor stack
                // imbalance when the mouse moves directly between two cards
                // (card B's enter-push can land before card A's exit-pop): only
                // push when the current cursor is not already the pointing hand,
                // and only pop when the current cursor is the pointing hand.
                if hovering, NSCursor.current !== NSCursor.pointingHand {
                    NSCursor.pointingHand.push()
                } else if !hovering, NSCursor.current === NSCursor.pointingHand {
                    NSCursor.pop()
                }
            }
        // Whole card area hit-testable so taps land anywhere on the card.
        .contentShape(Rectangle())
        .help(kind.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        // Expose selection state so VoiceOver announces "selected" when the
        // card is in the active multi-selection (replicates CategorySidePane's
        // .isSelected pattern). Combined with .isButton above.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "selected" : "not selected")
        .accessibilityHint(isPinned ? "Pinned clip. Activate to paste." : "Activate to paste.")
    }

    private var accessibilitySummary: String {
        let content = isImage ? "Image" : isFile ? "File \(clip.contentText)" : clip.previewText
        return "\(clip.displayTitle), \(kind.label), \(content)\(isPinned ? ", pinned" : "")"
    }

    // MARK: - Pieces

    private var headerRow: some View {
        HStack(spacing: 6) {
            leadingIcon

            if isRenaming {
                titleEditor
            } else {
                titleLabel
            }

            Spacer(minLength: 4)

            // Keep category dots and rich-text/pin badges mounted during hover
            // so the card never loses context; only the timestamp moves out of
            // the way for the quick-action buttons. The badges stay visible at
            // reduced opacity so they do not fight the hover actions for
            // attention but are still readable. (Audit: hover swaps out dots
            // and rich indicator, losing persistent context.)
            HStack(spacing: 6) {
                categoryDots
                kindIndicator
                richIndicator
                pinBadge
                timestampText
                    .opacity(showsActions ? 0 : 1)
            }
            .opacity(showsActions ? 0.35 : 1)
        }
        // minHeight lets the row grow with larger fonts instead of clipping.
        .frame(minHeight: 20)
        // Quick actions render as a trailing overlay instead of a layout
        // sibling: the old ZStack kept the (hidden) action row in the size
        // calculation, giving every card a ~200pt minimum width that made
        // 3-4 column grids overflow their cells and collide. An overlay costs
        // zero layout width, and ViewThatFits swaps in a compact variant when
        // the card is narrower than the full button row.
        .overlay(alignment: .trailing) {
            fittingHoverActions
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
        }
    }

    /// Icon slot: shows the pinned category's icon when the clip is categorized,
    /// otherwise the source app icon (or a placeholder when icons are off).
    @ViewBuilder
    private var leadingIcon: some View {
        if let category = pinnedCategory {
            categoryIcon(category)
                .frame(width: 16, height: 16)
        } else if settings.showAppIcons,
                  let icon = AppIconProvider.shared.icon(forBundleID: clip.sourceAppBundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: iconSize))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.textSecondary)
                .frame(width: 16, height: 16)
        }
    }

    /// Renders any of the three category icon kinds, matching CategorySidePane.
    @ViewBuilder
    private func categoryIcon(_ category: Category) -> some View {
        switch category.iconKind {
        case .symbol:
            Image(systemName: category.iconValue)
                .font(.system(size: iconSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(hexString: category.colorHex))
        case .emoji:
            Text(category.iconValue)
                .font(.system(size: iconSize + 1))
        case .appLogo:
            if let icon = AppIconProvider.shared.icon(forBundleID: category.iconValue) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: iconSize))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.textSecondary)
            }
        }
    }

    /// The title text shown in normal (non-editing) state. No double-click
    /// rename here: single-click on the card pastes (fast-paste design), so a
    /// double-click would fire a paste on its first click. Rename is reachable
    /// via the hover pencil-cursor button and the context-menu "Rename...".
    private var titleLabel: some View {
        Text(clip.displayTitle)
            .font(PanelTypography.title(settings))
            .foregroundStyle(settings.highContrastCardText ? tokens.textPrimary : tokens.textSecondary)
            .lineLimit(1)
    }

    /// Inline rename field. The background is the standard editable-field color
    /// (white in light themes, dark in dark themes), which contrasts the card
    /// face so the field reads unmistakably as a text entry. Focus and full
    /// selection happen automatically via SelectAllTextField.
    private var titleEditor: some View {
        SelectAllTextField(
            initialText: clip.userTitle ?? clip.displayTitle,
            font: PanelTypography.nsTitleFont(settings),
            textColor: NSColor(tokens.textPrimary),
            accessibilityLabel: "Rename clip",
            onCommit: { commitRename($0) },
            onCancel: { cancelRename() }
        )
        // minHeight, not a fixed height, so larger fonts are not clipped.
        .frame(minHeight: 18)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        // Opposite-luminance fill so the field never blends into the card:
        // a dark tint on light themes, a light tint on dark themes.
        .background(renameFieldFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(tokens.accent, lineWidth: 1.5)
        )
    }

    private var renameFieldFill: Color {
        // Theme-derived fill so the rename field never relies on hardcoded
        // Color.white/Color.black (which bypassed the token system and could
        // break custom themes). Uses the primary text color at low opacity: on
        // dark themes textPrimary is light so the field reads as a light tint
        // on the dark card; on light themes textPrimary is dark so the field
        // reads as a dark tint on the light card. Opposite-luminance is
        // preserved without hardcoded Color literals.
        tokens.textPrimary.opacity(tokens.isDark ? 0.16 : 0.08)
    }

    private func beginRename() {
        isRenaming = true
    }

    private func commitRename(_ value: String) {
        isRenaming = false
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty, or unchanged-from-the-app-name, clears the custom title.
        if trimmed.isEmpty || trimmed == clip.sourceAppName {
            onRename(nil)
        } else {
            onRename(trimmed)
        }
    }

    private func cancelRename() {
        isRenaming = false
    }

    // MARK: - File-clip actions

    /// Resolves the best URL for the file clip: live original first, stored copy second.
    private var resolvedFileURL: URL? {
        if let path = clip.filePath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let mediaFilename = clip.mediaFilename else { return nil }
        let stored = ClipDatabase.shared.media.url(for: mediaFilename)
        return FileManager.default.fileExists(atPath: stored.path) ? stored : nil
    }

    private func filePasteAction() {
        if let override = onPasteFile { override(); return }
        // Paste directly: write the URL to the pasteboard (no keystroke; the
        // panel dismiss gives focus back, then the user can Cmd+V manually, or
        // the parent wires a real PasteService call via onPasteFile).
        guard let url = resolvedFileURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        (url as NSURL).write(to: pb)
    }

    private func fileRevealAction() {
        if let override = onRevealInFinder { override(); return }
        guard let url = resolvedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func fileMoveAction() {
        if let override = onMoveFile { override(); return }
        // Move is only meaningful with Accessibility permission; the parent
        // should supply onMoveFile wired to PasteService.pasteFile(_:move:true).
        filePasteAction()
    }

    private func fileExtractAction() {
        if let override = onExtractZip { override(); return }
        guard let archiveURL = resolvedFileURL else { return }
        let name = archiveURL.deletingPathExtension().lastPathComponent
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let destDir = downloads.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", archiveURL.path, destDir.path]
        proc.terminationHandler = { p in
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    NSWorkspace.shared.activateFileViewerSelecting([destDir])
                }
                // Failure is silently swallowed; no partial state to clean up.
            }
        }
        try? proc.run()
    }

    // MARK: - Trailing metadata pieces
    // Split out from the former single trailingMetadata so the hover behavior
    // can keep the contextual badges mounted while hiding only the timestamp.

    private var categoryDots: some View {
        ForEach(Array(categoryColors.prefix(3).enumerated()), id: \.offset) { _, color in
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
        }
    }

    private var kindIndicator: some View {
        Image(systemName: kind.iconName)
            .font(.system(size: iconSize, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(kind.tint)
    }

    private var richIndicator: some View {
        Group {
            if clip.isRich {
                Image(systemName: "textformat")
                    .font(.system(size: iconSize))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.textSecondary)
                    .help("Has rich formatting")
            }
        }
    }

    private var pinBadge: some View {
        Group {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: iconSize))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.accent)
                    // Bounce when a card becomes pinned so the toggle is felt.
                    .symbolEffect(.bounce, value: reduceMotion ? false : isPinned)
            }
        }
    }

    private var timestampText: some View {
        Text(clip.createdAt, format: Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .narrow))
            .font(PanelTypography.metadata(settings))
            .foregroundStyle(tokens.textSecondary)
            .monospacedDigit()
    }

    /// Width-adaptive action row: the full button strip when the card is wide
    /// enough, a pin/delete pair plus overflow menu when it is not, and a lone
    /// overflow menu as the last resort on very narrow cards.
    private var fittingHoverActions: some View {
        ViewThatFits(in: .horizontal) {
            hoverActions
            compactHoverActions
            overflowMenu(includePinAndDelete: true)
        }
    }

    /// Compact variant for narrow grid cards: keeps the two highest-traffic
    /// actions as direct buttons and folds the rest into an overflow menu.
    private var compactHoverActions: some View {
        HStack(spacing: 6) {
            overflowMenu(includePinAndDelete: false)
            cardActionButton(
                isPinned ? "pin.slash" : "pin",
                help: isPinned ? "Unpin" : "Pin",
                action: onTogglePin
            )
            cardActionButton("trash", help: "Delete", role: .destructive, action: onDelete)
        }
    }

    /// Overflow menu carrying the actions that lost their dedicated buttons in
    /// the compact layouts. Mirrors hoverActions item-for-item so nothing is
    /// unreachable at any card width.
    private func overflowMenu(includePinAndDelete: Bool) -> some View {
        Menu {
            if isFile {
                Button("Paste (Copy)", action: filePasteAction)
                Button("Reveal in Finder", action: fileRevealAction)
                if clip.contentText.lowercased().hasSuffix(".zip") {
                    Button("Extract", action: fileExtractAction)
                }
            } else if !isImage {
                if let aiMenu = aiMenuContent {
                    Menu("AI Actions") { aiMenu() }
                }
                Button("Send as Keystrokes", action: onSendKeystrokes)
                Button("Edit", action: onEdit)
            }
            Button("Rename", action: beginRename)
            if includePinAndDelete {
                Button(isPinned ? "Unpin" : "Pin", action: onTogglePin)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: iconSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .foregroundStyle(tokens.textSecondary)
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            if isFile {
                // File-clip quick actions: paste (copy), reveal, extract for zips.
                cardActionButton("arrow.down.to.line", help: "Paste (Copy)", action: filePasteAction)
                cardActionButton("arrow.up.right.square", help: "Reveal in Finder", action: fileRevealAction)
                if clip.contentText.lowercased().hasSuffix(".zip") {
                    cardActionButton("archivebox", help: "Extract", action: fileExtractAction)
                }
            } else if !isImage {
                // AI actions menu, same items as the right-click AI submenu.
                // Menu content comes from the parent so dispatch stays in one place.
                if let aiMenu = aiMenuContent {
                    Menu {
                        aiMenu()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: iconSize, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .foregroundStyle(tokens.textSecondary)
                    .help("AI actions")
                    .accessibilityLabel("AI actions")
                }
                // "Paste as plain text" is still reachable via the context menu;
                // this slot is now the quicker "send as keystrokes" action.
                cardActionButton("keyboard", help: "Send as keystrokes", action: onSendKeystrokes)
                cardActionButton("pencil", help: "Edit", action: onEdit)
            }
            cardActionButton("character.cursor.ibeam", help: "Rename", action: beginRename)
            cardActionButton(
                isPinned ? "pin.slash" : "pin",
                help: isPinned ? "Unpin" : "Pin",
                action: onTogglePin
            )
            // Visually separate the destructive action so Delete is not packed
            // flush against Pin where a misclick is easy.
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            cardActionButton("trash", help: "Delete", role: .destructive, action: onDelete)
        }
    }

    private func cardActionButton(
        _ symbol: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                // Larger hit target than the glyph; contentShape makes the whole
                // frame clickable, not just the opaque pixels.
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
                // Cross-fade when a button's glyph swaps in place (pin <-> pin.slash).
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(role == .destructive ? tokens.danger : tokens.textSecondary)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Body re-evaluates often (hover, selection); thumbnails come from this
    /// cache instead of disk after the first load.
    // nonisolated(unsafe): NSCache is documented thread-safe; the decode task
    // writes from off-main while body reads on the main actor.
    private nonisolated(unsafe) static let thumbnailCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // Cap entry count so scrolling through a large history can't accumulate
        // hundreds of decompressed bitmaps in RAM (was the primary 4 GB cause).
        c.countLimit = 200
        // 64 MB byte budget; cost is set per-object as pixelW*pixelH*4 bytes.
        c.totalCostLimit = 64 * 1024 * 1024
        return c
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
    private static func cachedThumbnail(for filename: String) -> NSImage? {
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
    private static func thumbnail(for filename: String) async -> NSImage? {
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

        let w = cgThumb.width
        let h = cgThumb.height
        let image = NSImage(cgImage: cgThumb,
                            size: NSSize(width: w, height: h))

        // Cost = estimated decoded bytes so the totalCostLimit budget is accurate.
        let cost = w * h * 4
        thumbnailCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    private var imagePreview: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if let filename = clip.thumbFilename,
                   let nsImage = Self.cachedThumbnail(for: filename) ?? decodedThumbnail {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 72, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: placeholderIconSize, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tokens.textSecondary)
                        .frame(width: 72, height: 48)
                }
            }
            // Cache miss: decode off-main and publish into @State to re-render.
            // Keyed by filename so an image edit that repoints the clip's thumb
            // refires the decode instead of showing the stale bitmap.
            .task(id: clip.thumbFilename) {
                guard let filename = clip.thumbFilename,
                      Self.cachedThumbnail(for: filename) == nil else { return }
                decodedThumbnail = nil
                decodedThumbnail = await Self.thumbnail(for: filename)
            }
            if let width = clip.pixelWidth, let height = clip.pixelHeight {
                Text("\(width)\u{00D7}\(height) PNG")
                    .font(PanelTypography.micro(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    private var filePreview: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: clip.contentText.hasSuffix(".zip") ? "doc.zipper" : "doc")
                .font(.system(size: placeholderIconSize, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(kind.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.contentText)
                    .font(PanelTypography.body(settings))
                    .lineLimit(2)
                    .foregroundStyle(tokens.textPrimary)
                if let byteSize = clip.byteSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file))
                        .font(PanelTypography.micro(settings))
                        .foregroundStyle(tokens.textSecondary)
                        .monospacedDigit()
                }
                // Reference-only badge: stored bytes not available.
                if clip.mediaFilename == nil {
                    Text("Path reference only")
                        .font(PanelTypography.micro(settings))
                        .foregroundStyle(tokens.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func swatchRow(_ swatch: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(swatch)
                .frame(width: 38, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(tokens.cardBorder, lineWidth: 1)
                )
            Text(clip.contentText)
                .font(PanelTypography.micro(settings))
                .foregroundStyle(tokens.textSecondary)
                .lineLimit(1)
        }
        .accessibilityLabel("Color \(clip.contentText)")
    }

    /// Tint fraction as a 0-1 Double from the 0-20 integer setting.
    private var tintFraction: Double {
        Double(settings.cardTintStrength) / 100.0
    }

    private var cardBorderColor: Color {
        // Selection is drawn by a separate overlay ring, so the base border keeps
        // its normal per-style color even when selected (no width change here).
        switch settings.cardStyle {
        case .filled:
            return tokens.cardBorder
        case .bordered:
            // Bordered: use the identity color as the border so cards are visually
            // distinct even without a filled background.
            return cardColor.opacity(0.6)
        case .plain:
            return .clear
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        switch settings.cardStyle {
        case .filled:
            ZStack {
                // Opaque themed card face: always readable, never washed out.
                tokens.cardSurface
                // Identity tint from the user-controlled strength setting.
                LinearGradient(
                    colors: [cardColor.opacity(tintFraction * (isHovering ? 2 : 1)), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                if isHovering {
                    tokens.textPrimary.opacity(0.05)
                }
            }
        case .bordered:
            ZStack {
                Color.clear
                if isHovering {
                    tokens.textPrimary.opacity(0.05)
                }
            }
        case .plain:
            Color.clear
                .overlay(isHovering ? tokens.textPrimary.opacity(0.06) : Color.clear)
        }
    }
}
