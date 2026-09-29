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

    private var results: [any PaletteCommand] { PaletteRanker.rank(commands, query: query, recents: recents) }

    var body: some View {
        ZStack {
            tokens.textPrimary.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            GlassSurface(in: RoundedRectangle(cornerRadius: tokens.metrics.radius.lg, style: .continuous)) {
                VStack(spacing: 0) {
                    searchField
                    Divider().padding(.vertical, tokens.metrics.space.one)
                    resultList
                    Divider().padding(.vertical, tokens.metrics.space.one)
                    hintBar
                }
            }
            .frame(maxWidth: 520, maxHeight: 380)
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
            Image(systemName: "command").foregroundStyle(tokens.textSecondary).accessibilityHidden(true)
            TextField("Type a command", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .accessibilityLabel("Command search")
                .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
            KeyCap("esc")
        }
        .padding(.horizontal, tokens.metrics.space.two)
    }

    private var resultList: some View {
        let items = results
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if items.isEmpty {
                        Text("No matching commands. Clear the search to see all.")
                            .foregroundStyle(tokens.textSecondary)
                            .padding(tokens.metrics.space.three)
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { index, command in
                        row(command, selected: index == highlighted, hovered: index == hovered)
                            .id(index)
                            .onTapGesture { run(command) }
                            .onHover { inside in
                                if inside { hovered = index } else if hovered == index { hovered = nil }
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

    private func row(_ command: any PaletteCommand, selected: Bool, hovered: Bool) -> some View {
        HStack(spacing: tokens.metrics.space.two) {
            Image(systemName: command.symbol).frame(width: 20).foregroundStyle(tokens.accentText)
            VStack(alignment: .leading, spacing: 0) {
                Text(command.title).foregroundStyle(tokens.textPrimary)
                if let subtitle = command.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(tokens.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: tokens.metrics.space.two)
            if let shortcut = command.shortcut { KeyCap(shortcut) }
        }
        .padding(.horizontal, tokens.metrics.space.two)
        .padding(.vertical, tokens.metrics.space.one + 2)
        .background(selected ? tokens.selection : (hovered ? tokens.selection.opacity(0.5) : .clear), in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(command.title)
        .accessibilityValue(command.shortcut ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { run(command) }
    }

    private var hintBar: some View {
        HStack(spacing: tokens.metrics.space.three) {
            Text("Up/Down move").font(.caption).foregroundStyle(tokens.textSecondary)
            Text("Return run").font(.caption).foregroundStyle(tokens.textSecondary)
            Text("Esc close").font(.caption).foregroundStyle(tokens.textSecondary)
            Spacer()
        }
        .padding(.horizontal, tokens.metrics.space.two)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let count = results.count
        switch press.key {
        case .downArrow:
            if count > 0 { highlighted = (highlighted + 1) % count }
        case .upArrow:
            if count > 0 { highlighted = (highlighted - 1 + count) % count }
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
