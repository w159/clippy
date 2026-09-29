import XCTest
@testable import Clippy

final class StatusItemMenuModelTests: XCTestCase {
    private func text(_ value: String) -> Clip {
        Clip(contentText: value, typeIdentifier: "public.utf8-plain-text", createdAt: Date())
    }

    func testTakesNewestLimitInOrder() {
        let clips = (0..<15).map { text("clip \($0)") }
        let rows = StatusItemMenuModel.rows(clips: clips, limit: 10) { _ in false }
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.first?.title, "clip 0")
        XCTAssertEqual(rows.last?.clipIndex, 9)
    }

    func testSensitiveClipsAreOmittedWithoutConsumingSlots() {
        let clips = [text("secret"), text("a"), text("secret"), text("b")]
        let rows = StatusItemMenuModel.rows(clips: clips, limit: 2) { $0.contentText == "secret" }
        XCTAssertEqual(rows.map(\.title), ["a", "b"])
        XCTAssertFalse(rows.contains { $0.title.contains("secret") })
    }

    func testTitleTruncatesAndCollapsesWhitespace() {
        let long = String(repeating: "x", count: 200)
        let title = StatusItemMenuModel.title(for: text(long))
        XCTAssertEqual(title.count, StatusItemMenuModel.maxTitleLength)
        XCTAssertTrue(title.hasSuffix("\u{2026}"))
        XCTAssertEqual(StatusItemMenuModel.title(for: text("  a \n\n b\t c ")), "a b c")
        XCTAssertEqual(StatusItemMenuModel.title(for: text("   ")), "Empty text")
    }

    func testImageAndFileTitles() {
        var image = text("")
        image.contentKind = .image
        image.pixelWidth = 640
        image.pixelHeight = 480
        XCTAssertEqual(StatusItemMenuModel.title(for: image), "Image 640\u{00D7}480")
        var file = text("")
        file.contentKind = .file
        file.filePath = "/tmp/report.pdf"
        XCTAssertEqual(StatusItemMenuModel.title(for: file), "report.pdf")
    }

    func testClickBehaviorDefaultsAndPersists() {
        let previous = StatusItemPreferences.defaults
        defer { StatusItemPreferences.defaults = previous }
        let suiteName = "status.tests.\(UUID().uuidString)"
        StatusItemPreferences.defaults = UserDefaults(suiteName: suiteName)!
        defer { StatusItemPreferences.defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(StatusItemPreferences.clickBehavior, .panelOnLeftClick)
        StatusItemPreferences.clickBehavior = .menuOnAnyClick
        XCTAssertEqual(StatusItemPreferences.clickBehavior, .menuOnAnyClick)
    }
}
