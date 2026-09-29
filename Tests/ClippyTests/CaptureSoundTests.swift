import XCTest
@testable import Clippy

@MainActor
final class CaptureSoundTests: XCTestCase {

    // MARK: - Volume clamping

    func testClampVolumeZero() {
        XCTAssertEqual(SoundPlayer.clampVolume(0.0), 0.0)
    }

    func testClampVolumeOne() {
        XCTAssertEqual(SoundPlayer.clampVolume(1.0), 1.0)
    }

    func testClampVolumeAboveOneIsClampedToOne() {
        XCTAssertEqual(SoundPlayer.clampVolume(1.5), 1.0)
    }

    func testClampVolumeNegativeIsClampedToZero() {
        XCTAssertEqual(SoundPlayer.clampVolume(-0.1), 0.0)
    }

    func testClampVolumeMidRange() {
        XCTAssertEqual(SoundPlayer.clampVolume(0.5), 0.5, accuracy: 0.0001)
    }

    // MARK: - Slider to volume conversion

    func testSliderZeroProducesZeroVolume() {
        XCTAssertEqual(SoundPlayer.sliderToVolume(0), 0.0)
    }

    func testSliderHundredProducesFullVolume() {
        XCTAssertEqual(SoundPlayer.sliderToVolume(100), 1.0, accuracy: 0.0001)
    }

    func testSliderFiftyProducesHalfVolume() {
        XCTAssertEqual(SoundPlayer.sliderToVolume(50), 0.5, accuracy: 0.0001)
    }

    func testSliderAboveHundredIsClamped() {
        // Defensive: a slider set beyond its declared range should not
        // produce a volume above 1.0.
        XCTAssertEqual(SoundPlayer.sliderToVolume(200), 1.0, accuracy: 0.0001)
    }

    // MARK: - Sound name round-trip

    func testAllSoundCasesHaveNonEmptyRawValue() {
        for sound in CaptureSound.allCases {
            XCTAssertFalse(sound.rawValue.isEmpty, "\(sound) rawValue must not be empty")
        }
    }

    func testCaptureSoundRawValueRoundTrips() {
        for sound in CaptureSound.allCases {
            let recovered = CaptureSound(rawValue: sound.rawValue)
            XCTAssertEqual(recovered, sound, "round-trip failed for \(sound.rawValue)")
        }
    }

    func testCaptureSoundLabelMatchesRawValue() {
        // Label is the display name; for system sounds the raw value IS the
        // human-readable name (Tink, Pop, etc.), so label == rawValue.
        for sound in CaptureSound.allCases {
            XCTAssertEqual(sound.label, sound.rawValue)
        }
    }

    func testUnknownRawValueFallsBackToNil() {
        XCTAssertNil(CaptureSound(rawValue: "NonexistentSound"))
    }

    // MARK: - Runtime sound availability

    func testResolveTinkReturnsNonNilOnThisMachine() {
        // Tink ships with macOS 14+; if this ever returns nil the system is
        // missing standard sounds and the test documents the contract failure.
        XCTAssertNotNil(SoundPlayer.resolve(.tink), "NSSound(named: \"Tink\") must resolve on macOS 14+")
    }
}
