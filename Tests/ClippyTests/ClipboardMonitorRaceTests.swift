import XCTest

@testable import Clippy

/// Regression cover for the dropped-copy defect: an app that writes several
/// pasteboard flavors bumps changeCount on clearContents() and fills the data
/// in milliseconds to hundreds of milliseconds later. The poll used to retire
/// the changeCount on that first empty look, so the copy was lost for good -
/// no clip, no mascot bounce, no capture sound. Repro measured 5 of 6 copies
/// dropped against a 300ms fill gap.
final class ClipboardMonitorRaceTests: XCTestCase {

    private func makeScratchPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("ClippyTest-\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    /// captureText writes on a background queue; give it a moment to land.
    private func waitForClip(_ db: ClipDatabase, text: String, timeout: TimeInterval = 5) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try db.allClips().contains(where: { $0.contentText == text }) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    func testCopyIsNotDroppedWhenPasteboardFillsInAfterTheFirstPoll() throws {
        let db = try makeTestDatabase(self)
        let pb = makeScratchPasteboard()
        let monitor = ClipboardMonitor(database: db, pasteboard: pb)

        // Retire a first, complete write so the monitor is in steady state.
        pb.clearContents()
        pb.setString("seed clip", forType: .string)
        monitor.tick()
        XCTAssertTrue(try waitForClip(db, text: "seed clip"))

        // The slow write: changeCount has already moved, the data has not landed.
        pb.clearContents()
        monitor.tick()

        // Data lands, and the very next poll must still capture it.
        pb.setString("slow write clip", forType: .string)
        monitor.tick()

        XCTAssertTrue(
            try waitForClip(db, text: "slow write clip"),
            "a copy whose pasteboard filled in after the first poll was dropped"
        )
    }

    /// The retry must not run forever: a flavor Clippy will never capture has to
    /// be retired once the grace period is up, or the poll re-reads it on every
    /// tick until the next copy.
    func testUnsupportedFlavorIsRetiredAfterTheGracePeriod() throws {
        let db = try makeTestDatabase(self)
        let pb = makeScratchPasteboard()
        let monitor = ClipboardMonitor(database: db, pasteboard: pb)

        // setString does not bump changeCount - only clearContents does - so
        // once this change is retired, filling it in later is invisible to the
        // poll. That is the deliberate ceiling: a writer slower than the grace
        // period still loses its copy.
        pb.clearContents()
        monitor.tick()
        Thread.sleep(forTimeInterval: 2.1)
        monitor.tick()  // grace expired: this retires the change

        pb.setString("past the grace period", forType: .string)
        monitor.tick()
        XCTAssertFalse(try waitForClip(db, text: "past the grace period", timeout: 1))

        // A later complete write is still captured, proving the retire did not
        // wedge the monitor.
        pb.clearContents()
        pb.setString("after grace", forType: .string)
        monitor.tick()
        XCTAssertTrue(try waitForClip(db, text: "after grace"))
    }
}
