import Foundation

/// Resolves how a user script run is confined (SEC-07). The on/off flag lives in
/// `SandboxScriptFlags`; the network sub-flag is stored here under the
/// `scripts.sandboxNetwork.<id>` key because `ScriptSandbox.allowNetwork` has no
/// persisted counterpart in the Security layer.
struct ScriptSandboxPolicy {
    private let defaults: UserDefaults
    private let flags: SandboxScriptFlags

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.flags = SandboxScriptFlags(defaults: defaults)
    }

    private static func networkKey(_ id: UUID) -> String { "scripts.sandboxNetwork.\(id.uuidString)" }

    func isSandboxed(_ id: UUID) -> Bool { flags.isSandboxed(id) }

    func setSandboxed(_ on: Bool, for id: UUID) {
        flags.set(on, for: id)
        if !on { setNetworkAllowed(false, for: id) }
    }

    func isNetworkAllowed(_ id: UUID) -> Bool { defaults.bool(forKey: Self.networkKey(id)) }

    func setNetworkAllowed(_ on: Bool, for id: UUID) {
        if on { defaults.set(true, forKey: Self.networkKey(id)) } else { defaults.removeObject(forKey: Self.networkKey(id)) }
    }

    /// The sandbox to pass to `ScriptRunner.run`: nil when the flag is off. When
    /// the sandbox is unavailable the runner itself refuses the run with
    /// `SandboxRunner.refusalMessage`, since `confirmedUnsandboxedFallback` stays false.
    func sandbox(for id: UUID) -> ScriptSandbox? {
        guard isSandboxed(id) else { return nil }
        return ScriptSandbox(allowNetwork: isNetworkAllowed(id))
    }

    /// One-line status for the editor toggle's caption.
    static func availabilityCaption(_ availability: SandboxAvailability) -> String {
        switch availability {
        case .available: return "Sandbox available: read-only filesystem, network blocked unless allowed below."
        case .unavailable(let reason): return "Sandbox unavailable: \(reason) Sandboxed runs are refused."
        }
    }
}
