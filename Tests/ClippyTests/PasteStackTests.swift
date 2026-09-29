import XCTest

@testable import Clippy

/// FEAT-06: paste stack ordering, FIFO/LIFO, reorder, sensitive refusal.
@MainActor
final class PasteStackTests: XCTestCase {
    private func clip(_ text: String, id: Int64? = nil) -> Clip {
        Clip(id: id ?? Int64(abs(text.hashValue % 100_000) + 1), contentText: text, contentRTF: nil, contentHTML: nil,
             typeIdentifier: "public.utf8-plain-text", sourceAppBundleID: nil, sourceAppName: nil, createdAt: Date())
    }

    private func stack(_ order: PasteStackOrder, secret: String = "SECRET") -> PasteStack {
        PasteStack(order: order, isSensitive: { $0.contentText == secret })
    }

    private func texts(_ stack: PasteStack) -> [String] { stack.items.map(\.clip.contentText) }

    func testFIFOPopsOldestFirst() {
        let stack = stack(.fifo)
        ["a", "b", "c"].forEach { stack.add(clip($0)) }
        XCTAssertEqual(stack.upcoming?.clip.contentText, "a")
        XCTAssertEqual([stack.next(), stack.next(), stack.next()].map { $0?.clip.contentText }, ["a", "b", "c"])
        XCTAssertNil(stack.next())
    }

    func testLIFOPopsNewestFirst() {
        let stack = stack(.lifo)
        ["a", "b", "c"].forEach { stack.add(clip($0)) }
        XCTAssertEqual(stack.upcomingIndex, 2)
        XCTAssertEqual([stack.next(), stack.next(), stack.next()].map { $0?.clip.contentText }, ["c", "b", "a"])
    }

    func testReorderRemoveAndClear() {
        let stack = stack(.fifo)
        ["a", "b", "c"].forEach { stack.add(clip($0)) }
        stack.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(texts(stack), ["c", "a", "b"])
        XCTAssertTrue(stack.remove(id: stack.items[1].id))
        XCTAssertEqual(texts(stack), ["c", "b"])
        XCTAssertFalse(stack.remove(id: UUID()))
        stack.remove(atOffsets: IndexSet(integer: 0))
        XCTAssertEqual(texts(stack), ["b"])
        stack.clear()
        XCTAssertEqual(stack.count, 0)
        XCTAssertNil(stack.upcomingIndex)
    }

    func testSensitiveClipsAreRefusedWithReason() {
        let stack = stack(.fifo)
        XCTAssertEqual(stack.add(clip("SECRET")), .failure(.sensitive))
        XCTAssertEqual(stack.count, 0)
        XCTAssertFalse(PasteStackRefusal.sensitive.message.isEmpty)
    }

    func testClipWithoutIDAndFullStackAreRefused() {
        let stack = stack(.fifo)
        var unsaved = clip("x")
        unsaved.id = nil
        XCTAssertEqual(stack.add(unsaved), .failure(.unsupported))
        for index in 0..<PasteStack.capacity { XCTAssertEqual(stack.add(clip("n\(index)", id: Int64(index + 1))), .success(index + 1)) }
        XCTAssertEqual(stack.add(clip("over", id: 999)), .failure(.full))
    }
}
