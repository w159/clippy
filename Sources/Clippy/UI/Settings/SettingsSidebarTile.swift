import SwiftUI

// The colored rounded-square symbol tile shown beside each pane name, as in System Settings.

extension SettingsPaneID {
    /// Tile fill. System palette colors so the tiles adapt to light and dark.
    var tileColor: Color {
        switch self {
        case .general: return .gray
        case .appearance: return .blue
        case .capture: return .orange
        case .preview: return .teal
        case .pasteStack: return .indigo
        case .snippets: return .pink
        case .ai: return .purple
        case .intelligence: return .mint
        case .semantic: return .cyan
        case .security: return .red
        case .data: return .brown
        case .integrations: return .green
        case .automation: return .yellow
        case .scripts: return .gray
        case .ocr: return .teal
        case .editor: return .orange
        case .about: return .blue
        }
    }
}

/// A 26 pt rounded square with a white symbol on the pane color.
struct SettingsSidebarTile: View {
    let pane: SettingsPaneID

    var body: some View {
        Image(systemName: pane.icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(pane.tileColor.gradient, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
            .accessibilityHidden(true)
    }
}
