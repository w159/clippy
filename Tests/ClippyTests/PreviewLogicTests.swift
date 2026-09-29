import XCTest
@testable import Clippy

@MainActor
final class PreviewLogicTests: XCTestCase {
    private func item(_ text: String) -> ClipPreviewItem {
        ClipPreviewProvider.item(for: makeTextClip(text), isSensitive: { _ in false })
    }

    func testSensitiveClipNeverCarriesContent() {
        let result = ClipPreviewProvider.item(for: makeTextClip("hunter2"), isSensitive: { _ in true })
        XCTAssertEqual(result, .masked)
    }

    func testKindSelection() {
        if case .color = item("#FF8800") {} else { XCTFail("color") }
        if case .link(let url) = item("https://example.com/a") { XCTAssertEqual(url.host, "example.com") } else { XCTFail("link") }
        if case .json = item("{\"a\": 1, \"b\": [1,2]}") {} else { XCTFail("json") }
        if case .csv = item("a,b,c\n1,2,3\n4,5,6\n") {} else { XCTFail("csv") }
        if case .text = item("just some plain words here") {} else { XCTFail("text") }
        if case .code = item("import Foundation\nfunc go() {\n    guard let x = y else { return }\n}\n") {} else { XCTFail("code") }
    }

    func testLinkWithSpacesIsNotALink() {
        XCTAssertNil(ClipPreviewProvider.singleLink("https://a.com and more"))
    }

    func testLineCapping() {
        let text = (1...100).map(String.init).joined(separator: "\n")
        let capped = ClipPreviewProvider.capLines(text, limit: 10)
        XCTAssertEqual(capped.text.split(separator: "\n").count, 10)
        XCTAssertEqual(capped.dropped, 90)
        XCTAssertEqual(ClipPreviewProvider.capLines("a\nb", limit: 10).dropped, 0)
    }

    func testCodeItemIsCapped() {
        let body = (0..<80).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        guard case .code(let text, _, let dropped) = ClipPreviewProvider.textItem("import Foundation\n" + body, lineLimit: 20) else {
            return XCTFail("expected code")
        }
        XCTAssertEqual(text.split(separator: "\n").count, 20)
        XCTAssertEqual(dropped, 61)
    }

    func testURLSanitizer() {
        XCTAssertNotNil(LinkURLSanitizer.sanitized(URL(string: "https://example.com/path?q=swift")!))
        XCTAssertNil(LinkURLSanitizer.sanitized(URL(string: "https://user:pw@example.com/")!))
        XCTAssertNil(LinkURLSanitizer.sanitized(URL(string: "https://user@example.com/")!))
        XCTAssertNil(LinkURLSanitizer.sanitized(URL(string: "https://example.com/?access_token=abc")!))
        XCTAssertNil(LinkURLSanitizer.sanitized(URL(string: "https://example.com/?X-Amz-Signature=abc")!))
        XCTAssertNil(LinkURLSanitizer.sanitized(URL(string: "https://example.com/?my_token=1")!))
        XCTAssertNil(LinkURLSanitizer.sanitized(URL(string: "ftp://example.com/")!))
        XCTAssertNil(LinkURLSanitizer.sanitized(URL(string: "file:///etc/hosts")!))
        XCTAssertNil(LinkURLSanitizer.sanitized(URL(string: "https://example.com/#frag")!)?.fragment)
    }

    func testHostPolicy() {
        XCTAssertTrue(LinkPreviewPreferences.isHostAllowed("a.example.com", allow: [], deny: []))
        XCTAssertFalse(LinkPreviewPreferences.isHostAllowed("a.example.com", allow: [], deny: ["example.com"]))
        XCTAssertFalse(LinkPreviewPreferences.isHostAllowed("other.org", allow: ["example.com"], deny: []))
        XCTAssertFalse(LinkPreviewPreferences.isHostAllowed("example.com", allow: ["example.com"], deny: ["example.com"]))
        XCTAssertEqual(LinkPreviewPreferences.normalize([" A.com", "a.com", ""]), ["a.com"])
    }

    func testColumnWidthClampAndVisibility() {
        XCTAssertEqual(PreviewColumnPreferences.clamp(10), PreviewColumnPreferences.minWidth)
        XCTAssertEqual(PreviewColumnPreferences.clamp(9000), PreviewColumnPreferences.maxWidth)
        XCTAssertEqual(PreviewColumnPreferences.clamp(.nan), PreviewColumnPreferences.defaultWidth)
        XCTAssertTrue(PreviewColumnPreferences.isVisible(panelWidth: 1100, enabled: true))
        XCTAssertFalse(PreviewColumnPreferences.isVisible(panelWidth: 1099, enabled: true))
        XCTAssertFalse(PreviewColumnPreferences.isVisible(panelWidth: 2000, enabled: false))
    }

    func testColumnWidthPersistence() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PreviewLogicTests.\(UUID().uuidString)"))
        XCTAssertEqual(PreviewColumnPreferences.width(defaults), PreviewColumnPreferences.defaultWidth)
        PreviewColumnPreferences.setWidth(9999, defaults: defaults)
        XCTAssertEqual(PreviewColumnPreferences.width(defaults), PreviewColumnPreferences.maxWidth)
    }

    func testTempFilesArePrivateAndCleanedUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qltest-\(UUID().uuidString)")
        let files = QuickLookTempFiles(directory: dir)
        let copy = try files.materialize(data: Data("x".utf8), name: "../evil/name.txt")
        XCTAssertEqual(copy.deletingLastPathComponent().path, dir.path)
        let perms = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        files.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}

