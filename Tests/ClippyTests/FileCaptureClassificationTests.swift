import XCTest
@testable import Clippy

/// Guards the folder-copy regression: `attributesOfItem[.size]` reports a
/// non-zero size for a directory, so the old viability filter passed folders
/// through to `MediaStore.storeFile`, where `Data(contentsOf:)` throws EISDIR.
/// That failure produced no clip, no sound, and 1273 log lines in the field.
final class FileCaptureClassificationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-classify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in
            if let root { try? FileManager.default.removeItem(at: root) }
        }
    }

    func testDirectoryIsViableButNotAByteCopy() throws {
        let folder = root.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let candidate = try XCTUnwrap(
            ClipboardMonitor.classify(folder),
            "a folder must still become a clip - it is a path reference"
        )
        XCTAssertFalse(candidate.isRegularFile, "a folder must never reach storeFile")
        XCTAssertEqual(candidate.byteSize, 0)
    }

    /// The precise mechanism of the original bug, asserted directly: the old
    /// filter's predicate is true for a directory, and the read it gated fails.
    func testDirectoryPassesTheOldSizePredicateAndFailsTheRead() throws {
        let folder = root.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        let reportedSize = (attributes[.size] as? Int) ?? 0
        XCTAssertGreaterThan(reportedSize, 0, "this is why the old filter let folders through")
        XCTAssertThrowsError(try Data(contentsOf: folder, options: .mappedIfSafe))
    }

    func testRegularFileCarriesItsSize() throws {
        let file = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)

        let candidate = try XCTUnwrap(ClipboardMonitor.classify(file))
        XCTAssertTrue(candidate.isRegularFile)
        XCTAssertEqual(candidate.byteSize, 5)
    }

    func testEmptyFileIsRejected() throws {
        let file = root.appendingPathComponent("empty.txt")
        try Data().write(to: file)
        XCTAssertNil(ClipboardMonitor.classify(file))
    }

    func testMissingPathIsRejected() {
        XCTAssertNil(ClipboardMonitor.classify(root.appendingPathComponent("nope.txt")))
    }
}
