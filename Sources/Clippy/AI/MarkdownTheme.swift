import SwiftUI
import MarkdownUI
import AppKit

extension MarkdownUI.Theme {
    /// A Markdown theme mapped onto Clippy's token + typography system so
    /// assistant replies match the panel, with real fenced code blocks.
    static func clippy(tokens: ThemeTokens, settings: AppSettings) -> MarkdownUI.Theme {
        // fontSizeBase is an Int (UserDefaults-backed); FontSize(_:) takes a
        // CGFloat, so convert before scaling to keep the arithmetic in CGFloat.
        let baseSize = CGFloat(settings.fontSizeBase)

        return MarkdownUI.Theme()
            .text {
                ForegroundColor(tokens.textPrimary)
                FontSize(baseSize)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(baseSize * 0.92)
                BackgroundColor(tokens.cardSurface)
            }
            .codeBlock { configuration in
                // Audit [POLISH]: overlay a copy button on fenced code blocks so
                // the user can copy a snippet without selecting across the block.
                ZStack(alignment: .topTrailing) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        configuration.label
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(baseSize * 0.92)
                                ForegroundColor(tokens.textPrimary)
                            }
                    }
                    CodeBlockCopyButton(text: configuration.content, tokens: tokens)
                        .padding(6)
                }
                .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tokens.cardBorder, lineWidth: 1))
                .markdownMargin(top: 6, bottom: 6)
            }
            .link {
                ForegroundColor(tokens.accent)
            }
    }
}

/// Copy-to-clipboard button overlaid on a markdown code block. Shows a brief
/// checkmark after copying so the click is acknowledged.
private struct CodeBlockCopyButton: View {
    let text: String
    let tokens: ThemeTokens
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Copy code")
        .accessibilityLabel(copied ? "Copied" : "Copy code")
    }
}
