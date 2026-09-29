import XCTest
@testable import Clippy

@MainActor
private final class FakeWatch: ExternalEditorWatch {
    var cancelled = false
    func cancel() { cancelled = true }
}

@MainActor
private final class FakeFileSystem: ExternalEditorFileSystem {
    var files: [URL: String] = [:]
    var failWrites = false
    /// Number of upcoming watch() calls that fail (file not there yet).
    var watchFailures = 0
    var watches: [FakeWatch] = []
    var handler: (@MainActor (ExternalEditorWatchEvent) -> Void)?
    private(set) var writeCount = 0

    func read(_ url: URL) -> String? { files[url] }
    func write(_ text: String, to url: URL) throws {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        writeCount += 1
        files[url] = text
    }
    func remove(_ url: URL) { files[url] = nil }
    func watch(_ url: URL, handler: @escaping @MainActor (ExternalEditorWatchEvent) -> Void) -> ExternalEditorWatch? {
        if watchFailures > 0 { watchFailures -= 1; return nil }
        let watch = FakeWatch()
        watches.append(watch)
        self.handler = handler
        return watch
    }
}

@MainActor
private final class FakeScheduler: ExternalEditorScheduler {
    private final class Timer: ExternalEditorTimer {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private var pending: [(delay: TimeInterval, timer: Timer, work: @MainActor () -> Void)] = []
    private(set) var delays: [TimeInterval] = []

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ExternalEditorTimer {
        let timer = Timer()
        pending.append((seconds, timer, work))
        delays.append(seconds)
        return timer
    }

    var livePending: Int { pending.filter { !$0.timer.cancelled }.count }

    /// Fires every live timer once (in order), like time passing.
    func fireAll() {
        let batch = pending
        pending = []
        for item in batch where !item.timer.cancelled { item.work() }
    }
}

@MainActor
final class ExternalEditorSessionTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/clippy-test/clip-1.txt")
    private var fileSystem = FakeFileSystem()
    private var scheduler = FakeScheduler()
    private var persisted: [String] = []
    private var persistResult = true

    override func setUp() {
        super.setUp()
        fileSystem = FakeFileSystem()
        scheduler = FakeScheduler()
        persisted = []
        persistResult = true
    }

    private func makeSession(initial: String = "hello") throws -> ExternalEditorSession {
        let session = ExternalEditorSession(
            clipID: 1, url: url, initialText: initial,
            fileSystem: fileSystem, scheduler: scheduler,
            persist: { [unowned self] text in
                persisted.append(text)
                return persistResult
            })
        try session.start()
        return session
    }

    func testStartWritesFileAndArmsWatcher() throws {
        let session = try makeSession()
        XCTAssertEqual(fileSystem.files[url], "hello")
        XCTAssertTrue(session.isWatching)
    }

    func testBurstOfEventsIsDebouncedIntoOneWrite() throws {
        let session = try makeSession()
        fileSystem.files[url] = "one"
        session.fileDidChange()
        fileSystem.files[url] = "two"
        session.fileDidChange()
        fileSystem.files[url] = "three"
        session.fileDidChange()
        XCTAssertEqual(scheduler.livePending, 1)
        XCTAssertTrue(persisted.isEmpty)
        scheduler.fireAll()
        XCTAssertEqual(persisted, ["three"])
        XCTAssertEqual(scheduler.delays.first, 0.25)
    }

    func testEmptyReadIsIgnoredWhilePreviousTextNonEmpty() throws {
        let session = try makeSession()
        fileSystem.files[url] = ""   // truncate before the editor rewrites
        session.fileDidChange()
        scheduler.fireAll()
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(session.lastKnownText, "hello")
        // The rewrite that follows the truncate is then picked up.
        fileSystem.files[url] = "hello world"
        session.fileDidChange()
        scheduler.fireAll()
        XCTAssertEqual(persisted, ["hello world"])
    }

