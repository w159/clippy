import XCTest
@testable import Clippy

@MainActor
final class OCRBatchTests: XCTestCase {
    private let urls = (1...3).map { URL(fileURLWithPath: "/tmp/ocr-batch-\($0).png") }

    func testProcessesSequentiallyWithProgress() {
        var order: [String] = []
        var progress: [Int] = []
        let done = expectation(description: "batch")
        var items: [OCRBatch.Item] = []
        OCRBatch.run(
            urls: urls,
            recognizer: { url, completion in
                order.append(url.lastPathComponent)
                completion(.success("text \(url.lastPathComponent)"))
            },
            progress: { completed, total, _ in
                XCTAssertEqual(total, 3)
                progress.append(completed)
            },
            completion: { items = $0; done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(order, urls.map(\.lastPathComponent))
        XCTAssertEqual(progress, [1, 2, 3])
        XCTAssertEqual(items.count, 3)
    }

    func testFailureDoesNotStopBatch() {
        struct Boom: Error {}
        let done = expectation(description: "batch")
        var items: [OCRBatch.Item] = []
        OCRBatch.run(
            urls: urls,
            recognizer: { url, completion in
                completion(url == self.urls[1] ? .failure(Boom()) : .success("ok"))
            },
            completion: { items = $0; done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(items.count, 3)
        if case .failure = items[1].result {} else { XCTFail("middle item should fail") }
    }

    func testCancelStopsBeforeNextFile() {
        var handle: OCRBatch.Handle?
        var processed = 0
        let done = expectation(description: "batch")
        var items: [OCRBatch.Item] = []
        handle = OCRBatch.run(
            urls: urls,
            recognizer: { _, completion in
                processed += 1
                DispatchQueue.main.async { completion(.success("x")) }
            },
            completion: { items = $0; done.fulfill() })
        // The first file is already in flight; cancelling now stops the rest.
        handle?.cancel()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(processed, 1)
        XCTAssertEqual(items.count, 1)
    }

    func testEmptyInputCompletesImmediately() {
        var called = false
        OCRBatch.run(urls: [], recognizer: { _, _ in XCTFail() }, completion: { items in
            called = true
            XCTAssertTrue(items.isEmpty)
        })
        XCTAssertTrue(called)
    }
}
