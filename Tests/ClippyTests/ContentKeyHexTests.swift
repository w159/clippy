import CryptoKit
import XCTest
@testable import Clippy

final class ContentKeyHexTests: XCTestCase {
    /// The original encoder, kept as the reference the fast one must match.
    private func reference(_ prefix: String, _ string: String) -> String {
        prefix + SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testTextKeyMatchesReference() {
        let long = String(repeating: "clipboard line \u{1F600}\n", count: 5000)
        for text in ["", "hello world", "caf\u{E9} \u{1F600}\u{1F468}\u{200D}\u{1F469}", long] {
            XCTAssertEqual(makeTextClip(text).contentKey, reference("t-", text), "text: \(text.prefix(20))")
        }
    }

    func testFilePathKeyMatchesReference() {
        let path = "/Users/me/Documents/report \u{1F4C4}.pdf"
        XCTAssertEqual(
            Clip.contentKey(kind: .file, text: "ignored", mediaFilename: nil, filePath: path),
            reference("p-", path)
        )
        XCTAssertEqual(
            Clip.contentKey(kind: .image, text: "fallback", mediaFilename: nil, filePath: nil),
            reference("p-", "fallback")
        )
    }

    func testMediaFilenameKeyIsUnchanged() {
        XCTAssertEqual(
            Clip.contentKey(kind: .image, text: "", mediaFilename: "abc.png", filePath: nil),
            "m-abc.png"
        )
    }
}
