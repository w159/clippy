import PDFKit
import XCTest

@testable import Clippy

/// CAP-01/06 and PLT-09: paste outcomes, activation, Finder move.
final class PasteServiceTests: CaptureTestCase {

    // MARK: CAP-01: paste failures

    func testMissingImageBytesFailWithoutKeystrokeOrClobberingTheClipboard() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        write(pb, "what the user had copied")
        var keystrokes = 0
        let service = PasteService(monitor: monitor, sendKeystroke: { _ in keystrokes += 1; return true },
                                   frontmostBundleID: { "com.example.target" })
        var reported: PasteResult?
        service.onResult = { reported = $0 }

        var image = makeTextClip("")
        image.contentKind = .image
        image.mediaFilename = "0000-missing.png"
        XCTAssertEqual(service.paste(image, asPlainText: false), .failed(.mediaMissing))
        XCTAssertEqual(reported, .failed(.mediaMissing))

        var file = makeTextClip("gone.txt")
        file.contentKind = .file
        file.filePath = "/nonexistent/\(UUID().uuidString)/gone.txt"
        XCTAssertEqual(service.pasteFile(file, move: false), .failed(.fileUnavailable))

        XCTAssertEqual(service.pasteCombined([image], asPlainText: false), .failed(.nothingToPaste))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(keystrokes, 0, "no Cmd+V after a failed write")
        XCTAssertEqual(pb.string(forType: .string), "what the user had copied")
    }

    // MARK: CAP-06: activation and Finder

    func testMoveKeystrokeIsOnlySentToFinder() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        let file = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: FileManager.default.temporaryDirectory, create: true)
            .appendingPathComponent("move-me.txt")
        try Data("x".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var clip = makeTextClip("move-me.txt")
        clip.contentKind = .file
        clip.filePath = file.path

        func run(front: String) -> [Bool] {
            var moves: [Bool] = []
            let service = PasteService(monitor: monitor, sendKeystroke: { moves.append($0); return true },
                                       frontmostBundleID: { front })
            let done = expectation(description: front)
            service.pasteFile(clip, move: true) { _ in done.fulfill() }
            wait(for: [done], timeout: 5)
            return moves
        }
        XCTAssertEqual(run(front: PasteService.finderBundleID), [true])
        XCTAssertEqual(run(front: "com.example.notfinder"), [false])
    }

    func testMissingAccessibilityDegradesToCopyOnly() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        let service = PasteService(monitor: monitor, sendKeystroke: { _ in false }, frontmostBundleID: { "com.example.target" })
        let done = expectation(description: "paste")
        var outcome: PasteResult?
        service.paste(makeTextClip("hello"), asPlainText: true) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outcome, .copiedOnly(.accessibilityNotGranted))
        XCTAssertEqual(pb.string(forType: .string), "hello")
    }

    func testTargetNeverActivatingTimesOutWithoutKeystroke() throws {
        let db = try makeTestDatabase(self)
        let monitor = makeMonitor(db, makePasteboard())
        var keystrokes = 0
        var front = "com.example.clippy"
        let tracker = monitor.sourceTracker
        tracker.record(bundleID: "com.example.editor", name: "Editor", at: Date())
        let service = PasteService(monitor: monitor, sendKeystroke: { _ in keystrokes += 1; return true },
                                   frontmostBundleID: { front }, activationCenter: NotificationCenter(), activationTimeout: 0.2,
                                   ownBundleID: "com.example.clippy")
        let done = expectation(description: "paste")
        var outcome: PasteResult?
        service.paste(makeTextClip("hello"), asPlainText: true) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outcome, .copiedOnly(.targetNotActivated))
        XCTAssertEqual(keystrokes, 0)
        front = "com.example.editor"
    }

    func testActivationWaiterCompletesOnNotificationAndOnTimeout() {
        let center = NotificationCenter()
        var ready = false
        let activated = expectation(description: "activated")
        var result: Bool?
        ActivationWaiter.wait(until: { ready }, timeout: 5, center: center) { result = $0; activated.fulfill() }
        ready = true
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wait(for: [activated], timeout: 2)
        XCTAssertEqual(result, true)

        let timedOut = expectation(description: "timeout")
        var second: Bool?
        ActivationWaiter.wait(until: { false }, timeout: 0.1, center: center) { second = $0; timedOut.fulfill() }
        wait(for: [timedOut], timeout: 2)
        XCTAssertEqual(second, false)

        let immediate = expectation(description: "immediate")
        var count = 0
        ActivationWaiter.wait(until: { true }, timeout: 5, center: center) { _ in count += 1; immediate.fulfill() }
        wait(for: [immediate], timeout: 2)
        XCTAssertEqual(count, 1)
    }

    // MARK: PLT-09

    func testPrivacyAccessReportsAllowedOnAScratchPasteboard() {
        XCTAssertEqual(PasteboardPrivacy.access(of: makePasteboard()), .allowed)
    }
}
