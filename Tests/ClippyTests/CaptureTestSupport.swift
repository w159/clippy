import PDFKit
import XCTest

@testable import Clippy

/// Shared scratch-pasteboard scaffolding for the capture and paste tests.
/// Capture and paste fidelity (CAP-01...08, FEAT-01) against scratch
/// NSPasteboard instances: never the general pasteboard, the real DB, or the
/// network.
@MainActor
class CaptureTestCase: XCTestCase {

    var scratchDefaults: UserDefaults!
    var savedDefaults: UserDefaults!
    var savedMoveToTop = false

    override func setUp() {
        super.setUp()
        savedDefaults = CapturePreferences.defaults
        let suite = "ClippyCaptureTests-\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: suite)
        CapturePreferences.defaults = scratchDefaults
        // The developer's own stored settings must not decide these tests.
        let settings = AppSettings.shared
        savedMoveToTop = settings.movePastedItemToTop
        let saved = (settings.captureFiles, settings.captureImages, settings.ignoredBundleIDs, settings.maxFileSizeMB)
        settings.movePastedItemToTop = false
        settings.captureFiles = true
        settings.captureImages = true
        settings.ignoredBundleIDs = []
        settings.maxFileSizeMB = 10
        addTeardownBlock { [scratchDefaults, savedDefaults, savedMoveToTop] in
            settings.captureFiles = saved.0
            settings.captureImages = saved.1
            settings.ignoredBundleIDs = saved.2
            settings.maxFileSizeMB = saved.3
            scratchDefaults?.removePersistentDomain(forName: suite)
            CapturePreferences.defaults = savedDefaults ?? .standard
            AppSettings.shared.movePastedItemToTop = savedMoveToTop
            SensitiveFlagStore.register(nil)
        }
    }

    // MARK: Helpers

    func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("ClippyCap-\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    func makeMonitor(_ db: ClipDatabase, _ pb: NSPasteboard) -> ClipboardMonitor {
        ClipboardMonitor(database: db, pasteboard: pb)
    }

    func waitFor(_ timeout: TimeInterval = 5, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return try condition()
    }

    func clip(_ db: ClipDatabase, text: String, timeout: TimeInterval = 5) throws -> Clip? {
        _ = try waitFor(timeout) { try db.allClips().contains { $0.contentText == text } }
        return try db.allClips().first { $0.contentText == text }
    }

    func hasClip(_ db: ClipDatabase, text: String, timeout: TimeInterval = 0.6) throws -> Bool {
        try clip(db, text: text, timeout: timeout) != nil
    }

    func write(_ pb: NSPasteboard, _ text: String) {
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func pngData(width: Int = 8, height: Int = 6, alpha: Bool = false) -> Data {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }
}
