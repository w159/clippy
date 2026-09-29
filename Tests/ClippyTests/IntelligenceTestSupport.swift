import Foundation
import XCTest
@testable import Clippy

/// Deterministic bag-of-words embedder that assigns a language from marker words:
/// "hola"/"gracias" -> "es", "zzz" -> unsupported (no vector), otherwise "en".
/// Counts calls so tests can prove cache hits.
final class LanguageStubEmbedder: TextEmbedder {
    var revision: Int
    private(set) var calls = 0
    private let lock = NSLock()

    init(revision: Int = 1) { self.revision = revision }

    func vector(for text: String) -> [Float]? { embedding(for: text)?.vector }

    func embedding(for text: String) -> LanguageVector? {
        lock.lock(); calls += 1; lock.unlock()
        let lower = text.lowercased()
        if lower.contains("zzz") { return nil }
        let language = (lower.contains("hola") || lower.contains("gracias")) ? "es" : "en"
        var vector = [Float](repeating: 0, count: 64)
        var any = false
        for word in SuggestionEngine.words(text) {
            var hash: UInt64 = 5381
            for byte in word.utf8 { hash = hash &* 33 &+ UInt64(byte) }
            vector[Int(hash % 64)] += 1
            any = true
        }
        return any ? LanguageVector(vector: vector, language: language) : nil
    }
}

/// Fresh temporary directory removed at the end of the test.
func makeIntelligenceTempDirectory(_ testCase: XCTestCase) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clippy-intel-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

func makeIntelClip(
    _ id: Int64, _ text: String, age: TimeInterval = 60, now: Date,
    bundle: String = "com.example.test"
) -> Clip {
    var clip = makeTextClip(text, createdAt: now.addingTimeInterval(-age))
    clip.id = id
    clip.sourceAppBundleID = bundle
    clip.sourceAppName = "TestApp"
    return clip
}
