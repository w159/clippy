import Foundation

extension Notification.Name {
    /// Posted on the main thread after a clip was captured and saved. userInfo:
    /// `["clipID": Int64]` is set for image captures (nil-id captures omit it).
    static let clippyClipCaptured = Notification.Name("ClippyClipCaptured")
}

/// Opt-in preference for background OCR indexing (default off: it costs CPU
/// and stores recognised text in the local database).
enum OCRIndexPreferences {
    static let key = "ocrIndexEnabled"
    /// Injectable for tests.
    private static let seam = DefaultsSeam()
    static var defaults: UserDefaults {
        get { seam.value }
        set { seam.value = newValue }
    }

    static var isEnabled: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

/// Recognises text in image clips that have none yet, in the background at low
/// priority, one clip at a time with a pause between clips, so image text
/// becomes searchable. Never logs recognised text. Skips clips flagged
/// sensitive and does nothing unless `OCRIndexPreferences.isEnabled`.
final class OCRIndexer: @unchecked Sendable {
    typealias Recognizer = (URL, @escaping @MainActor (OCRService.RecognitionResult) -> Void) -> Void

    enum PassStop: Equatable { case finished, disabled, cancelled, notWarm }

    struct PassResult: Equatable {
        var indexed = 0
        var skippedSensitive = 0
        var failed = 0
        var stop: PassStop = .finished
    }

    private let database: ClipDatabase
    private let recognizer: Recognizer
    private let isEnabled: () -> Bool
    private let customIsWarm: (() -> Bool)?
    private let requestWarmUp: () -> Void
    private let sensitiveStore: () -> SensitiveFlagStore?
    private let pause: (TimeInterval) async -> Void
    private let minimumInterval: TimeInterval
    private let warmRetryDelay: TimeInterval
    private let batchSize: Int
    private let center: NotificationCenter
    private let lock = NSLock()
    private var running = false
    private var rerun = false
    private var worker: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var warmRequestedAt: Date?
    private var lastRecognitionAt: Date?
    /// How long models are considered warm after a warm-up request or recognition.
    private let warmWindow: TimeInterval = 600

    /// - Parameters:
    ///   - isWarm: nil = the built-in heuristic (a recognition or warm-up request
    ///     happened recently). Cold => the indexer requests a warm-up and retries.
    ///   - minimumInterval: pause between two clips (rate limit).
    init(database: ClipDatabase,
         recognizer: @escaping Recognizer = { OCRService.recognizeText(in: $0, completion: $1) },
         isEnabled: @escaping () -> Bool = { OCRIndexPreferences.isEnabled },
         isWarm: (() -> Bool)? = nil,
         requestWarmUp: @escaping () -> Void = { OCRWarmupPolicy.shared.requestWarmup() },
         sensitiveStore: @escaping () -> SensitiveFlagStore? = { SensitiveFlagStore.current },
         minimumInterval: TimeInterval = 2,
         warmRetryDelay: TimeInterval = 30,
         batchSize: Int = 25,
         pause: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         center: NotificationCenter = .default) {
        self.database = database
        self.recognizer = recognizer
        self.isEnabled = isEnabled
        self.requestWarmUp = requestWarmUp
        self.sensitiveStore = sensitiveStore
        self.minimumInterval = minimumInterval
        self.warmRetryDelay = warmRetryDelay
        self.batchSize = batchSize
        self.pause = pause
        self.center = center
        self.customIsWarm = isWarm
    }

    deinit { stop() }

    /// Starts reacting to `clippyClipCaptured` and schedules an initial pass.
    func start() {
        lock.withLock {
            guard observer == nil else { return }
            observer = center.addObserver(forName: .clippyClipCaptured, object: nil, queue: nil) { [weak self] _ in
                self?.kick()
            }
        }
        kick()
    }

    /// Cancels any running pass and stops observing.
    func stop() {
        let (task, token) = lock.withLock { () -> (Task<Void, Never>?, NSObjectProtocol?) in
            let result = (worker, observer)
            worker = nil
            observer = nil
            return result
        }
        task?.cancel()
        if let token { center.removeObserver(token) }
    }

    /// Schedules a pass on a background task unless one is running (then it reruns after).
    func kick() {
        guard isEnabled() else { return }
        lock.withLock {
            if running { rerun = true; return }
            running = true
            worker = Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                var warmRetries = 0
                while true {
                    self.lock.withLock { self.rerun = false }
                    let result = await self.runPass()
                    if result.stop == .notWarm, warmRetries < 3 {
                        warmRetries += 1
                        self.lock.withLock { self.rerun = true }
                        await self.pause(self.warmRetryDelay)
                    }
                    // Decide to continue and release the running flag atomically so a
                    // kick() racing with the end of the loop is never lost.
                    let again = self.lock.withLock { () -> Bool in
                        if Task.isCancelled || !self.rerun {
                            self.running = false
                            return false
                        }
                        return true
                    }
                    if !again { break }
                }
            }
        }
    }

    /// One pass over every unscanned image clip. Public for tests.
    func runPass() async -> PassResult {
        var result = PassResult()
        var cursor = Int64.max
        while true {
            guard isEnabled() else { result.stop = .disabled; return result }
            let batch: [Clip]
            do { batch = try database.clipsNeedingOCR(before: cursor, limit: batchSize) } catch {
                ClippyLog.error("OCR index fetch failed: \(error)", category: ClippyLog.storage)
                return result
            }
            if batch.isEmpty { return result }
            for clip in batch {
                guard let id = clip.id, let filename = clip.mediaFilename else { continue }
                cursor = id
                if Task.isCancelled { result.stop = .cancelled; return result }
                guard isEnabled() else { result.stop = .disabled; return result }
                if SensitiveContent.isSensitive(clip: clip, store: sensitiveStore()) {
                    result.skippedSensitive += 1
                    continue
                }
                guard (customIsWarm?() ?? heuristicWarm()) else {
                    requestWarmUp()
                    lock.withLock { warmRequestedAt = Date() }
                    result.stop = .notWarm
                    return result
                }
                let outcome = await recognize(database.media.url(for: filename))
                // A cancel or opt-out during recognition discards the result.
                if Task.isCancelled { result.stop = .cancelled; return result }
                guard isEnabled() else { result.stop = .disabled; return result }
                lock.withLock { lastRecognitionAt = Date() }
                switch outcome {
                case .success(let text):
                    do {
                        try database.setOCRText(id: id, text: String(text.prefix(200_000)))
                        result.indexed += 1
                    } catch {
                        ClippyLog.error("OCR index write failed: \(error)", category: ClippyLog.storage)
                        result.failed += 1
                    }
                case .failure:
                    result.failed += 1
                }
                await pause(minimumInterval)
            }
        }
    }

    private func recognize(_ url: URL) async -> OCRService.RecognitionResult {
        await withCheckedContinuation { continuation in
            recognizer(url) { continuation.resume(returning: $0) }
        }
    }

    private func heuristicWarm() -> Bool {
        lock.withLock {
            let recent = [lastRecognitionAt, warmRequestedAt.map { $0.addingTimeInterval(warmRetryDelay) }]
                .compactMap { $0 }.max()
            guard let recent else { return false }
            return Date().timeIntervalSince(recent) < warmWindow && recent <= Date()
        }
    }
}
