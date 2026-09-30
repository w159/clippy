import Foundation

// AI-derived computed properties of AppSettings (stored AI settings stay in AppSettings.swift).

extension AppSettings {
    /// Whether auto-titling may actually run right now.
    ///
    /// Auto-titling is the one feature that sends content the user never chose to
    /// send: it fires on *every* copy. With a hosted provider selected that means
    /// every password, account number, and client record that passes through the
    /// clipboard is posted to a third party. So the feature is gated on a provider
    /// that keeps the text on this Mac - Apple Intelligence or a verified loopback server -
    /// regardless of how the toggle is set. Settings explains the gate rather than
    /// silently doing nothing.
    var canAutoSuggestTitles: Bool {
        guard aiEnabled && aiAutoSuggestTitles else { return false }
        guard case .success(let resolved) = AIProviderStore.shared.resolve() else { return false }
        return resolved.keepsDataOnMac
    }
}