    func testEmptyReadAllowedWhenPreviousTextWasEmpty() throws {
        let session = try makeSession(initial: "")
        fileSystem.files[url] = "x"
        session.fileDidChange()
        scheduler.fireAll()
        XCTAssertEqual(persisted, ["x"])
    }

    func testLastKnownTextAdvancesOnlyAfterSuccessfulWrite() throws {
        let session = try makeSession()
        persistResult = false
        fileSystem.files[url] = "edited"
        session.fileDidChange()
        scheduler.fireAll()
        XCTAssertEqual(session.lastKnownText, "hello")
        XCTAssertEqual(session.persistFailures, 1)
        // The retry timer re-reads and succeeds once the DB recovers.
        persistResult = true
        scheduler.fireAll()
        XCTAssertEqual(persisted, ["edited", "edited"])
        XCTAssertEqual(session.lastKnownText, "edited")
        XCTAssertEqual(session.persistFailures, 0)
    }

    func testUnchangedTextDoesNotPersist() throws {
        let session = try makeSession()
        session.fileDidChange()
        scheduler.fireAll()
        XCTAssertTrue(persisted.isEmpty)
    }

    func testReplacedEventRearmsWatcherAndSyncs() throws {
        let session = try makeSession()
        let first = fileSystem.watches[0]
        fileSystem.files[url] = "atomic save"
        session.fileDidChange(.replaced)
        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(fileSystem.watches.count, 2)
        XCTAssertTrue(session.isWatching)
        scheduler.fireAll()
        XCTAssertEqual(persisted, ["atomic save"])
    }

    func testRearmRetriesWithBackoffUntilFileReappears() throws {
        let session = try makeSession()
        fileSystem.watchFailures = 3
        session.fileDidChange(.replaced)
        XCTAssertFalse(session.isWatching)
        var rounds = 0
        while !session.isWatching, rounds < 10 { scheduler.fireAll(); rounds += 1 }
        XCTAssertTrue(session.isWatching)
        XCTAssertEqual(rounds, 3)
        let backoff = scheduler.delays.filter { $0 != 0.25 }
        XCTAssertEqual(backoff, backoff.sorted())
    }

    func testRearmGivesUpAfterMaxAttempts() throws {
        let session = try makeSession()
        fileSystem.watchFailures = 1000
        session.fileDidChange(.replaced)
        for _ in 0..<(ExternalEditorSession.maxRearmAttempts + 3) { scheduler.fireAll() }
        XCTAssertFalse(session.isWatching)
        XCTAssertEqual(scheduler.livePending, 0)
    }

    func testPushFromAppWritesFileWithoutEchoingBack() throws {
        let session = try makeSession()
        XCTAssertTrue(session.pushFromApp("from app"))
        XCTAssertEqual(fileSystem.files[url], "from app")
        session.fileDidChange(.replaced)   // our own atomic write echoes back
        scheduler.fireAll()
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(session.lastKnownText, "from app")
    }

    func testPushFromAppSyncsPendingDiskChangeFirst() throws {
        let session = try makeSession()
        fileSystem.files[url] = "external"
        session.fileDidChange()
        session.pushFromApp("app")
        XCTAssertEqual(persisted, ["external"])
        XCTAssertEqual(fileSystem.files[url], "app")
    }

    func testPushFromAppReportsWriteFailure() throws {
        let session = try makeSession()
        fileSystem.failWrites = true
        XCTAssertFalse(session.pushFromApp("nope"))
        XCTAssertEqual(session.lastKnownText, "hello")
    }

    func testCloseReleasesWatchTimersAndTempFile() throws {
        let session = try makeSession()
        session.fileDidChange()
        session.close()
        XCTAssertTrue(fileSystem.watches[0].cancelled)
        XCTAssertNil(fileSystem.files[url])
        XCTAssertEqual(scheduler.livePending, 0)
        // Events after close do nothing.
        fileSystem.files[url] = "late"
        session.fileDidChange()
        scheduler.fireAll()
        XCTAssertTrue(persisted.isEmpty)
        session.close() // idempotent
    }
}
