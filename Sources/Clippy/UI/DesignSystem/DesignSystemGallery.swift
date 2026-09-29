import SwiftUI

/// #Preview gallery displaying the shared design-system components in every
/// interaction state; it uses a fixed light palette and never reads live clips.
struct DesignSystemGallery: View {
    @State private var selectedSegment = "Compact"
    @State private var filterSelected = true
    private let tokens = ClippyTokens.resolve(from: ThemePreset.cleanLight.fixedTokens!)
    private let states: [ControlState] = [.rest, .hover, .pressed, .selected, .focused, .disabled]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section("Tokens", detail: "Surface, type and status roles") {
                    HStack(spacing: 8) {
                        colorSwatch("surface", tokens.surface)
                        colorSwatch("elevated", tokens.surfaceElevated)
                        colorSwatch("inset", tokens.surfaceInset)
                        colorSwatch("sidebar", tokens.surfaceSidebar)
                        colorSwatch("accent", tokens.accent)
                    }
                    HStack(spacing: 12) {
                        Text("Primary").foregroundStyle(tokens.textPrimary)
                        Text("Secondary").foregroundStyle(tokens.textSecondary)
                        Text("Success").foregroundStyle(tokens.success)
                        Text("Warning").foregroundStyle(tokens.warning)
                        Text("Danger").foregroundStyle(tokens.danger)
                    }
                }
                section("Glass surfaces and filters", detail: "One sample per shared floating-control cluster") {
                    GlassCluster {
                        HStack(spacing: 8) {
                            ForEach(["All", "Text", "Images"], id: \.self) { item in
                                FilterChip(model: FilterChipModel(id: item, title: item, count: item == "All" ? 12 : nil), state: item == "Text" ? .selected : .rest) {}
                            }
                        }
                    }
                    ForEach(states, id: \.self) { state in
                        FilterChip(
                            model: FilterChipModel(id: state.label, title: "Filter · \(state.label)", systemImage: "line.3.horizontal.decrease", count: 3),
                            state: state
                        ) { filterSelected.toggle() }
                    }
                    ReasonChip(title: "Skipped: secure field", systemImage: "nosign", explanation: "Capture excluded by secure-field policy.")
                    ReasonChip(title: "OCR unavailable", systemImage: "text.viewfinder", state: .focused)
                }
                section("Buttons and keycaps", detail: "Hover, pressed, selected, focused and disabled") {
                    ForEach(states, id: \.self) { state in
                        HStack {
                            Text(state.label).frame(width: 76, alignment: .leading)
                            IconButton("pin", label: "Pin", state: state, glass: state == .rest) {}
                            SidebarRailItem("Library", systemImage: "tray.full", count: 12, selected: state == .selected, enabled: state != .disabled) {}
                            ClippyBadge("3", severity: .success)
                            KeyCap("⌘⇧V")
                        }
                    }
                    ClippySegmentedPicker("Density", selection: $selectedSegment, options: [
                        SegmentOption(value: "Compact", title: "Compact"),
                        SegmentOption(value: "Comfortable", title: "Comfortable"),
                        SegmentOption(value: "Cards", title: "Cards"),
                    ])
                    ClippySegmentedPicker(
                        "Disabled",
                        selection: $selectedSegment,
                        options: [SegmentOption(value: "Compact", title: "Compact"), SegmentOption(value: "Comfortable", title: "Comfortable")],
                        disabled: true
                    )
                }
                section("Messages", detail: "Safe status text only; no clipboard payloads") {
                    ForEach([BannerSeverity.neutral, .success, .warning, .danger], id: \.self) { severity in
                        ClippyToast("\(severity.label) notification", severity: severity, actionTitle: "Undo", action: {}) {}
                        ClippyBanner("\(severity.label) banner with a short explanation.", severity: severity, actionTitle: "Review", action: {}, dismiss: {})
                    }
                }
                section("Content states", detail: "Empty, busy, recoverable error and sheet chrome") {
                    EmptyState(systemImage: "tray", title: "Nothing copied yet", message: "New clips appear here.", actionTitle: "Settings") {}
                        .frame(height: 170)
                    LoadingState("Loading clips", rows: 3)
                    ErrorState(message: "The clipboard could not be read.", retry: {})
                    SettingsRow(title: "Appearance", detail: Text("Match your system setting")) { Toggle("Automatic", isOn: .constant(true)).labelsHidden() }
                    ClippySheet(title: "Preview sheet") { Text("System-provided presentation chrome.") }
                }
                section("Preview and sensitivity", detail: "Checkerboard alpha preview; masked text reveals only while held") {
                    PreviewCheckerboard { Image(systemName: "photo").resizable().scaledToFit().padding(16) }
                        .frame(width: 240, height: 100)
                    MaskedText("Never place sample client text in the gallery.", sensitive: true)
                        .frame(height: 56)
                    MaskedText("Non-sensitive sample text", sensitive: false)
                    HStack(spacing: 12) { Skeleton(width: 140); Skeleton(width: 70, height: 8) }
                }
            }
            .padding(24)
        }
        .frame(width: 640, height: 1000)
        .background(tokens.surface)
        .clippyTokens(tokens)
    }

    private func section<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(tokens.textPrimary)
            Text(detail).font(.caption).foregroundStyle(tokens.textSecondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    private func colorSwatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 58, height: 30)
            Text(name).font(.caption2).foregroundStyle(tokens.textSecondary)
        }
    }
}

private extension ControlState {
    var label: String {
        switch self {
        case .rest: return "Rest"
        case .hover: return "Hover"
        case .pressed: return "Pressed"
        case .selected: return "Selected"
        case .focused: return "Focused"
        case .disabled: return "Disabled"
        }
    }
}

private extension BannerSeverity {
    var label: String {
        switch self {
        case .neutral: return "Neutral"
        case .success: return "Success"
        case .warning: return "Warning"
        case .danger: return "Error"
        }
    }
}

#Preview("Clippy Design System") {
    DesignSystemGallery()
}
