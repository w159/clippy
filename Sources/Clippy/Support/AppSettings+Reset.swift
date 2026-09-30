import Foundation

// Bulk reset operations for AppSettings.

extension AppSettings {
    /// Clear every per-token override so the app falls back to the selected
    /// preset's base colors. Used by the "Reset all" affordance.
    func clearColorOverrides() {
        customPanelHex = ""
        customScrollBgHex = ""
        customCardSurfaceHex = ""
        customCardBorderHex = ""
        customHeaderHex = ""
        customFooterHex = ""
        customSidebarHex = ""
        customScrollbarHex = ""
        customTextPrimaryHex = ""
        customTextSecondaryHex = ""
        customAccentHex = ""
        customSuccessHex = ""
        customDangerHex = ""
    }

    /// Reset every setting to its registered default. Audit finding: the only
    /// global reset was clearColorOverrides. This wipes all stored keys so the
    /// @AppDefault wrappers fall back to their declared defaults, then re-applies
    /// the same clamping/migration the init does for the @Published properties.
    /// The theme's base colors, AI config, capture knobs, hotkeys, and behavior
    /// toggles all return to their out-of-box values. Does not touch the
    /// keychain (API keys) or the clip database.
    func resetAllToDefaults() {
        // Wipe every persisted settings key. @AppDefault reads live from
        // UserDefaults, so removing a key makes its wrapper return the declared
        // default on the next access without needing an explicit assignment.
        for key in Keys.allPersisted where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }

        // @Published properties live in instance memory, not UserDefaults, so
        // removing keys is not enough: reset them to their defaults explicitly.
        // Each assignment fires objectWillChange so bound views re-render.
        pollingIntervalMs = 200.0
        mcpEnabled = false
        fontSizeBase = 13
        panelOpacity = 1.0
        captureSoundID = SoundCatalog.defaultID
        keystrokeWarnThreshold = 2000
        onePasswordAutoClearDelaySecs = 90
        mcpPort = 51764
        suggestionsLimit = 8
        resetExternalSettings(Keys.allPersisted)
        AIProviderStore.shared.reloadFromDefaults()

        // Re-seed the logger threshold from the reset value.
        ClippyLog.threshold = logLevel

        // Fire one consolidated change so views bound to @AppDefault properties
        // (which did not go through their wrapper setter) re-read UserDefaults.
        // @AppDefault reads live from UserDefaults, so after the key removals
        // above they will return their declared defaultValue on the next access.
        objectWillChange.send()
    }

    // MARK: - Per-pane reset and import reload (SET-09)

    /// Remove `keys` from UserDefaults so their wrappers fall back to declared
    /// defaults, then refresh the in-memory @Published mirrors. Managed (forced)
    /// keys are skipped so a pane reset never fights policy.
    func resetKeys(_ keys: [String]) {
        for key in keys where !Self.isForced(key) && defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
        resetExternalSettings(keys)
        reloadFromDefaults()
        if keys.contains(AIProviderStore.Keys.instances) || keys.contains(AIProviderStore.Keys.activeID) {
            AIProviderStore.shared.reloadFromDefaults()
        }
    }

    /// Refreshes preferences owned by other observable subsystems after their keys are cleared.
    private func resetExternalSettings(_ keys: [String]) {
        let keySet = Set(keys)
        if keySet.contains(GridPreferences.columnModeKey) { GridPreferences.shared.columnMode = .auto }
        if keySet.contains(GridPreferences.densityKey) { GridPreferences.shared.density = .compact }
        if keySet.contains(StatusItemPreferences.clickBehaviorKey) {
            StatusItemPreferences.clickBehavior = .panelOnLeftClick
        }
        for action in HotKeyAction.allCases where keySet.contains(action.defaultsKey) || keySet.contains(action.disabledKey) {
            HotKeyCenter.shared.resetChord(for: action)
        }
    }

    /// Re-read the @Published mirrors (which do not read UserDefaults live) after
    /// keys were removed or bulk-imported, applying the same clamping as init.
    func reloadFromDefaults() {
        pollingIntervalMs = defaults.object(forKey: Keys.pollingIntervalMs) as? Double ?? 200.0
        let font = defaults.integer(forKey: Keys.fontSizeBase)
        fontSizeBase = (11...16).contains(font) ? font : 13
        let opacity = defaults.double(forKey: Keys.panelOpacity)
        panelOpacity = (0.3...1.0).contains(opacity) ? opacity : 1.0
        captureSoundID = Self.resolveSoundID(defaults)
        let warn = defaults.integer(forKey: Keys.keystrokeWarnThreshold)
        keystrokeWarnThreshold = warn > 0 ? warn : 2000
        let port = defaults.integer(forKey: Keys.mcpPort)
        mcpPort = (1024...65535).contains(port) ? port : 51764
        let limit = defaults.integer(forKey: Keys.suggestionsLimit)
        suggestionsLimit = (3...20).contains(limit) ? limit : 8
        if !Self.isForced(Keys.mcpEnabled) { mcpEnabled = defaults.bool(forKey: Keys.mcpEnabled) }
        ClippyLog.threshold = logLevel
        objectWillChange.send()
    }
}
