import SwiftUI

/// The configured provider instances: active radio, status dot, duplicate and remove,
/// plus the "+ Add provider" menu.
struct AIProviderListSection: View {
    @ObservedObject var model: AIProviderManagerModel
    @ObservedObject var store: AIProviderStore
    @Environment(\.clippyTokens) private var tokens
    @State private var pendingRemoval: ProviderInstance?
    private let gate = AIProviderSettingsLogic.ForcedGate()

    var body: some View {
        PaneSection("Providers", footer: footnote) {
            if store.instances.isEmpty {
                SettingsNote("No providers yet. Add one to use AI features.")
            }
            ForEach(store.instances) { instance in
                row(instance)
            }
            addMenu
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "provider")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { instance in
            Button("Remove", role: .destructive) { model.remove(instance.id) }
        } message: { _ in
            Text("Its API key and secret headers are deleted from the Keychain.")
        }
    }

    private var footnote: String? {
        let retired = AIProviderSettingsLogic.retiredProviderNames
        guard !retired.isEmpty else { return nil }
        return "\(retired.joined(separator: ", ")) \(retired.count == 1 ? "is" : "are") retired and cannot be added. "
            + "Existing instances remain visible so you can move their settings to another provider."
    }

    private func row(_ instance: ProviderInstance) -> some View {
        let descriptor = ProviderCatalog.descriptor(id: instance.descriptorID)
        let isActive = store.presentationInstance()?.id == instance.id
        let isSelected = model.selectedID == instance.id
        return HStack(spacing: tokens.metrics.space.two) {
            Button { model.setActive(instance.id) } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.plain)
            .disabled(gate.providerLocked)
            .help(isActive ? "Active provider" : "Make active")
            .accessibilityLabel(isActive ? "Active provider" : "Make \(instance.name) active")
            statusDot(model.status(for: instance.id))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(instance.name).fontWeight(isSelected ? .semibold : .regular)
                    if let descriptor { badge(descriptor.family.displayLabel) }
                }
                Text(hostText(instance, descriptor))
                    .font(.caption).foregroundStyle(tokens.textSecondary).lineLimit(1)
            }
            Spacer()
            Button { _ = model.duplicate(instance.id) } label: { Image(systemName: "plus.square.on.square") }
                .buttonStyle(.plain).help("Duplicate \(instance.name)").accessibilityLabel("Duplicate \(instance.name)")
            Button { pendingRemoval = instance } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).help("Remove \(instance.name)").accessibilityLabel("Remove \(instance.name)")
                .disabled(gate.providerLocked && isActive)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = instance.id }
        .padding(.vertical, 8)
    }

    private func hostText(_ instance: ProviderInstance, _ descriptor: ProviderDescriptor?) -> String {
        guard let descriptor else { return "Unknown provider" }
        if descriptor.family == .appleFoundation { return "On this Mac" }
        let resolved = ResolvedProvider(descriptor: descriptor, instance: instance, apiKey: "", secretHeaders: [:])
        return resolved.effectiveBaseURL?.host ?? "Endpoint not set"
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(tokens.selection))
            .foregroundStyle(tokens.textSecondary)
    }

    private func statusDot(_ status: AIProviderManagerModel.Status) -> some View {
        let (color, label): (Color, String) = switch status {
        case .untested: (tokens.textSecondary.opacity(0.4), "Not tested")
        case .testing: (tokens.warning, "Testing")
        case .ok: (tokens.success, "Last test passed")
        case .failed: (tokens.danger, "Last test failed")
        }
        return Circle().fill(color).frame(width: 8, height: 8).help(label).accessibilityLabel(label)
    }

    private var addMenu: some View {
        Menu {
            ForEach(AIProviderSettingsLogic.addGroups(), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.descriptors) { descriptor in
                        Button(descriptor.displayName) { model.add(descriptorID: descriptor.id) }
                    }
                }
            }
        } label: {
            Label("Add provider", systemImage: "plus")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .settingsRow("ai.provider")
        .padding(.vertical, 10)
    }
}
