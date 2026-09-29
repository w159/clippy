import XCTest
@testable import Clippy

final class RankFusionTests: XCTestCase {
    func testAgreementBeatsSingleListLeader() {
        let fused = RankFusion.fuse([RankedList(ids: [1, 2, 3]), RankedList(ids: [3, 2, 9])])
        // damping 60: id3 = 1/63 + 1/61 = 0.032266; id2 = 1/62 + 1/62 = 0.032258;
        // id1 = 1/61 = 0.016393; id9 = 1/63 = 0.015873. Both agreeing ids beat the single-list ones.
        XCTAssertEqual(fused.map(\.id), [3, 2, 1, 9])
        XCTAssertEqual(fused.first { $0.id == 2 }?.listIndices, [0, 1])
    }

    func testTieBreaksByBestRankThenID() {
        // 1 and 5 each score 1/61; identical best rank => lower id first.
        let fused = RankFusion.fuse([RankedList(ids: [5]), RankedList(ids: [1])])
        XCTAssertEqual(fused.map(\.id), [1, 5])
        // Same score via ranks 1+2 vs 2+1: identical bestRank 1 => id order.
        let mirrored = RankFusion.fuse([RankedList(ids: [8, 4]), RankedList(ids: [4, 8])])
        XCTAssertEqual(mirrored.map(\.id), [4, 8])
    }

    func testMissingAndEmptyListsAreSkipped() {
        XCTAssertEqual(RankFusion.fuse([]), [])
        XCTAssertEqual(RankFusion.fuse([RankedList(ids: []), RankedList(ids: [7, 8])]).map(\.id), [7, 8])
    }

    func testWeightsScaleAndDisable() {
        let heavy = RankFusion.fuse([RankedList(ids: [1], weight: 1), RankedList(ids: [2], weight: 3)])
        XCTAssertEqual(heavy.map(\.id), [2, 1])
        let disabled = RankFusion.fuse([RankedList(ids: [1], weight: 0), RankedList(ids: [2], weight: -1), RankedList(ids: [3])])
        XCTAssertEqual(disabled.map(\.id), [3])
    }

    func testDuplicatesCountOnceAndLimitApplies() {
        let fused = RankFusion.fuse([RankedList(ids: [1, 1, 2, 3])], limit: 2)
        XCTAssertEqual(fused.map(\.id), [1, 2])
        XCTAssertEqual(fused[1].bestRank, 2)
    }
}
