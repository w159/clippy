import SwiftUI

/// Hover/selection quick actions for `ClipCardView`, shown in place of the
/// metadata (crossfade, LAY-06) and folded into an overflow menu when narrow.
extension ClipCardView {
    /// Width-adaptive action row: full strip, pin/delete + overflow, or overflow only.
    var fittingHoverActions: some View {
        ViewThatFits(in: .horizontal) {
            hoverActions
            compactHoverActions
            overflowMenu(includePinAndDelete: true)
        }
    }

    var compactHoverActions: some View {
        HStack(spacing: 6) {
            overflowMenu(includePinAndDelete: false)
            cardActionButton(isPinned ? "pin.slash" : "pin", help: isPinned ? "Unpin" : "Pin", action: onTogglePin)
            cardActionButton("trash", help: "Delete", role: .destructive, action: onDelete)
        }
    }

    /// Mirrors `hoverActions` item-for-item so nothing is unreachable when narrow.
    func overflowMenu(includePinAndDelete: Bool) -> some View {
        Menu {
            if isFile {
                Button("Paste (Copy)", action: filePasteAction)
                Button("Reveal in Finder", action: fileRevealAction)
                if clip.contentText.lowercased().hasSuffix(".zip") { Button("Extract", action: fileExtractAction) }
            } else if !isImage && !model.isSensitive {
                if let aiMenu = aiMenuContent { Menu("AI Actions") { aiMenu() } }
                Button("Send as Keystrokes", action: onSendKeystrokes)
                Button("Edit", action: onEdit)
            }
            if isImage, let extract = onExtractText { Button("Extract Text", action: extract) }
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
    }

    var hoverActions: some View {
        HStack(spacing: 6) {
            if isFile {
                cardActionButton("arrow.down.to.line", help: "Paste (Copy)", action: filePasteAction)
                cardActionButton("arrow.up.right.square", help: "Reveal in Finder", action: fileRevealAction)
                if clip.contentText.lowercased().hasSuffix(".zip") {
                    cardActionButton("archivebox", help: "Extract", action: fileExtractAction)
                }
            } else if isImage {
                if let extract = onExtractText { cardActionButton("text.viewfinder", help: "Extract Text", action: extract) }
            } else if !model.isSensitive {
                if let aiMenu = aiMenuContent {
                    Menu { aiMenu() } label: {
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
                }
                cardActionButton("keyboard", help: "Send as keystrokes", action: onSendKeystrokes)
                cardActionButton("pencil", help: "Edit", action: onEdit)
            }
            cardActionButton("character.cursor.ibeam", help: "Rename", action: beginRename)
            cardActionButton(isPinned ? "pin.slash" : "pin", help: isPinned ? "Unpin" : "Pin", action: onTogglePin)
            Divider().frame(height: 14).padding(.horizontal, 2)
            cardActionButton("trash", help: "Delete", role: .destructive, action: onDelete)
        }
    }

    func cardActionButton(_ symbol: String, help: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(role == .destructive ? tokens.danger : tokens.textSecondary)
        .help(help)
        .accessibilityLabel(help)
    }
}
