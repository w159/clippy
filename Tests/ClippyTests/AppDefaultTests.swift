import Foundation
import Observation
import XCTest
@testable import Clippy

// MARK: - AppDefault property wrapper tests
//
// These tests use throwaway UserDefaults keys (unique per test) cleaned up
// in tearDown. All tests run against UserDefaults.standard because
// @AppDefault is hardwired to .standard (no injection point by design).

// MARK: - Test fixture types

private enum FixtureColor: String, Equatable {
    case red
    case green
    case blue
}

@MainActor
@Observable
private final class FixtureSettings: ObservationNotifying {
    init() {}
    private(set) var storageRevision = 0

    // Unique key prefixes chosen to avoid colliding with live app keys.
    @ObservationIgnored @AppDefault("_test.appdefault.label", default: "hello")
    var label: String

    @ObservationIgnored @AppDefault("_test.appdefault.enabled", default: false)
    var enabled: Bool

    @ObservationIgnored @AppDefault("_test.appdefault.color", default: FixtureColor.red)
    var color: FixtureColor

    func announceStorageReloaded() { storageRevision &+= 1 }
}

// MARK: - Tests

@MainActor
final class AppDefaultTests: XCTestCase {
    private var fixture: FixtureSettings!

    private let labelKey   = "_test.appdefault.label"
    private let enabledKey = "_test.appdefault.enabled"
    private let colorKey   = "_test.appdefault.color"

    override func setUp() {
        super.setUp()
        // Clean slate before each test.
        UserDefaults.standard.removeObject(forKey: labelKey)
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: colorKey)
        fixture = FixtureSettings()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: labelKey)
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: colorKey)
        fixture = nil
        super.tearDown()
    }

    // MARK: String (plist)

    func testStringDefaultReturnedWhenKeyAbsent() {
        XCTAssertEqual(fixture.label, "hello")
    }

    func testStringSetsValueInUserDefaults() {
        fixture.label = "world"
        XCTAssertEqual(UserDefaults.standard.string(forKey: labelKey), "world")
    }

    func testStringReflectsExternallyStoredValue() {
        UserDefaults.standard.set("external", forKey: labelKey)
        // Re-create fixture so it reads fresh (wrapper reads on each access).
        let fresh = FixtureSettings()
        XCTAssertEqual(fresh.label, "external")
    }

    // MARK: Bool (plist)

    func testBoolDefaultReturnedWhenKeyAbsent() {
        XCTAssertFalse(fixture.enabled)
    }

    func testBoolSetsValueInUserDefaults() {
        fixture.enabled = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: enabledKey))
    }

    func testBoolReflectsExternallyStoredValue() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        let fresh = FixtureSettings()
        XCTAssertTrue(fresh.enabled)
    }

    // MARK: RawRepresentable enum

    func testEnumDefaultReturnedWhenKeyAbsent() {
        XCTAssertEqual(fixture.color, .red)
    }

    func testEnumSetsRawValueInUserDefaults() {
        fixture.color = .green
        XCTAssertEqual(UserDefaults.standard.string(forKey: colorKey), "green")
    }

    func testEnumReadsRawValueFromUserDefaults() {
        UserDefaults.standard.set("blue", forKey: colorKey)
        let fresh = FixtureSettings()
        XCTAssertEqual(fresh.color, .blue)
    }

    func testEnumFallsBackToDefaultOnBogusStoredValue() {
        // Store a string that has no matching case.
        UserDefaults.standard.set("ultraviolet", forKey: colorKey)
        let fresh = FixtureSettings()
        // Should fall back to the declared default (.red), not crash.
        XCTAssertEqual(fresh.color, .red)
    }

    // MARK: observers are notified on set

    func testObserversNotifiedOnStringSet() {
        let changes = observedChangeCount(tracking: { _ = self.fixture.label }, during: { self.fixture.label = "trigger" })
        // Observers are told synchronously, before the value is written.
        XCTAssertEqual(changes, 1)
    }

    func testObserversNotifiedOnBoolSet() {
        let changes = observedChangeCount(tracking: { _ = self.fixture.enabled }, during: { self.fixture.enabled = true })
        XCTAssertEqual(changes, 1)
    }

    func testObserversNotifiedOnEnumSet() {
        let changes = observedChangeCount(tracking: { _ = self.fixture.color }, during: { self.fixture.color = .blue })
        XCTAssertEqual(changes, 1)
    }

    func testObserversNotNotifiedWithoutSet() {
        let changes = observedChangeCount(
            tracking: { _ = self.fixture.label },
            during: {
                // Read-only access must not notify.
                _ = self.fixture.label
                _ = self.fixture.enabled
                _ = self.fixture.color
            })
        XCTAssertEqual(changes, 0)
    }

    // MARK: Notification-mechanism safeguard

    // The wrapper reports reads and writes to the owning class's registrar
    // through ObservationNotifying. The tests below pin the two behaviors a
    // silent regression would break: a write must notify observers of that
    // property, and must not notify observers of a different property.

    func testWriteDoesNotNotifyObserversOfOtherProperties() {
        let changes = observedChangeCount(tracking: { _ = self.fixture.enabled }, during: { self.fixture.label = "other" })
        XCTAssertEqual(changes, 0, "a write must only notify observers of the property it changed")
    }

    func testStorageReloadNotifiesObserversOfEveryWrappedProperty() {
        let changes = observedChangeCount(tracking: { _ = self.fixture.color }, during: { self.fixture.announceStorageReloaded() })
        XCTAssertEqual(changes, 1, "a bulk reset must re-render readers of wrapped settings")
    }

    func testSetNotifiesOnceAndGetNever() {
        let changes = observedChangeCount(
            tracking: { _ = self.fixture.label },
            during: {
                _ = self.fixture.label    // get -- must not notify
                self.fixture.label = "a"  // set -- notifies once
                _ = self.fixture.label    // get -- must not notify again
            })
        XCTAssertEqual(changes, 1)
    }
}
