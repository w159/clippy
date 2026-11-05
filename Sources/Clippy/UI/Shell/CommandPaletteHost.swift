import SwiftUI

/// Centered glass overlay for the Cmd+K command palette (screens section 4).
/// Fuzzy filter via `PaletteRanker`, keyboard navigation (Up/Down, Return runs,
/// Escape closes) and VoiceOver labels. Commands are supplied by the caller.
struct CommandPaletteHost: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool
    @State private var query = ""
    @State private var highlighted = 0
    @State private var hovered: Int?
    @State private var didRun = false
    @State private var recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
    private static let recentsKey = "commandPalette.recents"

    /// Commands offered; disabled ones are filtered out by the ranker.
    let commands: [any PaletteCommand]
    /// Closes the palette.
    let onDismiss: () -> Void

    private var layout: PaletteLayout { PaletteLayout.build(commands, query: query, recents: recents) }
    private var results: [any PaletteCommand] { layout.flat }

    var body: some View {
        ZStack {
            // Elevation shadow color dims in both themes; textPrimary lightened dark panels.
            tokens.metrics.elevation.color
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            GlassSurface(in: RoundedRectangle(cornerRadius: ClippyRadius.xl, style: .continuous)) {
                VStack(spacing: tokens.metrics.space.two) {
                    searchField
                    resultList
                    hintBar
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .frame(maxWidth: 560, maxHeight: 440)
            .padding(tokens.metrics.space.four)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel("Command palette")
        }
        .transition(.opacity)
        .onAppear { query = ""; highlighted = 0; hovered = nil; didRun = false; fieldFocused = true }
        .onExitCommand(perform: onDismiss)
        .onChange(of: query) { _, _ in highlighted = 0; hovered = nil }
        .onChange(of: results.map(\.id)) { _, _ in highlighted = 0; hovered = nil }
    }

    private var searchField: some View {
        HStack(spacing: tokens.metrics.space.two) {
            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Type a command", text: $query)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($fieldFocused)
                .accessibilityLabel("Command search")
                .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
            KeyCap("esc")
        }
        .padding(.horizontal, tokens.metrics.space.three)
        .padding(.vertical, tokens.metrics.space.two)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var resultList: some View {
        let layout = layout
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if layout.groups.isEmpty {
                        ContentUnavailableView.search
                            .frame(maxWidth: .infinity)
                            .padding(tokens.metrics.space.three)
                    }
                    ForEach(Array(layout.groups.enumerated()), id: \.offset) { _, group in
                        if let title = group.title {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, tokens.metrics.space.three)
                                .padding(.top, tokens.metrics.space.two)
                                .padding(.bottom, tokens.metrics.space.one)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(Array(group.commands.enumerated()), id: \.offset) { offset, command in
                            let index = group.startIndex + offset
                            row(command, selected: index == highlighted, hovered: index == hovered,
                                showsContext: group.title != command.section.rawValue)
                                .id(index)
                                .onTapGesture { run(command) }
                                .onHover { inside in
                                    if inside { hovered = index } else if hovered == index { hovered = nil }
                                }
                        }
                    }
                }
                .padding(.horizontal, tokens.metrics.space.one)
            }
            .onChange(of: highlighted) { _, value in
                withAnimation(ClippyMotion.animation(.instant, reduce: reduceMotion)) { proxy.scrollTo(value) }
            }
        }
    }

    private func row(_ command: any PaletteCommand, selected: Bool, hovered: Bool, showsContext: Bool) -> some View {
        HStack(spacing: tokens.metrics.space.three) {
            Image(systemName: command.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(selected ? tokens.onAccent : tokens.accentText)
                .frame(width: 30, height: 30)
                .background(selected ? Color.white.opacity(0.2) : tokens.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(command.title).font(.body).foregroundStyle(selected ? tokens.onAccent : tokens.textPrimary)
                if let subtitle = command.subtitle {
                    Text(subtitle).font(.caption)
                        .foregroundStyle(selected ? tokens.onAccent.opacity(0.85) : tokens.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: tokens.metrics.space.two)
            if showsContext {
                Text(command.section.rawValue).font(.caption)
                    .foregroundStyle(selected ? tokens.onAccent.opacity(0.85) : tokens.textSecondary)
            }
            if let shortcut = command.shortcut {
                HStack(spacing: 2) {
                    ForEach(Array(PaletteLayout.keyCaps(for: shortcut).enumerated()), id: \.offset) { _, cap in KeyCap(cap) }
                }
            }
        }
        .padding(.horizontal, tokens.metrics.space.two)
        .padding(.vertical, tokens.metrics.space.one + 2)
        .background(selected ? tokens.accent : (hovered ? Color.primary.opacity(0.08) : .clear),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(command.title)
        .accessibilityValue(command.shortcut ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { run(command) }
    }

    private var hintBar: some View {
        let hasRows = !results.isEmpty
        return HStack(spacing: tokens.metrics.space.three) {
            if hasRows {
                hint("\u{2191}\u{2193}", "navigate")
                hint("\u{21A9}", "select")
            }
            hint("esc", "close")
            if layout.sectionStarts.count > 1 { hint("\u{21E5}", "next section") }
            Spacer()
        }
        .padding(.horizontal, tokens.metrics.space.two)
        .padding(.vertical, tokens.metrics.space.one)
        .accessibilityElement(children: .combine)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: tokens.metrics.space.one) {
            KeyCap(key)
            Text(label).font(.caption).foregroundStyle(tokens.textSecondary)
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let count = results.count
        switch press.key {
        case .downArrow:
            if count > 0 { highlighted = (highlighted + 1) % count }
        case .upArrow:
            if count > 0 { highlighted = (highlighted - 1 + count) % count }
        case .tab:
            let starts = layout.sectionStarts
            if count > 0, starts.count > 1 {
                highlighted = PaletteLayout.jump(from: highlighted, sectionStarts: starts,
                                                 forward: !press.modifiers.contains(.shift))
            }
        case .return:
            let items = results
            if items.indices.contains(highlighted) { run(items[highlighted]) }
        case .escape:
            onDismiss()
        default:
            return .ignored
        }
        return .handled
    }

    private func run(_ command: any PaletteCommand) {
        guard !didRun else { return }
        didRun = true
        recents = PaletteRanker.pushRecent(command.id, into: recents)
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
        onDismiss()
        command.perform()
    }
}
