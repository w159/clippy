import SwiftUI
import MarkdownUI

extension MarkdownUI.Theme {
    /// Assistant reply theme built on semantic design tokens: primary text on the
    /// bubble surface, monospaced inset code blocks, accessible link color (AI-13).
    @MainActor
    static func clippyAssistant(tokens: ClippyTokens, baseSize: CGFloat) -> MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                ForegroundColor(tokens.textPrimary)
                FontSize(baseSize)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(baseSize * 0.92)
                BackgroundColor(tokens.surfaceInset)
            }
            .codeBlock { configuration in
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
                .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
                .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm).strokeBorder(tokens.stroke, lineWidth: 1))
                .markdownMargin(top: 6, bottom: 6)
            }
            .link {
                ForegroundColor(tokens.accentText)
                UnderlineStyle(.single)
            }
    }
}
