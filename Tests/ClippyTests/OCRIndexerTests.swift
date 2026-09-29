import XCTest
@testable import Clippy

@MainActor
final class OCRIndexerTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var maxActive = 0
        private(set) var urls: [URL] = []
        func begin(_ url: URL) {
            lock.withLock { active += 1; maxActive = Swift.max(maxActive, active); urls.append(url) }
        }
        func end() { lock.withLock { active -= 1 } }
    }

    private func addImage(_ db: ClipDatabase, _ name: String) throws -> Int64 {
        var clip = Clip(id: nil, contentText: "", contentRTF: nil, contentHTML: nil, typeIdentifier: "public.png",
                        sourceAppBundleID: nil, sourceAppName: "Shots", createdAt: Date(), contentKind: .image,
                        mediaFilename: name, thumbFilename: name)
        try db.saveCapturedImageClip(&clip, cap: 100)
        return try db.dbQueue.read { try Int64.fetchOne($0, sql: "SELECT MAX(id) FROM clips")! }
    }

    private func makeIndexer(_ db: ClipDatabase, probe: Probe, enabled: @escaping () -> Bool = { true },
                             warm: @escaping () -> Bool = { true }, flags: SensitiveFlagStore? = nil,
                             pauses: PauseLog = PauseLog(),
                             text: @escaping (URL) -> String = { "text of \($0.lastPathComponent)" }) -> OCRIndexer {
        OCRIndexer(
            database: db,
            recognizer: { url, done in
                probe.begin(url)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                    probe.end()
                    done(.success(text(url)))
                }
            },
            isEnabled: enabled, isWarm: warm, requestWarmUp: { pauses.warmRequests += 1 },
            sensitiveStore: { flags }, minimumInterval: 0.5, warmRetryDelay: 1, batchSize: 2,
            pause: { pauses.record($0) })
    }

    final class PauseLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TimeInterval] = []
        var warmRequests = 0
        func record(_ value: TimeInterval) { lock.withLock { values.append(value) } }
        var all: [TimeInterval] { lock.withLock { values } }
    }

    func testPreferenceDefaultsOff() {
        let suite = UserDefaults(suiteName: "ocr-index-\(UUID().uuidString)")!
        let saved = OCRIndexPreferences.defaults
        OCRIndexPreferences.defaults = suite
        defer { OCRIndexPreferences.defaults = saved }
        XCTAssertFalse(OCRIndexPreferences.isEnabled)
        OCRIndexPreferences.isEnabled = true
        XCTAssertTrue(OCRIndexPreferences.isEnabled)
    }

    func testIndexesAllImagesSeriallyWithRateLimit() async throws {
        let db = try makeTestDatabase(self)
        for name in ["a.png", "b.png", "c.png"] { _ = try addImage(db, name) }
        let probe = Probe()
        let pauses = PauseLog()
        let result = await makeIndexer(db, probe: probe, pauses: pauses).runPass()
        XCTAssertEqual(result, OCRIndexer.PassResult(indexed: 3, skippedSensitive: 0, failed: 0, stop: .finished))
        XCTAssertEqual(probe.maxActive, 1)
        XCTAssertEqual(pauses.all, [0.5, 0.5, 0.5])
        XCTAssertEqual(try db.search(matching: "text of a.png", limit: 5).hits.map(\.matchedIn), [.ocr])
        XCTAssertTrue(try db.clipsNeedingOCR(limit: 10).isEmpty)
    }

    func testDisabledDoesNothing() async throws {
        let db = try makeTestDatabase(self)
        _ = try addImage(db, "a.png")
        let probe = Probe()
        let result = await makeIndexer(db, probe: probe, enabled: { false }).runPass()
        XCTAssertEqual(result.stop, .disabled)
        XCTAssertTrue(probe.urls.isEmpty)
        XCTAssertEqual(try db.clipsNeedingOCR(limit: 10).count, 1)
    }

    func testSkipsSensitiveImagesAndNeverRetriesThemInPass() async throws {
        let db = try makeTestDatabase(self)
        let secret = try addImage(db, "secret.png")
        _ = try addImage(db, "ok.png")
        let flags = SensitiveFlagStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("flags-\(UUID().uuidString)"))
        let key = Clip.contentKey(kind: .image, text: "", mediaFilename: "secret.png", filePath: nil)
        flags.setOverride(key: key, isSensitive: true)
        let probe = Probe()
        let result = await makeIndexer(db, probe: probe, flags: flags).runPass()
        XCTAssertEqual(result.indexed, 1)
        XCTAssertEqual(result.skippedSensitive, 1)
        XCTAssertEqual(probe.urls.map(\.lastPathComponent), ["ok.png"])
        let stored = try await db.dbQueue.read { try Clip.fetchOne($0, key: secret)! }
        XCTAssertNil(stored.ocrText)
    }

    func testColdModelsRequestWarmUpAndStop() async throws {
        let db = try makeTestDatabase(self)
        _ = try addImage(db, "a.png")
        let probe = Probe()
        let pauses = PauseLog()
        let result = await makeIndexer(db, probe: probe, warm: { false }, pauses: pauses).runPass()
        XCTAssertEqual(result.stop, .notWarm)
        XCTAssertEqual(pauses.warmRequests, 1)
        XCTAssertTrue(probe.urls.isEmpty)
    }

    func testCancellationStopsBeforeNextClipAndDiscardsNothingWritten() async throws {
        let db = try makeTestDatabase(self)
        for name in ["a.png", "b.png", "c.png", "d.png"] { _ = try addImage(db, name) }
        let probe = Probe()
        let indexer = makeIndexer(db, probe: probe)
        let task = Task { await indexer.runPass() }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.stop, .cancelled)
        XCTAssertLessThan(result.indexed, 4)
        XCTAssertEqual(try db.clipsNeedingOCR(limit: 10).count, 4 - result.indexed)
    }

    func testRecognitionFailureLeavesClipUnscannedAndContinues() async throws {
        let db = try makeTestDatabase(self)
        _ = try addImage(db, "bad.png")
        _ = try addImage(db, "good.png")
        struct Boom: Error {}
        let indexer = OCRIndexer(
            database: db,
            recognizer: { url, done in
                done(url.lastPathComponent == "bad.png" ? .failure(Boom()) : .success("fine"))
            },
            isEnabled: { true }, isWarm: { true }, requestWarmUp: {}, sensitiveStore: { nil },
            minimumInterval: 0, batchSize: 1, pause: { _ in })
        let result = await indexer.runPass()
        XCTAssertEqual(result.indexed, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(try db.clipsNeedingOCR(limit: 10).count, 1)
    }

    func testCapturedNotificationTriggersPass() async throws {
        let db = try makeTestDatabase(self)
        let id = try addImage(db, "n.png")
        let center = NotificationCenter()
        let probe = Probe()
        let indexer = OCRIndexer(
            database: db,
            recognizer: { url, done in probe.begin(url); probe.end(); done(.success("notified")) },
            isEnabled: { true }, isWarm: { true }, requestWarmUp: {}, sensitiveStore: { nil },
            minimumInterval: 0, pause: { _ in }, center: center)
        indexer.start()
        defer { indexer.stop() }
        center.post(name: .clippyClipCaptured, object: nil, userInfo: ["clipID": id])
        for _ in 0..<100 where try db.clipsNeedingOCR(limit: 1).count > 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let notifiedText = try await db.dbQueue.read { try Clip.fetchOne($0, key: id)?.ocrText }
        XCTAssertEqual(notifiedText, "notified")
    }
}
