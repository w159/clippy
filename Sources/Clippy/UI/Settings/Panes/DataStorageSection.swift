import SwiftUI

/// Storage ceiling with current usage, plus a read-only iCloud sync summary.
struct DataStorageSection: View {
    @Environment(\.clippyTokens) private var tokens
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var cloud = ICloudSyncService.shared
    @State private var ceiling = StorageCeiling.current
    @State private var usage: StorageUsage?

    /// Creates the section.
    init() {}

    var body: some View {
        Group {
            PaneSection("Storage", footer: Self.ceilingNote) {
                SettingsRow(title: "Clip limit", detail: Text("\(ceiling.formatted()) clips")) {
                    Stepper("Clip limit", value: $ceiling, in: StorageCeiling.minimum...1_000_000, step: 500).labelsHidden()
                        .onChange(of: ceiling) { _, value in StorageCeiling.current = value; reloadUsage() }
                }
                Divider()
                SettingsRow(title: "Current usage", detail: Text(usageDetail)) {
                    if usage?.isNearCeiling == true {
                        Label("Near limit", systemImage: "exclamationmark.triangle.fill").foregroundStyle(tokens.warning)
                    }
                }
            }
            PaneSection("iCloud sync", footer: "Turn sync on or off in Integrations. This is a read-only summary.") {
                SettingsRow(title: "Status", detail: Text(cloudDetail)) {
                    Image(systemName: cloudOK ? "checkmark.icloud.fill" : "icloud.slash").foregroundStyle(cloudOK ? tokens.success : tokens.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .onAppear(perform: reloadUsage)
    }

    private static let ceilingNote = "When history reaches the limit, the oldest uncategorized clips are removed. "
        + "Clippy warns at \(Int(StorageCeiling.warningFraction * 100))% so you can raise the limit or clean up first."

    private var cloudOK: Bool { settings.iCloudSyncEnabled && cloud.isAvailable }

    private var cloudDetail: String {
        if !cloud.isAvailable { return "iCloud Drive is not available on this Mac." }
        return settings.iCloudSyncEnabled ? "On. Syncing through iCloud Drive." : "Off."
    }

    private var usageDetail: String {
        guard let usage else { return "Counting\u{2026}" }
        return "\(usage.count.formatted()) of \(usage.ceiling.formatted())"
    }

    private func reloadUsage() { usage = try? ClipDatabase.shared.storageUsage() }
}
