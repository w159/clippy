import AppKit

// Curated list of macOS system sounds suitable for a capture confirmation.
// All 14 names below ship with macOS 14+ in /System/Library/Sounds/.
// SoundPlayer.resolve() verifies availability at runtime and falls back to
// nil (silent) if a name is somehow absent, so no hard crash is possible.
enum CaptureSound: String, CaseIterable, Identifiable {
    case tink      = "Tink"
    case pop       = "Pop"
    case glass     = "Glass"
    case morse     = "Morse"
    case purr      = "Purr"
    case submarine = "Submarine"
    case basso     = "Basso"
    case blow      = "Blow"
    case bottle    = "Bottle"
    case frog      = "Frog"
    case funk      = "Funk"
    case hero      = "Hero"
    case ping      = "Ping"
    case sosumi    = "Sosumi"

    var id: String { rawValue }

    /// The display name shown in the picker.
    var label: String { rawValue }
}

// MARK: - SoundPlayer

/// Plays a named macOS system sound at a specified volume.
/// Single responsibility: resolve NSSound, set volume, fire play().
/// NSSound.play() is asynchronous and non-blocking; it returns immediately
/// and the system mixes the audio independently of the caller.
///
/// Main-actor isolated: NSSound is not Sendable and every caller (capture
/// pipeline, Settings pickers) is on the main thread, so the id cache needs no lock.
@MainActor
final class SoundPlayer {

    /// Cache of NSSound instances keyed by catalog id (see SoundCatalog).
    static var idCache: [String: NSSound] = [:]

    /// Resolves the named sound and plays it at the given volume (0.0-1.0).
    /// Returns true when playback was started; false when the sound could not
    /// be resolved (e.g. missing from this OS version).
    @discardableResult
    static func play(_ sound: CaptureSound, volume: Float) -> Bool {
        guard let ns = resolve(sound) else { return false }
        // NSSound.volume is a Float in [0.0, 1.0]; clamp defensively because
        // the settings slider may produce a fractional edge outside that range.
        ns.volume = clampVolume(volume)
        ns.play()
        return true
    }

    /// Resolves the named system sound; nil when the sound is unavailable.
    /// Exposed for unit testing without requiring audio hardware.
    static func resolve(_ sound: CaptureSound) -> NSSound? {
        NSSound(named: sound.rawValue)
    }

    /// Clamps a raw volume value to the valid NSSound range [0.0, 1.0].
    /// Extracted for unit testing without instantiating NSSound.
    nonisolated static func clampVolume(_ raw: Float) -> Float {
        min(1.0, max(0.0, raw))
    }

    /// Converts a 0-100 integer slider value to the 0.0-1.0 Float NSSound expects.
    nonisolated static func sliderToVolume(_ slider: Int) -> Float {
        clampVolume(Float(slider) / 100.0)
    }
}
