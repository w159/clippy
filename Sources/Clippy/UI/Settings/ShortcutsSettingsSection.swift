import SwiftUI

// Global shortcuts (one recorder per HotKeyAction) and the menu bar icon click behavior.

struct ShortcutsSettingsSection: View {
    var body: some View {
        Section("Shortcuts") {
            ForEach(HotKeyAction.allCases, id: \.self) { action in
                HotKeyRecorderView(action: action)
            }
            SettingsNote("Click a shortcut, then press the new combination. Escape cancels and Delete clears it. " +
                "Reset restores the default; conflicts and registration failures are shown under the row.")
        }
        .settingsRow("general.hotkey")
        Section("Menu bar icon") {
            StatusItemBehaviorRow()
        }
    }
}

/// Picker for what clicking the menu bar icon does. The preference is a static, so the row keeps its own state.
struct StatusItemBehaviorRow: View {
    @State private var behavior = StatusItemPreferences.clickBehavior

    var body: some View {
        Picker("Icon click", selection: $behavior) {
            ForEach(StatusItemClickBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .settingsRow("general.statusItem")
        .onChange(of: behavior) { _, value in StatusItemPreferences.clickBehavior = value }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let stored = StatusItemPreferences.clickBehavior
            if behavior != stored { behavior = stored }
        }
    }
}
