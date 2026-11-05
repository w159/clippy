import Foundation
import XCTest
@testable import Clippy

// MARK: - AppSettings observation regression tests
//
// Guards the "nothing can be changed" regression: settings that mutate without
// notifying any SwiftUI view. AppSettings is `@Observable`; its plain stored
// properties are tracked by the macro, while every `@AppDefault` /
// `@GatedPublished` property is `@ObservationIgnored` and reports to the
// registrar itself. A property that falls out of either path would mutate
// silently. FixtureSettings (AppDefaultTests) cannot catch that for the real
// class, so these run against AppSettings, which mixes both kinds.
//
// These tests run against the AppSettings.shared singleton (the wrapper is
// hardwired to UserDefaults.standard, matching AppDefaultTests). Original
// values are captured and restored so the suite does not mutate real settings.

@MainActor
final class AppSettingsObservationTests: XCTestCase {
    private var settings: AppSettings!

    // Saved originals (one tracked stored property, one @AppDefault) for restore.
    private var originalPanelOpacity: Double = 0
    private var originalMovePastedItemToTop: Bool = false

    override func setUp() {
        super.setUp()
        settings = AppSettings.shared
        originalPanelOpacity = settings.panelOpacity
        originalMovePastedItemToTop = settings.movePastedItemToTop
    }

    override func tearDown() {
        settings.panelOpacity = originalPanelOpacity
        settings.movePastedItemToTop = originalMovePastedItemToTop
        settings = nil
        super.tearDown()
    }

    // MARK: Tracked stored property path (the regression)

    /// A mutation of a tracked stored property MUST notify observers. A property
    /// that silently fell out of tracking would stay quiet here -- the core of the
    /// "nothing updates" bug.
    func testTrackedPropertyNotifiesObservers() {
        // Mutate to a guaranteed-different value within the clamped range.
        let target = settings.panelOpacity == 0.9 ? 0.8 : 0.9
        let changes = observedChangeCount(
            tracking: { _ = self.settings.panelOpacity },
            during: { self.settings.panelOpacity = target })
        XCTAssertEqual(
            changes, 1,
            "Mutating a tracked AppSettings property must notify observers. " +
            "A property outside observation would break all SwiftUI re-render."
        )
    }

    // MARK: @AppDefault path (must keep working)

    /// The @AppDefault subscript reports the write to the registrar explicitly.
    func testAppDefaultPropertyNotifiesObservers() {
        let changes = observedChangeCount(
            tracking: { _ = self.settings.movePastedItemToTop },
            during: { self.settings.movePastedItemToTop.toggle() })
        XCTAssertEqual(
            changes, 1,
            "Mutating an @AppDefault AppSettings property must notify observers."
        )
    }

    /// A bulk reset rewrites UserDefaults behind the wrappers; readers of any
    /// @AppDefault property must still be told.
    func testStorageReloadNotifiesAppDefaultReaders() {
        let changes = observedChangeCount(
            tracking: { _ = self.settings.movePastedItemToTop },
            during: { self.settings.announceStorageReloaded() })
        XCTAssertEqual(changes, 1)
    }
}
