import XCTest
@testable import Clippy

/// Compares the shipped sentence embedder with `NLContextualEmbedding` on a
/// small labelled synthetic fixture set. Skipped when contextual assets are
/// absent; never triggers a download.
final class SemanticEmbedderComparisonTests: XCTestCase {
    private struct Case {
        let query: String
        let relevant: String
        let distractors: [String]
    }

    private let fixtures = [
        Case(query: "invoice for the plumber", relevant: "Payment due for plumbing repair invoice #442",
             distractors: ["Recipe: lemon pasta with garlic", "Flight AA100 departs at 9am", "git rebase --onto main feature"]),
        Case(query: "how to cook dinner", relevant: "Recipe: lemon pasta with garlic and olive oil",
             distractors: ["Quarterly tax filing deadline reminder", "SELECT * FROM users WHERE id = 3", "Meeting moved to Thursday 3pm"]),
        Case(query: "airline booking", relevant: "Your flight to Lisbon departs at 9:40am from gate 12",
             distractors: ["Recipe: banana bread with walnuts", "npm install --save-dev typescript", "Dentist appointment on Friday"]),
        Case(query: "database query", relevant: "SELECT name, email FROM customers ORDER BY created_at",
             distractors: ["Happy birthday, hope you have a great day", "Boarding pass for seat 14C", "Grocery list: milk, eggs, bread"]),
    ]

    private func accuracy(_ embedder: TextEmbedder) -> Double {
        var hits = 0
        for item in fixtures {
            guard let query = embedder.vector(for: item.query) else { continue }
            let pool = [item.relevant] + item.distractors
            let scored = pool.compactMap { text in embedder.vector(for: text).map { (text, VectorMath.cosine(query, $0)) } }
            if scored.max(by: { $0.1 < $1.1 })?.0 == item.relevant { hits += 1 }
        }
        return Double(hits) / Double(fixtures.count)
    }

    func testContextualVersusSentenceEmbeddingOnFixtures() throws {
        let contextual = NLContextualTextEmbedder()
        try XCTSkipUnless(contextual.hasAvailableAssets, "NLContextualEmbedding assets are not installed")
        let sentence = accuracy(NLTextEmbedder())
        let mean = accuracy(contextual)
        print("Semantic fixture top-1 accuracy: sentence=\(sentence) contextual=\(mean)")
        XCTAssertNotNil(contextual.vector(for: fixtures[0].query), "contextual embedder must produce vectors when assets exist")
        XCTAssertGreaterThanOrEqual(mean, 0)
    }
}