// MARK: - Link cache and service

private struct FakeFetcher: LinkMetadataFetching {
    let counter: Counter
    final class Counter { var calls = 0 }
    func fetch(_ url: URL, timeout: TimeInterval) async throws -> LinkPreviewMetadata {
        counter.calls += 1
        return LinkPreviewMetadata(url: url.absoluteString, title: "T", host: url.host ?? "", iconPNG: nil, fetchedAt: Date(timeIntervalSince1970: 1000))
    }
}

@MainActor
final class LinkPreviewCacheTests: XCTestCase {
    private var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("lpc-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func meta(_ name: String, at seconds: TimeInterval) -> LinkPreviewMetadata {
        LinkPreviewMetadata(url: "https://\(name)", title: name, host: name, iconPNG: Data(count: 400), fetchedAt: Date(timeIntervalSince1970: seconds))
    }

    func testOldestEvictedWhenOverCap() {
        let cache = LinkPreviewCache(directory: dir, maxBytes: 1500, maxAge: 1_000_000, now: { Date(timeIntervalSince1970: 100) })
        for (index, name) in ["a.com", "b.com", "c.com", "d.com"].enumerated() {
            cache.store(meta(name, at: Double(index)), for: URL(string: "https://\(name)")!)
        }
        XCTAssertLessThanOrEqual(cache.totalBytes, 1500)
        XCTAssertNil(cache.entry(for: URL(string: "https://a.com")!))
        XCTAssertNotNil(cache.entry(for: URL(string: "https://d.com")!))
    }

    func testExpiryUsesInjectedClock() {
        var clock = Date(timeIntervalSince1970: 100)
        let cache = LinkPreviewCache(directory: dir, maxBytes: 10_000, maxAge: 60, now: { clock })
        let url = URL(string: "https://a.com")!
        cache.store(meta("a.com", at: 100), for: url)
        XCTAssertNotNil(cache.entry(for: url))
        clock = Date(timeIntervalSince1970: 161)
        XCTAssertNil(cache.entry(for: url))
        XCTAssertEqual(cache.count, 0)
    }

    func testServiceGates() async {
        let counter = FakeFetcher.Counter()
        let cache = LinkPreviewCache(directory: dir, maxBytes: 10_000, maxAge: 1_000_000, now: { Date(timeIntervalSince1970: 1001) })
        var enabled = false
        let service = LinkPreviewService(fetcher: FakeFetcher(counter: counter), cache: cache, isEnabled: { enabled }, allow: { [] }, deny: { ["blocked.com"] })
        let url = URL(string: "https://example.com/a")!
        let disabled = await service.metadata(for: url, sensitive: false)
        XCTAssertNil(disabled)
        enabled = true
        let sensitive = await service.metadata(for: url, sensitive: true)
        XCTAssertNil(sensitive)
        let creds = await service.metadata(for: URL(string: "https://u:p@example.com/")!, sensitive: false)
        XCTAssertNil(creds)
        let tokenURL = await service.metadata(for: URL(string: "https://example.com/?token=x")!, sensitive: false)
        XCTAssertNil(tokenURL)
        let denied = await service.metadata(for: URL(string: "https://blocked.com/")!, sensitive: false)
        XCTAssertNil(denied)
        XCTAssertEqual(counter.calls, 0)
        let first = await service.metadata(for: url, sensitive: false)
        let second = await service.metadata(for: url, sensitive: false)
        XCTAssertEqual(first?.title, "T")
        XCTAssertEqual(second?.title, "T")
        XCTAssertEqual(counter.calls, 1)
    }
}

// MARK: - Smart collection selection

private final class FakeSource: SmartCollectionSource {
    var items: [SmartCollection]
    init(_ items: [SmartCollection]) { self.items = items }
    func collections() throws -> [SmartCollection] { items }
    func count(matching rule: SmartCollectionRule, limit: Int) throws -> Int { min(limit, rule.newerThanDays ?? 0) }
    func clips(matching rule: SmartCollectionRule, limit: Int) throws -> [Clip] { [makeTextClip("x")] }
    func delete(id: Int64) throws { items.removeAll { $0.id == id } }
}

@MainActor
final class SmartCollectionSelectionTests: XCTestCase {
    private func collection(_ id: Int64, days: Int) -> SmartCollection {
        var rule = SmartCollectionRule()
        rule.newerThanDays = days
        return SmartCollection(id: id, name: "C\(id)", rule: rule, sortOrder: Int(id))
    }

    func testSelectToggleAndActiveRule() {
        let model = SmartCollectionSelection(source: FakeSource([collection(1, days: 5), collection(2, days: 5000)]))
        model.reload()
        XCTAssertNil(model.activeRule)
        model.toggle(1)
        XCTAssertEqual(model.activeRule?.newerThanDays, 5)
        XCTAssertEqual(model.selectedClips().count, 1)
        model.toggle(1)
        XCTAssertNil(model.selectedID)
    }

    func testCountsAndCap() {
        let model = SmartCollectionSelection(source: FakeSource([collection(1, days: 5), collection(2, days: 5000)]))
        model.reload()
        XCTAssertEqual(model.countLabel(for: 1), "5")
        XCTAssertEqual(model.countLabel(for: 2), "999+")
    }

    func testDeleteClearsSelection() {
        let model = SmartCollectionSelection(source: FakeSource([collection(1, days: 5), collection(2, days: 3)]))
        model.reload()
        model.toggle(2)
        model.delete(2)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.collections.map(\.id), [1])
    }
}
