import AppKit
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted on the main thread immediately after a clip is saved, at the same
    /// instant the capture sound fires. The status item observes it to bounce
    /// the mascot in sync with the sound.
    static let clippyDidCapture = Notification.Name("ClippyDidCapture")
}

/// Watches NSPasteboard.general by polling changeCount (the only supported
/// detection mechanism on macOS) and stores new items.
///
/// `ObservableObject` so the UI can surface `failureCount` / `hasRepeatedFailures`
/// (CAP-05) and `readingBlockedByPrivacy` (PLT-09).
@MainActor
final class ClipboardMonitor: ObservableObject {
    let database: ClipDatabase
    let pasteboard: NSPasteboard
    /// Attributes copies to the app that made them (CAP-04).
    let sourceTracker: SourceAppTracker
    private let flavorStore: FlavorStore
    private let flagStore: SensitiveFlagStore
    /// Remembers the last text clip for "copy twice to append" (FEAT-13).
    private let appendTracker = ClipAppendTracker()
    private var timer: Timer?
    private var lastChangeCount = 0
    private var cancellables = Set<AnyCancellable>()

    /// Change counts of pasteboard writes Clippy itself produced. Exactly these
    /// are skipped, so a foreign copy made around the same moment is never lost
    /// (CAP-02).
    private var ownWriteCounts = Set<Int>()

    /// Legacy one-shot armed by `ignoreNextChange()`: skips the change that is
    /// exactly one past `baseline`, and only within its short window.
    private var armedIgnore: (baseline: Int, expires: Date)?
    private static let armedIgnoreWindow: TimeInterval = 1.5

    /// When the previous poll ran, and the start of the window the current
    /// change was first seen in; the source app is resolved against that window.
    private var lastPollDate = Date()
    private var sourceWindowStart = Date()

    /// A change whose file capture failed outright, allowed to run again.
    private var forcedRetryChangeCount: Int?
    private var fileRetryCounts: [Int: Int] = [:]
    private static let maxFileRetries = 2

    /// The changeCount of a pasteboard write we have seen but that had not been
    /// filled in yet, and when we first saw it. See tick().
    private var unresolvedChangeCount: Int?
    private var unresolvedSince = Date.distantPast

    /// How long a change may stay unresolved before it is retired anyway. Long
    /// enough for the slowest multi-flavor writers, short enough that a flavor
    /// we will never support cannot keep the poll re-reading the pasteboard.
    private static let unresolvedGrace: TimeInterval = 2.0

    // MARK: Published health (main thread only)

    /// Total capture failures since launch (CAP-05).
    @Published private(set) var failureCount = 0
    /// Failures since the last successful capture.
    @Published private(set) var consecutiveFailures = 0
    /// The most recent failure, described without clip content.
    @Published private(set) var lastFailure: String?
    /// True while macOS denies this app pasteboard reads (PLT-09).
    @Published private(set) var readingBlockedByPrivacy = false

    /// Consecutive failures at which `hasRepeatedFailures` turns true.
    static let repeatedFailureThreshold = 3
    var hasRepeatedFailures: Bool { consecutiveFailures >= Self.repeatedFailureThreshold }

    /// Delivers the user notification for an auto-cleared sensitive clip.
    /// Replaceable so tests never touch UserNotifications.
    var autoClearNotifier: (_ title: String, _ body: String) -> Void = { CaptureNotifier.post(title: $0, body: $1) }

    /// Serial queue for the heavy capture work (DB write, FTS reindex, eviction,
    /// media file copy, thumbnail encoding). The poll timer fires on the main
    /// run loop, so doing this work inline froze the UI on every copy; under DB
    /// queue contention (e.g. a background iCloud export holding the shared
    /// DatabaseQueue) the main thread could stall until the write committed.
    /// The pasteboard is still read on the main thread (AppKit-affined), then
    /// the save is dispatched here. Serial to preserve capture order and keep
    /// concurrent evictions from racing on the shared DatabaseQueue.
    private let captureQueue = DispatchQueue(label: "com.bytesavvy.clippy.capture-save", qos: .userInitiated)

    var isPaused = false

