import AppKit
import SwiftUI

/// The main-pane content for the virtual "1Password" category: lists items from
/// the configured vault, expands an item to show all its fields, copies any
/// individual field on demand, and creates a new secret. No values are stored
/// or logged by Clippy.
struct OnePasswordView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var items: [OPItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var creating = false
    @State private var newTitle = ""
    @State private var newValue = ""
    @State private var status: String?
    @State private var expandedItemID: String?
    @State private var detail: OPItemDetail?
    @State private var detailLoading = false
    @State private var detailError: String?

    private var service: OnePasswordService { OnePasswordService(vault: settings.onePasswordVault) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { reload() }
    }

    private var tokens: ThemeTokens { settings.theme }

    private var header: some View {
        HStack {
            Label {
                Text("1Password \u{00B7} \(settings.onePasswordVault)")
                    .foregroundStyle(tokens.textPrimary)
            } icon: {
                Image(systemName: "key.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(tokens.accent, tokens.textSecondary)
            }
                .font(PanelTypography.body(settings).weight(.semibold))
            Spacer()
            Button { creating.toggle() } label: {
                Image(systemName: "plus").symbolRenderingMode(.hierarchical)
            }
                .help("New secret")
                .accessibilityLabel("New secret")
            Button { reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolRenderingMode(.hierarchical)
                    // Spin the refresh glyph while a reload is in flight; the
                    // variableColor cycle reads as "working" and stops on load.
                    .symbolEffect(.variableColor, isActive: !reduceMotion && loading)
            }
                .help("Refresh")
                .accessibilityLabel("Refresh")
                .disabled(loading)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if !OnePasswordService.isInstalled {
            message("The 1Password CLI (op) was not found.",
                    detail: "Install 1Password 8 and turn on the command-line tool in its Developer settings.")
        } else if let error {
            message("Could not reach 1Password", detail: error)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if creating { newSecretForm }
                    if let status {
                        Text(status).font(.caption).foregroundStyle(tokens.textSecondary)
                    }
                    if loading {
                        ProgressView().controlSize(.small)
                    } else if items.isEmpty {
                        Text("No secrets in this vault yet. Use + to add one.")
                            .font(.callout).foregroundStyle(tokens.textSecondary)
                    } else {
                        ForEach(items) { item in
                            itemRow(item)
                            if expandedItemID == item.id {
                                itemDetailPanel(item)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private var newSecretForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $newTitle).textFieldStyle(.roundedBorder)
            SecureField("Secret value", text: $newValue).textFieldStyle(.roundedBorder)
            HStack {
                Button("Create") { create() }
                    .disabled(newTitle.isEmpty || newValue.isEmpty)
                Button("Cancel") { creating = false; newTitle = ""; newValue = "" }
            }
        }
        .padding(8)
        .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(tokens.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Item row (collapsed)

    private func itemRow(_ item: OPItem) -> some View {
        let isExpanded = expandedItemID == item.id
        return Button {
            toggleExpand(item)
        } label: {
            HStack {
                Image(systemName: "lock.doc")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                    Text(item.category.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption2).foregroundStyle(tokens.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.textSecondary)
                    // One fixed chevron rotated, not two swapped glyphs, so the
                    // expand/collapse change animates smoothly instead of popping.
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                isExpanded
                    ? tokens.accent.opacity(0.10)
                    : tokens.cardBorder.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Shows or hides the fields for this item.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Item detail panel (expanded)

    @ViewBuilder
    private func itemDetailPanel(_ item: OPItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if detailLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading fields...").font(.caption).foregroundStyle(tokens.textSecondary)
                }
                .padding(.horizontal, 8)
            } else if let detailError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tokens.danger)
                        // Bounce once when an error surfaces so it draws the eye.
                        // Keyed on the message so a new error re-triggers the bounce.
                        .symbolEffect(.bounce, value: reduceMotion ? "" : detailError)
                    Text(detailError).font(.caption).foregroundStyle(tokens.textSecondary)
                }
                .padding(.horizontal, 8)
            } else if let detail {
                itemDetailFields(detail)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func itemDetailFields(_ detail: OPItemDetail) -> some View {
        ForEach(Array(detail.sectionedFields.enumerated()), id: \.offset) { _, bucket in
            let (section, fields) = bucket
            if let section {
                Text(section.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tokens.textSecondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
            ForEach(fields) { field in
                FieldRow(field: field, itemID: detail.id, service: service,
                         autoClear: settings.onePasswordAutoClearClipboard,
                         autoClearSecs: settings.onePasswordAutoClearDelaySecs)
            }
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "key.slash")
                .font(.system(size: 28, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.textSecondary)
            Text(title).font(PanelTypography.body(settings).weight(.semibold))
            Text(detail).font(PanelTypography.metadata(settings)).foregroundStyle(tokens.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Actions

    private func toggleExpand(_ item: OPItem) {
        if expandedItemID == item.id {
            // Collapse: clear reveal state by discarding detail entirely.
            expandedItemID = nil
            detail = nil
            detailError = nil
        } else {
            expandedItemID = item.id
            detail = nil
            detailError = nil
            loadDetail(item)
        }
    }

    private func loadDetail(_ item: OPItem) {
        detailLoading = true
        Task {
            do {
                let d = try await service.fetchItemDetail(itemID: item.id)
                await MainActor.run {
                    // Only apply if the user hasn't switched to a different item.
                    if expandedItemID == item.id {
                        detail = d
                    }
                    detailLoading = false
                }
            } catch {
                await MainActor.run {
                    if expandedItemID == item.id {
                        detailError = error.localizedDescription
                    }
                    detailLoading = false
                }
            }
        }
    }

    private func reload() {
        guard OnePasswordService.isInstalled else { return }
        loading = true
        error = nil
        expandedItemID = nil
        detail = nil
        Task {
            do {
                let fetched = try await service.listItems()
                await MainActor.run { items = fetched; loading = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; loading = false }
            }
        }
    }

    private func create() {
        let title = newTitle, value = newValue
        status = "Creating \(title)..."
        Task {
            do {
                try await service.createSecret(title: title, value: value)
                await MainActor.run {
                    creating = false; newTitle = ""; newValue = ""
                    status = "Created \(title)."
                    reload()
                }
            } catch {
                await MainActor.run { status = error.localizedDescription }
            }
        }
    }
}

// MARK: - FieldRow

/// One field in the expanded item detail. Handles concealed reveal toggle,
/// TOTP fetch-on-demand, copy-with-concealed-marker, and auto-clear scheduling.
private struct FieldRow: View {
    let field: OPField
    let itemID: String
    let service: OnePasswordService
    let autoClear: Bool
    let autoClearSecs: Int

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tokens: ThemeTokens { settings.theme }

    @State private var revealed = false
    @State private var copying = false
    @State private var copyError: String?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tokens.textSecondary)
                fieldValueView
            }
            Spacer(minLength: 8)
            copyButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 5))
        .onDisappear {
            // Reset reveal state when the row leaves the view hierarchy
            // (item collapsed or view dismissed).
            revealed = false
        }
    }

    @ViewBuilder
    private var fieldValueView: some View {
        if field.type.isOTP {
            Text("TOTP - fetched on copy")
                .font(.caption)
                .foregroundStyle(tokens.textSecondary)
                .italic()
        } else if field.type.isConcealed {
            if revealed, let v = field.value {
                Text(v)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                HStack(spacing: 4) {
                    Text(String(repeating: "\u{2022}", count: 8))
                        .font(.caption)
                        .foregroundStyle(tokens.textSecondary)
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.caption2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(tokens.accent)
                            // Cross-fade eye <-> eye.slash on the reveal toggle.
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .help(revealed ? "Hide" : "Reveal")
                    // Expose reveal state to VoiceOver so the button's purpose
                    // is clear without seeing the eye/eye.slash glyph swap.
                    .accessibilityLabel(revealed ? "Hide" : "Reveal")
                    .accessibilityValue(revealed ? "shown" : "hidden")
                }
            }
        } else if let v = field.value {
            Text(v)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(3)
        } else {
            Text("(empty)")
                .font(.caption)
                .foregroundStyle(tokens.textSecondary)
                .italic()
        }

        if let err = copyError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private var copyButton: some View {
        Button {
            performCopy()
        } label: {
            if copying {
                ProgressView().controlSize(.mini)
            } else {
                Text("Copy")
            }
        }
        .controlSize(.small)
        .disabled(copying || (field.value == nil && !field.type.isOTP))
        .help(field.value == nil && field.type.isConcealed ? "This field has no value stored in 1Password." : "")
    }

    private func performCopy() {
        copying = true
        copyError = nil

        if field.type.isOTP {
            // TOTP: fetch on demand, never cache.
            Task {
                do {
                    let code = try await service.fetchTOTP(itemID: itemID)
                    await MainActor.run {
                        writeToPasteboard(code, concealed: true)
                        copying = false
                    }
                } catch {
                    await MainActor.run {
                        copyError = error.localizedDescription
                        copying = false
                    }
                }
            }
        } else if field.type.isConcealed {
            // For concealed fields the value was fetched with the item detail
            // (op already prompted for auth). Copy directly.
            guard let v = field.value else { copying = false; return }
            writeToPasteboard(v, concealed: true)
            copying = false
        } else {
            guard let v = field.value else { copying = false; return }
            writeToPasteboard(v, concealed: false)
            copying = false
        }
    }

    /// Write to the pasteboard. Concealed writes include the ConcealedType
    /// marker so the clipboard monitor never records the value in history.
    /// If auto-clear is enabled, a task checks the changeCount after the delay
    /// and clears the pasteboard only if it still holds this exact write.
    private func writeToPasteboard(_ value: String, concealed: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        if concealed {
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }

        if concealed && autoClear {
            let changeCount = pb.changeCount
            let delay = autoClearSecs
            Task {
                try? await Task.sleep(for: .seconds(UInt64(delay)))
                await MainActor.run {
                    // Only clear if the pasteboard hasn't been written to since.
                    if NSPasteboard.general.changeCount == changeCount {
                        NSPasteboard.general.clearContents()
                    }
                }
            }
        }
    }
}
