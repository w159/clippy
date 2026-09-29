import XCTest
@testable import Clippy

final class EmbeddingCacheTests: XCTestCase {
    private func makeCache(
        _ url: URL?, revision: Int = 1, capacity: Int = 100, maxFileBytes: Int = 1 << 20
    ) -> EmbeddingCache {
        EmbeddingCache(
            fileURL: url, revision: revision, capacity: capacity, maxFileBytes: maxFileBytes,
            saveDelay: 60)
    }

    private func value(_ seed: Float, language: String = "en", dim: Int = 8) -> LanguageVector {
        LanguageVector(vector: (0..<dim).map { seed + Float($0) }, language: language)
    }

    func testRoundTripAcrossInstances() throws {
        let url = makeIntelligenceTempDirectory(self).appendingPathComponent("e.bin")
        let first = makeCache(url)
        first.store(id: 1, textHash: 11, value: value(1))
        first.store(id: 2, textHash: 22, value: value(2, language: "es", dim: 4))
        first.flush()

        let second = makeCache(url)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.lookup(id: 1, textHash: 11), value(1))
        XCTAssertEqual(second.lookup(id: 2, textHash: 22), value(2, language: "es", dim: 4))
    }

    func testHashMismatchIsAMiss() {
        let cache = makeCache(nil)
        cache.store(id: 1, textHash: 11, value: value(1))
        XCTAssertNil(cache.lookup(id: 1, textHash: 12))
        XCTAssertNil(cache.lookup(id: 9, textHash: 11))
    }

    func testCorruptFilesLoadAsEmpty() throws {
        let dir = makeIntelligenceTempDirectory(self)
        let url = dir.appendingPathComponent("e.bin")
        let good = makeCache(url)
        good.store(id: 1, textHash: 1, value: value(1))
        good.flush()
        let original = try Data(contentsOf: url)

        var cases: [String: Data] = [
            "garbage": Data((0..<200).map { UInt8($0 % 251) }),
            "empty": Data(),
            "truncated": original.prefix(original.count - 5),
            "trailing": original + Data([1, 2, 3]),
        ]
        var badMagic = original
        badMagic[0] = 0x58
        cases["magic"] = badMagic
        var hugeCount = original
        hugeCount.replaceSubrange(16..<20, with: [0xff, 0xff, 0xff, 0x7f])
        cases["count"] = hugeCount

        for (name, data) in cases {
            try data.write(to: url)
            XCTAssertEqual(makeCache(url).count, 0, "case \(name)")
        }
        // A corrupt file is replaced cleanly by the next save.
        try cases["garbage"]!.write(to: url)
        let recovered = makeCache(url)
        recovered.store(id: 5, textHash: 5, value: value(5))
        recovered.flush()
        XCTAssertNotNil(makeCache(url).lookup(id: 5, textHash: 5))
    }

    func testRevisionChangeInvalidatesFile() {
        let url = makeIntelligenceTempDirectory(self).appendingPathComponent("e.bin")
        let old = makeCache(url, revision: 1)
        old.store(id: 1, textHash: 1, value: value(1))
        old.flush()
        XCTAssertEqual(makeCache(url, revision: 2).count, 0)
        XCTAssertEqual(makeCache(url, revision: 1).count, 1)
    }

    func testCapacityEvictsLeastRecentlyUsed() {
        let cache = makeCache(nil, capacity: 10)
        for id in 1...10 { cache.store(id: Int64(id), textHash: UInt64(id), value: value(Float(id))) }
        // Touch id 1 so it is the most recently used before the overflowing insert.
        XCTAssertNotNil(cache.lookup(id: 1, textHash: 1))
        cache.store(id: 11, textHash: 11, value: value(11))
        XCTAssertLessThanOrEqual(cache.count, 10)
        XCTAssertNotNil(cache.lookup(id: 1, textHash: 1), "recently used entry survives")
        XCTAssertNotNil(cache.lookup(id: 11, textHash: 11))
        XCTAssertNil(cache.lookup(id: 2, textHash: 2), "oldest entry is evicted")
    }

    func testFileSizeCapDropsOldestRecords() throws {
        let url = makeIntelligenceTempDirectory(self).appendingPathComponent("e.bin")
        // Each record: 8+8+1+2+4+32 = 55 bytes; header 20. Cap fits 3 records.
        let cache = makeCache(url, capacity: 100, maxFileBytes: 20 + 55 * 3)
        for id in 1...6 { cache.store(id: Int64(id), textHash: UInt64(id), value: value(Float(id))) }
        cache.flush()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertLessThanOrEqual(size ?? .max, 20 + 55 * 3)
        let reloaded = makeCache(url, capacity: 100, maxFileBytes: 20 + 55 * 3)
        XCTAssertEqual(reloaded.count, 3)
        XCTAssertNotNil(reloaded.lookup(id: 6, textHash: 6), "newest records are kept")
        XCTAssertNil(reloaded.lookup(id: 1, textHash: 1))
    }

    func testClearDeletesFileAndMemory() {
        let url = makeIntelligenceTempDirectory(self).appendingPathComponent("e.bin")
        let cache = makeCache(url)
        cache.store(id: 1, textHash: 1, value: value(1))
        cache.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(makeCache(url).count, 0)
    }

    func testStableHashIsDeterministic() {
        XCTAssertEqual(StableHash.fnv1a("hello"), 0xa430_d846_80aa_bd0b)
        XCTAssertNotEqual(StableHash.fnv1a("hello"), StableHash.fnv1a("hellp"))
    }

    func testEnginePersistsEmbeddingsAcrossInstances() {
        let url = makeIntelligenceTempDirectory(self).appendingPathComponent("e.bin")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clips = [makeIntelClip(1, "lisbon itinerary flights hotel", now: now)]
        let context = ScreenContext(bundleID: "com.other", text: "lisbon flights", capturedAt: now)

        let embedder1 = LanguageStubEmbedder()
        let cache1 = makeCache(url)
        let engine1 = SuggestionEngine(embedder: embedder1, cache: cache1)
        _ = engine1.rank(context: context, clips: clips, limit: 3, now: now)
        cache1.flush()

        let embedder2 = LanguageStubEmbedder()
        let engine2 = SuggestionEngine(embedder: embedder2, cache: makeCache(url))
        _ = engine2.rank(context: context, clips: clips, limit: 3, now: now)
        // Only the query is embedded on the second launch; the clip comes from disk.
        XCTAssertEqual(embedder2.calls, 1)
        XCTAssertEqual(embedder1.calls, 2)
    }
}
