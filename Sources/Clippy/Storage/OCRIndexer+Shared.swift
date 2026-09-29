import Foundation

extension OCRIndexer {
    private nonisolated(unsafe) static var sharedInstance: OCRIndexer?
    private static let sharedLock = NSLock()

    /// The app-wide indexer over `ClipDatabase.shared`, created on first use.
    static var shared: OCRIndexer {
        sharedLock.withLock {
            if let sharedInstance { return sharedInstance }
            let created = OCRIndexer(database: .shared)
            sharedInstance = created
            return created
        }
    }

    /// Call once at launch: starts observing captures and runs a first pass
    /// (a no-op while indexing is disabled).
    static func startShared() { shared.start() }

    /// Single entry point for the Settings toggle. Turning indexing on kicks a
    /// pass; turning it off cancels the running pass and, when `deleteText` is
    /// true, erases all stored recognised text.
    static func setIndexingEnabled(_ enabled: Bool, deleteText: Bool = false) {
        OCRIndexPreferences.isEnabled = enabled
        if enabled {
            shared.start()
            shared.kick()
        } else {
            shared.stop()
            if deleteText { try? ClipDatabase.shared.clearAllOCRText() }
        }
    }
}
