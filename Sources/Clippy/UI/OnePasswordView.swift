import AppKit
import SwiftUI

/// The main-pane content for the virtual "1Password" category: lists items from
/// the configured vault, expands an item to show all its fields, copies any
/// individual field on demand, and creates a new secret. No values are stored
/// or logged by Clippy.
struct OnePasswordView: View {
    private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Owns the list/detail loads and the state machine (OPW-01, OPW-02).
    @State private var model = OnePasswordViewModel(
        makeService: { OnePasswordService(vault: AppSettings.shared.onePasswordVault) })
    @State private var creating = false
    @State private var newTitle = ""
    @State private var newValue = ""
    @State private var status: String?
    /// A failed "Create secret": persistent, announced, with Try Again (the form keeps its input).
    @State private var createError: String?
    @State private var searchQuery = ""
    @State private var toastMessage: String?
    @State private var isCreating = false
    @State private var toastTask: Task<Void, Never>?
    @State private var statusTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @FocusState private var titleFocused: Bool

    private var service: OnePasswordService { OnePasswordService(vault: settings.onePasswordVault) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { model.reload() }
        .onDisappear {
            toastTask?.cancel()
            statusTask?.cancel()
        }
        .onChange(of: model.state) { _, state in if state == .ready { searchFocused = true } }
        .onChange(of: creating) { _, isOn in if isOn { titleFocused = true } }
        // Switching vaults in Settings must reload the list; onAppear alone left the
        // old vault's items on screen.
        .onChange(of: settings.onePasswordVault) { _, _ in model.reload() }
        .onChange(of: searchQuery) { _, _ in
            if let expandedItemID, !filteredItems.contains(where: { $0.id == expandedItemID }) {
                model.collapse()
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                ClippyToast(toastMessage, severity: .success, dismiss: { self.toastMessage = nil })
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .animation(ClippyMotion.animation(.quick, reduce: reduceMotion), value: toastMessage)
        .clippyDesignSystem()
    }

    /// CLI missing or not signed in: the same states that show the full-pane recovery panel.
    private var cliUnavailable: Bool {
        switch model.state {
        case .notInstalled, .needsSignIn: return true
        default: return false
        }
    }
    private var loading: Bool { model.state == .loading }
    private var expandedItemID: String? { model.expandedItemID }

    private var tokens: ThemeTokens { settings.theme }
    @Environment(\.clippyTokens) private var designTokens
    private var filteredItems: [OPItem] {
        OnePasswordFilter.filter(model.items, query: searchQuery, vault: settings.onePasswordVault)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label {
                Text("1Password · \(settings.onePasswordVault)")
                    .foregroundStyle(tokens.textPrimary)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "key.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(tokens.accent, tokens.textSecondary)
            }
            .font(PanelTypography.body(settings).weight(.semibold))
            TextField("Search items", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search 1Password items by title or vault")
                .focused($searchFocused)
                .disabled(model.state != .ready)
            IconButton("plus", label: "New secret", state: creating ? .selected : .rest) { creating.toggle() }
                .disabled(cliUnavailable)
            IconButton("arrow.clockwise", label: "Refresh", state: loading ? .disabled : .rest) { model.reload() }
                .symbolEffect(.variableColor, isActive: !reduceMotion && loading)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .notInstalled:
            OnePasswordStatePanel(state: .notInstalled, retry: { model.reload() }, signIn: { model.signIn() })
        case .needsSignIn(let detail):
            OnePasswordStatePanel(state: .needsSignIn(detail), signingIn: model.signingIn,
                                  retry: { model.reload() }, signIn: { model.signIn() })
        case .error(let detail):
            OnePasswordStatePanel(state: .error(detail), retry: { model.reload() }, signIn: { model.signIn() })
        case .loading:
            if model.items.isEmpty {
                OnePasswordStatePanel(state: .loading, retry: { model.reload() }, signIn: { model.signIn() })
            } else {
                // Keep the previous list on screen while refreshing so nothing jumps.
                itemList.opacity(0.6).allowsHitTesting(false)
            }
        case .empty:
            OnePasswordStatePanel(state: .empty, retry: { model.reload() }, signIn: { model.signIn() })
        case .ready:
            itemList
        }
    }

    private var itemList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if creating { newSecretForm }
                if let createError {
                    ClippyBanner("Could not create the secret. \(createError)", severity: .danger,
                                 actionTitle: "Try Again", action: create, dismiss: { self.createError = nil })
                }
                if let status { Text(status).font(.caption).foregroundStyle(tokens.textSecondary) }
                if filteredItems.isEmpty {
                    Text(searchQuery.isEmpty ? "No items in this vault." : "No items match this search.")
                        .font(.callout).foregroundStyle(tokens.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                ForEach(filteredItems) { item in
                    OnePasswordItemRow(item: item, isExpanded: expandedItemID == item.id,
                                       toggle: { model.toggleExpand(item) })
                    if expandedItemID == item.id {
                        OnePasswordItemDetailPanel(
                            loading: model.detailLoading, error: model.detailError, detail: model.detail,
                            service: service, onAutoClear: { showAutoClearToast() },
                            onRetry: { model.retryDetail() })
                    }
                }
            }
            .padding(10)
        }
    }

    private var newSecretForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit { create() }
            SecureField("Secret value", text: $newValue)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }
            HStack {
                Spacer()
                Button("Cancel") { creating = false; newTitle = ""; newValue = "" }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button("Create") { create() }
                    .buttonStyle(.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newTitle.isEmpty || newValue.isEmpty || isCreating)
            }
        }
        .disabled(isCreating)
        .padding(8)
        .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: ClippyRadius.inset))
        .overlay(
            RoundedRectangle(cornerRadius: ClippyRadius.inset)
                .strokeBorder(designTokens.stroke, lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func showAutoClearToast() {
        toastMessage = "Clippy cleared the copied secret from the clipboard"
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    /// Shows `message` under the header, then clears it so it never goes stale.
    private func flashStatus(_ message: String) {
        status = message
        statusTask?.cancel()
        statusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            status = nil
        }
    }

    private func create() {
        guard !isCreating, !newTitle.isEmpty, !newValue.isEmpty else { return }
        let title = newTitle, value = newValue
        isCreating = true
        createError = nil
        status = "Creating \(title)\u{2026}"
        Task {
            do {
                try await service.createSecret(title: title, value: value)
                await MainActor.run {
                    isCreating = false
                    creating = false; newTitle = ""; newValue = ""
                    flashStatus("Created \(title).")
                    model.reload()
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    status = nil
                    createError = error.localizedDescription
                    AccessibilityNotification.Announcement("Could not create the secret").post()
                }
            }
        }
    }
}


#Preview("1Password") {
    OnePasswordView()
        .frame(width: 720, height: 520)
}