    /// A pasteboard file URL that survived classification, with the facts the
    /// save loop needs so it does not re-stat the file off-main.
    struct FileCandidate: Equatable {
        let url: URL
        let isRegularFile: Bool
        let byteSize: Int
    }

    /// Decide whether a pasteboard file URL can become a clip, and how.
    ///
    /// Returns nil for anything that cannot: a symlink to nowhere, an empty
    /// regular file, or an iCloud item whose bytes are not on disk yet. Reading
    /// an evicted item would either block on a download or throw, and neither
    /// belongs on a clipboard poll.
    ///
    /// Directories come back with `isRegularFile == false`. They are viable -
    /// the clip is the path - but they must never reach `MediaStore.storeFile`,
    /// which reads bytes and throws EISDIR on a folder.
    static func classify(_ url: URL) -> FileCandidate? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        if values.isUbiquitousItem == true,
           let status = values.ubiquitousItemDownloadingStatus,
           status != .current {
            ClippyLog.warning("Skipping file clip: iCloud item not downloaded",
                              category: ClippyLog.capture)
            return nil
        }

        if values.isDirectory == true {
            return FileCandidate(url: url, isRegularFile: false, byteSize: 0)
        }

        guard values.isRegularFile == true else { return nil }
        let size = values.fileSize ?? 0
        guard size > 0 else { return nil }
        return FileCandidate(url: url, isRegularFile: true, byteSize: size)
    }

    /// Whether `url`'s extension identifies it as an image ImageIO/Vision can
    /// decode. A copied image is not always image-only on the pasteboard: apps
    /// like Finder, Preview, and some screenshot flows also put a file URL
    /// alongside the image data, and the file-URL path is captured first (see
    /// the comment in `captureCurrentPasteboard`). Without this check that
    /// produces a bare "path only" file clip with no preview and no OCR. When
    /// this returns true, `captureFileIfPresent` additionally thumbnails the
    /// file so it previews and can be OCR'd like a real image clip, while
    /// staying a `.file` clip (Paste as file / Move / Reveal in Finder unchanged).
    nonisolated static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Recovers the content-hash portion of a `MediaStore.storeFile` filename
    /// (which is `hash`, or `hash.ext` when the source had an extension), so a
    /// follow-up `imageThumbnail(forFileAt:hash:)` call can key its thumbnail
    /// off the exact same hash instead of recomputing it from the file bytes.
    private nonisolated static func contentHash(fromStoredFilename filename: String, extension ext: String) -> String {
        ext.isEmpty ? filename : String(filename.dropLast(ext.count + 1))
    }

    /// Pasteboard types that mean "do not record this". ConcealedType is the
    /// convention password managers (1Password, Bitwarden, ...) set on copied
    /// secrets; TransientType marks ephemeral writes; AutoGeneratedType marks
    /// machine-made content. The legacy identifiers are what older password
    /// managers and clipboard tools still write (nspasteboard.org).
    static let skippedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",
    ]

    /// Whether a copy carrying `types` must not be recorded: it has a
    /// conceal/transient/auto-generated marker, or any type equals or conforms to
    /// an entry in the user's `blocklist`.
    static func shouldSkip(types: [String], blocklist: [String]) -> Bool {
        if types.contains(where: skippedTypes.contains) { return true }
        guard !blocklist.isEmpty else { return false }
        let blocked = blocklist.map { ($0, UTType($0)) }
        return types.contains { type in
            let uti = UTType(type)
            return blocked.contains { id, blockedUTI in
                if type == id { return true }
                guard let uti, let blockedUTI else { return false }
                return uti.conforms(to: blockedUTI)
            }
        }
    }

    /// The pasteboard is injectable so the capture path can be driven headlessly
    /// in tests; production always watches the general pasteboard.
    init(database: ClipDatabase, pasteboard: NSPasteboard = .general, sourceTracker: SourceAppTracker = SourceAppTracker()) {
        self.database = database
        self.pasteboard = pasteboard
        self.sourceTracker = sourceTracker
        self.flavorStore = FlavorStore(directory: database.media.sidecarDirectory)
        self.flagStore = SensitiveFlagStore(directory: database.media.sidecarDirectory)
    }

    // MARK: - Timer and polling

    func start() {
        // With capture-on-launch the first poll sees a "changed" pasteboard and
        // captures what is already there (opt-in; see CapturePreferences).
        lastChangeCount = CapturePreferences.captureOnLaunch ? -1 : pasteboard.changeCount
        sourceWindowStart = Date()
        SensitiveFlagStore.register(flagStore)
        scheduleTimer()
        AppSettings.shared.$pollingIntervalMs
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleTimer() }
            .store(in: &cancellables)
    }

    /// Legacy entry point for writers that cannot report their change count:
    /// skips the change exactly one past the current count, within a short
    /// window. Prefer `performOwnWrite(_:)`, which skips exactly what was written.
    func ignoreNextChange() {
        armedIgnore = (pasteboard.changeCount, Date().addingTimeInterval(Self.armedIgnoreWindow))
    }

    /// Records that the pasteboard changes in `range` were produced by Clippy so
    /// the poll skips exactly those (CAP-02).
    func registerOwnWrite(changeCounts range: ClosedRange<Int>) {
        ownWriteCounts.formUnion(range)
        if ownWriteCounts.count > 64 { ownWriteCounts = ownWriteCounts.filter { $0 >= range.lowerBound } }
    }

    /// Runs `body` (a Clippy pasteboard write) and registers the change counts it
    /// produced. A write that changed nothing registers nothing, so a stale
    /// entry can never swallow a later foreign copy.
    @discardableResult
    func performOwnWrite<T>(_ body: () -> T) -> T {
        let before = pasteboard.changeCount
        let result = body()
        let after = pasteboard.changeCount
        if after > before { registerOwnWrite(changeCounts: (before + 1)...after) }
        return result
    }

    private func consumeOwnWrite(_ changeCount: Int) -> Bool {
        defer { ownWriteCounts = ownWriteCounts.filter { $0 > changeCount } }
        if ownWriteCounts.contains(changeCount) {
            armedIgnore = nil
            return true
        }
        if let armed = armedIgnore {
            armedIgnore = nil
            return Date() < armed.expires && changeCount == armed.baseline + 1
        }
        return false
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = max(0.05, AppSettings.shared.pollingIntervalMs / 1000.0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One poll. Internal rather than private so tests can drive the capture
    /// path deterministically instead of waiting on the timer.
    func tick() {
        let previousPoll = lastPollDate
        lastPollDate = Date()
        let changeCount = pasteboard.changeCount
        let forced = forcedRetryChangeCount == changeCount
        guard changeCount != lastChangeCount || forced else { return }
        forcedRetryChangeCount = nil
        if changeCount != unresolvedChangeCount, !forced { sourceWindowStart = previousPoll }

        if consumeOwnWrite(changeCount) {
            retire(changeCount)
            return
        }
        guard !isPaused else {
            retire(changeCount)
            return
        }

        // An app that writes several flavors bumps changeCount on
        // clearContents() and fills the data in up to a few hundred ms later.
        // Retiring the change on that first empty look loses the copy for good
        // (no clip, no mascot bounce, no capture sound) because the changeCount
        // never comes around again. Keep the change live until the pasteboard
        // resolves, or until the grace period expires.
        if captureCurrentPasteboard() {
            retire(changeCount)
        } else if unresolvedChangeCount != changeCount {
            unresolvedChangeCount = changeCount
            unresolvedSince = Date()
        } else if Date().timeIntervalSince(unresolvedSince) >= Self.unresolvedGrace {
            retire(changeCount)
        }
    }

    /// Marks a pasteboard change as dealt with so it is never looked at again.
    private func retire(_ changeCount: Int) {
        lastChangeCount = changeCount
        unresolvedChangeCount = nil
    }

    // MARK: - Health counters

    /// Callable from the capture queue: hops to the main actor to touch the counters.
    private nonisolated func recordFailure(_ what: String) {
        DispatchQueue.main.async { [weak self] in self?.recordFailureOnMain(what) }
    }

    private func recordFailureOnMain(_ what: String) {
        failureCount += 1
        consecutiveFailures += 1
        lastFailure = what
    }

    private func recordSuccess() {
        if consecutiveFailures != 0 { consecutiveFailures = 0 }
    }

    private func setReadingBlocked(_ blocked: Bool) {
        if readingBlockedByPrivacy != blocked { readingBlockedByPrivacy = blocked }
    }

    // MARK: - Sound feedback

    /// Bounce + sound for a stored capture. `appended` marks an append-merge into an
    /// existing clip, which is not a new clip for the paste stack.
    fileprivate func playCaptureSound(appended: Bool = false) {
        if !appended { NotificationCenter.default.post(name: .clippyPasteStackCaptured, object: nil) }
        let settings = AppSettings.shared
        // Fire the menu bar mascot bounce on the same event so icon and sound
        // are perfectly in sync, whether or not the sound itself is enabled.
        NotificationCenter.default.post(name: .clippyDidCapture, object: nil)
        guard settings.captureSoundEnabled else { return }
        SoundPlayer.play(id: settings.captureSoundID, volume: SoundPlayer.sliderToVolume(settings.captureSoundVolume))
    }
}

// MARK: - Capture pipeline

extension ClipboardMonitor {
    private static let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    private static let heicType = NSPasteboard.PasteboardType("public.heic")
    private static let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")
    private static let vcardType = NSPasteboard.PasteboardType("public.vcard")

    /// Returns true when this change is resolved: something was captured, or it
    /// was deliberately skipped. False means the pasteboard has not been filled
    /// in yet and the change deserves another look.
    ///
    /// Deliberate skips (concealed types, ignored source apps) MUST return true.
    /// Retrying one of those would re-read it after the frontmost app changed,
    /// which is how a password copy would end up in history.
    fileprivate func captureCurrentPasteboard() -> Bool {
        guard PasteboardPrivacy.access(of: pasteboard) != .denied else {
            setReadingBlocked(true)
            return true
        }
        setReadingBlocked(false)
        guard let types = pasteboard.types, !types.isEmpty else { return false }
        guard !Self.shouldSkip(types: types.map(\.rawValue), blocklist: CapturePreferences.typeBlocklist) else { return true }

        // Source attribution: the org.nspasteboard.source hint, else the app that
        // was active for the copy. The ignore list is applied to every plausible
        // source, so a copy straddling an app switch fails closed.
        let attribution = sourceTracker.attribution(pasteboard: pasteboard, lastPoll: sourceWindowStart)
        let ignored = Set(AppSettings.shared.ignoredBundleIDs)
        if attribution.all.contains(where: { ignored.contains($0.bundleID) }) { return true }
        var source = attribution.primary
        if source == nil, let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier {
            if ignored.contains(id) { return true }
            source = SourceAppTracker.App(bundleID: id, name: front.localizedName)
        }

        // File URLs must be checked before the text path: Finder's copy puts
        // both a file URL and a display-name string on the pasteboard, and we
        // want the richer file clip, not a bare filename text clip.
        if captureFileIfPresent(from: source) { return true }

        if let text = Self.plainText(from: pasteboard) {
            captureText(text, typeIdentifier: nil, from: source)
            return true
        }
        if let fallback = Self.fallbackText(from: pasteboard) {
            captureText(fallback.text, typeIdentifier: fallback.type, from: source)
            return true
        }
        return captureImageIfPresent(from: source)
    }

    /// The pasteboard's text. A multi-item pasteboard (several strings copied at
    /// once) is joined with newlines; a single item is returned as is. Blank
    /// text is nil, checked without copying or trimming the string.
    static func plainText(from pasteboard: NSPasteboard) -> String? {
        if let items = pasteboard.pasteboardItems, items.count > 1 {
            let strings = items.compactMap { $0.string(forType: .string) }.filter { $0.contains { !$0.isWhitespace } }
            if !strings.isEmpty { return strings.joined(separator: "\n") }
        }
        guard let text = pasteboard.string(forType: .string), text.contains(where: { !$0.isWhitespace }) else { return nil }
        return text
    }

    /// Text for a pasteboard with no plain string: a copied color as hex, a
    /// vCard as its source text, or the plain text of RTFD.
    static func fallbackText(from pasteboard: NSPasteboard) -> (text: String, type: String)? {
        let types = pasteboard.types ?? []
        if types.contains(.color), let color = NSColor(from: pasteboard)?.usingColorSpace(.sRGB) {
            let hex = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                             Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
            return (hex, NSPasteboard.PasteboardType.color.rawValue)
        }
        if let data = pasteboard.data(forType: vcardType), let card = String(data: data, encoding: .utf8),
           card.contains(where: { !$0.isWhitespace }) {
            return (card, vcardType.rawValue)
        }
        if let data = pasteboard.data(forType: .rtfd),
           let plain = NSAttributedString(rtfd: data, documentAttributes: nil)?.string,
           plain.contains(where: { !$0.isWhitespace }) {
            return (plain, NSPasteboard.PasteboardType.rtfd.rawValue)
        }
        return nil
    }

    /// Extra flavors to preserve for the current pasteboard, within budget.
    private func flavorSnapshot(excluding: Set<String>) -> PasteboardSnapshot? {
        guard CapturePreferences.preserveFlavors else { return nil }
        return PasteboardFlavors.snapshot(from: pasteboard, budget: CapturePreferences.flavorBudgetBytes, excluding: excluding)
    }

    private func captureText(_ text: String, typeIdentifier override: String?, from source: SourceAppTracker.App?) {
        // Snapshot the pasteboard on the main thread (AppKit-affined), then
        // dispatch the DB write off-main so a copy never blocks the UI.
        let rtf = pasteboard.data(forType: .rtf)
        let html = pasteboard.data(forType: .html)
        let typeIdentifier: String
        if let override {
            typeIdentifier = override
        } else if rtf != nil {
            typeIdentifier = "public.rtf"
        } else if html != nil {
            typeIdentifier = "public.html"
        } else {
            typeIdentifier = "public.utf8-plain-text"
        }
        let flavors = flavorSnapshot(excluding: [])
        let capturedChangeCount = pasteboard.changeCount
        let bundleID = source?.bundleID
        let appName = source?.name
        let createdAt = Date()
        let cap = AppSettings.shared.maxHistoryItems
        let database = self.database
        let flavorStore = self.flavorStore
        let flagStore = self.flagStore
        let appendTracker = self.appendTracker

        captureQueue.async { [weak self] in
            // Detection and hashing run here, off the main thread: both are
            // linear in the text and a huge paste must not stall the UI.
            let findings = SensitiveContent.detect(text)
            let sensitive = findings.contains { $0.confidence >= SensitiveContent.sensitiveThreshold }
            let key = Clip.contentKey(kind: .text, text: text, mediaFilename: nil, filePath: nil)
            // Opt-in "copy twice to append" (FEAT-13): a quick second copy from the
            // same app extends the previous clip instead of adding one. Never for sensitive text.
            let appendDecision = appendTracker.evaluate(text: text, bundleID: bundleID, sensitive: sensitive, now: createdAt)
            if case .append(let targetID, let merged) = appendDecision {
                do {
                    try database.updateClipText(id: targetID, newText: merged)
                } catch {
                    ClippyLog.error("Failed to append to clip: \(error)", category: ClippyLog.capture)
                    appendTracker.forget()
                    self?.recordFailure("Could not append to the previous clip")
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    self?.recordSuccess()
                    self?.playCaptureSound(appended: true)
                }
                return
            }
            var clip = Clip(
                id: nil,
                contentText: text,
                contentRTF: rtf,
                contentHTML: html,
                typeIdentifier: typeIdentifier,
                sourceAppBundleID: bundleID,
                sourceAppName: appName,
                createdAt: createdAt
            )
            do {
                if let flavors {
                    do { try flavorStore.write(flavors, key: key) } catch {
                        ClippyLog.warning("Could not preserve pasteboard flavors: \(error)", category: ClippyLog.capture)
                    }
                }
                flagStore.record(key: key, findings: findings)
                try database.saveCapturedClip(&clip, cap: cap)
                appendTracker.recordSaved(clipID: clip.id, text: text, bundleID: bundleID, date: createdAt, sensitive: sensitive)
                var savedID = clip.id
                if sensitive, savedID == nil {
                    savedID = try? database.dbQueue.read { try Clip.duplicateText(of: text).fetchOne($0)?.id }
                }
                let clipID = savedID
                // Sound/title fire only after a confirmed save; duplicates or DB
                // errors get no feedback. Hop back to main for AppKit + the
                // .clippyDidCapture notification the status item observes.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.recordSuccess()
                    self.playCaptureSound()
                    if sensitive {
                        let delay = TimeInterval(CapturePreferences.sensitiveAutoClearSeconds)
                        if delay > 0 {
                            self.scheduleAutoClear(changeCount: capturedChangeCount, clipID: clipID, key: key, after: delay)
                        }
                    } else {
                        // Sensitive text is never handed to the title suggester.
                        self.maybeAutoSuggestTitle(forText: text, clipID: clipID)
                    }
                }
            } catch {
                ClippyLog.error("Failed to save clip: \(error)", category: ClippyLog.capture)
                self?.recordFailure("Could not save a text clip")
            }
        }
    }

    // MARK: Sensitive auto-clear

    /// After `delay`, removes a sensitive copy from the clipboard (only if it is
    /// still the current contents) and, per `CapturePreferences.autoClearDeletesHistory`,
    /// from history; then posts a user notification (no clip content in it).
    func scheduleAutoClear(changeCount: Int, clipID: Int64?, key: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            var clearedClipboard = false
            var deletedHistory = false
            if self.pasteboard.changeCount == changeCount {
                self.performOwnWrite { self.pasteboard.clearContents() }
                clearedClipboard = true
            }
            if CapturePreferences.autoClearDeletesHistory, let clipID {
                do {
                    try self.database.deleteClip(id: clipID)
                    self.flavorStore.delete(key: key)
                    deletedHistory = true
                } catch {
                    ClippyLog.error("Auto-clear could not delete a sensitive clip: \(error)", category: ClippyLog.capture)
                }
            }
            if clearedClipboard || deletedHistory {
                let what = [clearedClipboard ? "the clipboard" : nil, deletedHistory ? "history" : nil].compactMap { $0 }
                self.autoClearNotifier("Sensitive item cleared", "Clippy removed a sensitive item from \(what.joined(separator: " and ")).")
            }
        }
    }

    /// The one auto-applied agentic action: when enabled, give a freshly captured
    /// text clip an AI-suggested title. Opt-in, detached, and best-effort, so it
    /// never blocks or breaks capture; the title is still user-editable.
    fileprivate func maybeAutoSuggestTitle(forText text: String, clipID: Int64?) {
        let settings = AppSettings.shared
        guard settings.aiEnabled, settings.aiAutoSuggestTitles, let clipID else { return }
        // Keep automatic clipboard transmission local, but surface a failed
        // resolution rather than hiding it behind canAutoSuggestTitles.
        switch AIProviderStore.shared.resolve() {
        case .failure(let error):
            AIHealth.shared.record(error)
            return
        case .success(let resolved):
            guard resolved.keepsDataOnMac else { return }
        }
        let service: AIService
        switch AIService.fromSettings() {
        case .success(let made): service = made
        case .failure(let error):
            AIHealth.shared.record(error)
            return
        }
        let database = self.database
        Task.detached {
            // Title the exact row we just inserted. Re-finding by content text
            // could match a different clip when identical text was captured twice.
            do {
                let proposal = try await service.suggestTitle(forText: text)
                guard !proposal.proposed.isEmpty else { throw AIError.empty }
                try database.updateClipTitle(id: clipID, userTitle: proposal.proposed)
            } catch {
                await AIHealth.shared.record(error)
            }
        }
    }


    // MARK: File capture

    /// Returns true when viable file URLs were found and dispatched for capture,
    /// so the caller can skip text/image. The byte copy runs off-main, so the
    /// per-item outcome arrives later: successes reset the health counters, and a
    /// selection where every item failed is retried on the next poll (up to
    /// `maxFileRetries` times) and counted in `failureCount` instead of
    /// vanishing (CAP-05). Multi-file Finder selections are captured as one clip
    /// per file URL (mirroring how single-file clips are saved), so a Cmd+C of
    /// five files produces five file clips in history rather than silently
    /// keeping only the first URL.
    @discardableResult
    private func captureFileIfPresent(from frontApp: SourceAppTracker.App?) -> Bool {
        let settings = AppSettings.shared
        guard settings.captureFiles else { return false }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options)
                as? [URL],
              !urls.isEmpty
        else { return false }

        // Classify each URL up front so one bad file in a multi-selection does not
        // abort the whole capture, and so we never hand a byte copy something that
        // cannot produce bytes. A selection with nothing viable returns false here
        // so the caller falls through to text/image capture.
        let viable = urls.compactMap(Self.classify(_:))
        guard !viable.isEmpty else { return false }

        let thresholdBytes = settings.maxFileSizeMB * 1_000_000
        let bundleID = frontApp?.bundleID
        let appName = frontApp?.name
        let changeCount = pasteboard.changeCount
        let cap = settings.maxHistoryItems
        let database = self.database
        let urlsToStore = viable

        // The "handled" decision is made on the main thread from the viable URL
        // list so the caller can skip the text/image fall-through immediately;
        // the byte copy + DB write run off-main so a multi-file Finder copy
        // cannot freeze the UI.
        captureQueue.async { [weak self] in
            var capturedAny = false
            var failures = 0
            for candidate in urlsToStore {
                let fileURL = candidate.url
                let displayName = fileURL.lastPathComponent

                do {
                    var mediaFilename: String? = nil
                    var storedByteSize: Int = candidate.byteSize
                    var thumbFilename: String? = nil
                    var pixelWidth: Int? = nil
                    var pixelHeight: Int? = nil

                    // Only regular files have bytes to copy. A directory is kept as
                    // a path reference: copying a folder tree into the media store
                    // is not what "copy a folder" means, and Data(contentsOf:) on
                    // one throws EISDIR, which is what used to sink the whole clip.
                    if candidate.isRegularFile, candidate.byteSize <= thresholdBytes {
                        let stored = try database.media.storeFile(at: fileURL)
                        mediaFilename = stored.mediaFilename
                        storedByteSize = stored.byteSize

                        // Additive: when the copied file is an image, give this
                        // file clip the same preview + OCR eligibility as a real
                        // image clip. Best-effort; a decode failure just leaves
                        // the clip as a plain file reference, never fails capture.
                        if Self.isImageFile(fileURL) {
                            let hash = Self.contentHash(fromStoredFilename: stored.mediaFilename,
                                                        extension: fileURL.pathExtension)
                            if let thumb = database.media.imageThumbnail(forFileAt: fileURL, hash: hash) {
                                thumbFilename = thumb.thumbFilename
                                pixelWidth = thumb.pixelWidth
                                pixelHeight = thumb.pixelHeight
                            }
                        }
                    }

                    var clip = Clip(
                        id: nil,
                        contentText: displayName,
                        contentRTF: nil,
                        contentHTML: nil,
                        typeIdentifier: "public.file-url",
                        sourceAppBundleID: bundleID,
                        sourceAppName: appName,
                        createdAt: Date(),
                        contentKind: .file,
                        mediaFilename: mediaFilename,
                        thumbFilename: thumbFilename,
                        pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight,
                        byteSize: storedByteSize
                    )
                    clip.filePath = fileURL.path

                    try database.saveCapturedFileClip(&clip, cap: cap)
                    capturedAny = true
                } catch {
                    failures += 1
                    // The file name is client data (it can carry a name or account
                    // number), so it is never logged.
                    ClippyLog.error("Failed to save a file clip: \(error)", category: ClippyLog.capture)
                }
            }
            // A copy where every item failed is worth one summary line: the
            // per-item errors above are easy to lose in a busy log, and this is
            // the shape that used to happen 1200+ times with nobody noticing.
            if failures > 0, !capturedAny {
                ClippyLog.error("File copy produced no clips: all \(failures) item(s) failed",
                                category: ClippyLog.capture)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if capturedAny { self.appendTracker.forget(); self.recordSuccess(); self.playCaptureSound() }
                if failures > 0 {
                    for _ in 0..<failures { self.recordFailureOnMain("Could not save a copied file") }
                    if !capturedAny { self.retryFileCapture(changeCount: changeCount) }
                }
            }
        }
        // True whenever viable file URLs were on the pasteboard, so the caller
        // does not fall through to text/image capture and create a spurious
        // filename text clip; a total failure is retried by `retryFileCapture`.
        return true
    }

    // MARK: Retry

    /// Lets `tick()` look at `changeCount` again after a file copy where every
    /// item failed, at most `maxFileRetries` times.
    private func retryFileCapture(changeCount: Int) {
        let attempts = fileRetryCounts[changeCount, default: 0]
        guard attempts < Self.maxFileRetries else { return }
        fileRetryCounts = [changeCount: attempts + 1]
        forcedRetryChangeCount = changeCount
    }

    // MARK: Image capture

    /// PNG bytes for the pasteboard image, and whether they came straight from
    /// a PNG flavor. Other encodings (JPEG, HEIC, GIF, TIFF) are decoded by
    /// ImageIO directly from their encoded bytes, with no NSImage/TIFF round
    /// trip (OCR-06); a PDF-only pasteboard is rendered from its first page.
    /// The originals are preserved as flavors and restored on paste.
    static func imagePayload(from pasteboard: NSPasteboard) -> (png: Data, isNativePNG: Bool)? {
        if let png = pasteboard.data(forType: .png) { return (png, true) }
        let maxEncoded = AppSettings.shared.maxImageSizeMB * 4_194_304
        for type in [jpegType, heicType, gifType, .tiff] {
            if let data = pasteboard.data(forType: type), data.count <= maxEncoded,
               let png = MediaStore.pngData(fromEncoded: data) {
                return (png, false)
            }
        }
        if let pdf = pasteboard.data(forType: .pdf), pdf.count <= maxEncoded,
           let png = MediaStore.pngData(fromPDF: pdf) {
            return (png, false)
        }
        return nil
    }

    /// Images are captured only when the pasteboard carries no text: a copied
    /// picture, a screenshot, not a rich-text snippet that happens to embed one.
    /// Returns true when the image was handled: captured, or rejected on purpose
    /// for exceeding the size cap. False means no image data was on the
    /// pasteboard, which the caller treats as "not filled in yet".
    @discardableResult
    private func captureImageIfPresent(from source: SourceAppTracker.App?) -> Bool {
        guard AppSettings.shared.captureImages,
              let payload = Self.imagePayload(from: pasteboard)
        else { return false }
        let pngData = payload.png
        guard pngData.count <= AppSettings.shared.maxImageSizeMB * 1_048_576 else { return true }

        // Decode the pasteboard to PNG on the main thread (AppKit image path),
        // then dispatch the file write + DB insert off-main so a screenshot
        // capture cannot block the UI.
        let flavors = flavorSnapshot(excluding: payload.isNativePNG ? ["public.png"] : [])
        let bundleID = source?.bundleID
        let appName = source?.name
        let createdAt = Date()
        let cap = AppSettings.shared.maxHistoryItems
        let database = self.database
        let flavorStore = self.flavorStore

        captureQueue.async { [weak self] in
            do {
                let stored = try database.media.store(pngData: pngData)
                if let flavors {
                    let key = Clip.contentKey(kind: .image, text: "", mediaFilename: stored.mediaFilename, filePath: nil)
                    do { try flavorStore.write(flavors, key: key) } catch {
                        ClippyLog.warning("Could not preserve pasteboard flavors: \(error)", category: ClippyLog.capture)
                    }
                }
                var clip = Clip(
                    id: nil,
                    contentText: "",
                    contentRTF: nil,
                    contentHTML: nil,
                    typeIdentifier: "public.png",
                    sourceAppBundleID: bundleID,
                    sourceAppName: appName,
                    createdAt: createdAt,
                    contentKind: .image,
                    mediaFilename: stored.mediaFilename,
                    thumbFilename: stored.thumbFilename,
                    pixelWidth: stored.pixelWidth,
                    pixelHeight: stored.pixelHeight,
                    byteSize: stored.byteSize
                )
                try database.saveCapturedImageClip(&clip, cap: cap)
                let capturedID = clip.id
                DispatchQueue.main.async { [weak self] in
                    self?.appendTracker.forget()
                    self?.recordSuccess()
                    self?.playCaptureSound()
                    // Lets the OCR indexer react (a bumped duplicate is already indexed).
                    NotificationCenter.default.post(
                        name: .clippyClipCaptured, object: nil,
                        userInfo: capturedID.map { ["clipID": $0] })
                }
            } catch {
                ClippyLog.error("Failed to save image clip: \(error)", category: ClippyLog.capture)
                self?.recordFailure("Could not save an image clip")
            }
        }
        return true
    }
}
