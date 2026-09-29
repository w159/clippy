import Combine
import Foundation
import XCTest
@testable import Clippy

// MARK: - AppSettings observation regression tests
//
// Guards the "nothing can be changed" regression: AppSettings once declared
// its own `let objectWillChange = ObservableObjectPublisher()`. That hand-rolled
// publisher suppressed the compiler's auto-wiring of every @Published property's
// willSet to objectWillChange, so @Published settings mutated without notifying
// any SwiftUI view. FixtureSettings (AppDefaultTests) could not catch this
// because it has no @Published properties -- only the real AppSettings, which
// mixes @AppDefault and @Published, exercises the failing interaction.
//
// These tests run against the AppSettings.shared singleton (the wrapper is
// hardwired to UserDefaults.standard, matching AppDefaultTests). Original
// values are captured and restored so the suite does not mutate real settings.

@MainActor
final class AppSettingsObservationTests: XCTestCase {
    private var settings: AppSettings!
    private var cancellables: Set<AnyCancellable> = []

    // Saved originals (one @Published, one @AppDefault) for restore.
    private var originalPanelOpacity: Double = 0
    private var originalMovePastedItemToTop: Bool = false

    override func setUp() {
        super.setUp()
        settings = AppSettings.shared
        originalPanelOpacity = settings.panelOpacity
        originalMovePastedItemToTop = settings.movePastedItemToTop
        cancellables = []
    }

    override func tearDown() {
        settings.panelOpacity = originalPanelOpacity
        settings.movePastedItemToTop = originalMovePastedItemToTop
        cancellables = []
        settings = nil
        super.tearDown()
    }

    // MARK: @Published path (the regression)

    /// A @Published mutation MUST fire objectWillChange. With the hand-rolled
    /// publisher this stayed silent -- the core of the "nothing updates" bug.
    func testPublishedPropertyFiresObjectWillChange() {
        var callCount = 0
        settings.objectWillChange
            .sink { callCount += 1 }
            .store(in: &cancellables)

        // Mutate to a guaranteed-different value within the clamped range.
        settings.panelOpacity = settings.panelOpacity == 0.9 ? 0.8 : 0.9
        XCTAssertEqual(
            callCount, 1,
            "Mutating a @Published AppSettings property must fire objectWillChange. " +
            "A hand-rolled objectWillChange would suppress this and break all SwiftUI re-render."
        )
    }

    // MARK: @AppDefault path (must keep working)

    /// The @AppDefault subscript fires objectWillChange explicitly. Removing the
    /// hand-rolled publisher must not regress this path.
    func testAppDefaultPropertyFiresObjectWillChange() {
        var callCount = 0
        settings.objectWillChange
            .sink { callCount += 1 }
            .store(in: &cancellables)

        settings.movePastedItemToTop.toggle()
        XCTAssertEqual(
            callCount, 1,
            "Mutating an @AppDefault AppSettings property must fire objectWillChange."
        )
    }

    // MARK: Publisher identity

    /// The synthesized publisher must be the concrete ObservableObjectPublisher
    /// the @AppDefault where-clause depends on.
    func testSharedPublisherIsObservableObjectPublisher() {
        XCTAssertTrue(
            type(of: settings.objectWillChange) == ObservableObjectPublisher.self,
            "AppSettings.objectWillChange must be the synthesized ObservableObjectPublisher."
        )
    }
}
