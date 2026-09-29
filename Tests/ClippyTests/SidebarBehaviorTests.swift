import Foundation
import XCTest
@testable import Clippy

@MainActor
final class SidebarBehaviorTests: XCTestCase {
    func testWidthClampHonorsFractionContentMinimumAndHardMinimum() {
        XCTAssertEqual(SidebarMetrics.clamp(width: 999, panelWidth: 800, minContentWidth: 300), 360)
        XCTAssertEqual(SidebarMetrics.clamp(width: 999, panelWidth: 600, minContentWidth: 360), 240)
        XCTAssertEqual(SidebarMetrics.clamp(width: 100, panelWidth: 800, minContentWidth: 300), 150)
        XCTAssertEqual(SidebarMetrics.clamp(width: 80, panelWidth: 400, minContentWidth: 320), 150)
    }
    func testAutoCollapseUsesBreakpointAndExplicitCollapse() {
        XCTAssertTrue(SidebarMetrics.shouldAutoCollapse(panelWidth: 519))
        XCTAssertFalse(SidebarMetrics.shouldAutoCollapse(panelWidth: 520))
        XCTAssertTrue(SidebarMetrics.showsRail(isCollapsed: true, panelWidth: 900))
        XCTAssertFalse(SidebarMetrics.showsRail(isCollapsed: false, panelWidth: 900))
    }
    func testPreferencesPersistWidthAndCollapsedStateAcrossInstances() {
        let suiteName = "SidebarBehaviorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = SidebarPreferences(defaults: defaults)
        first.width = 214
        first.isCollapsed = true
        let second = SidebarPreferences(defaults: defaults)
        XCTAssertEqual(second.width, 214)
        XCTAssertTrue(second.isCollapsed)
        second.toggleCollapsed()
        XCTAssertFalse(SidebarPreferences(defaults: defaults).isCollapsed)
    }
    func testDeleteUndoRestoresMembershipAndOriginalOrder() {
        let backend = CategoryUndoFakeBackend(order: [11, 12, 13])
        let undo = CategoryUndo(backend: backend)
        let category = makeCategory(id: 12, name: "Middle", sortOrder: 1)
        backend.order = [11, 13]
        undo.recordDelete(category, orderBefore: [11, 12, 13], members: [501, 502])
        XCTAssertTrue(undo.undo())
        XCTAssertEqual(backend.order, [11, 100, 13])
        XCTAssertEqual(backend.memberships, ["501:100", "502:100"])
        XCTAssertFalse(undo.canUndo)
    }
    func testReorderUndoRestoresOriginalOrder() {
        let backend = CategoryUndoFakeBackend(order: [13, 11, 12])
        let undo = CategoryUndo(backend: backend)
        undo.recordReorder(orderBefore: [11, 12, 13])
        XCTAssertTrue(undo.undo())
        XCTAssertEqual(backend.order, [11, 12, 13])
    }
    func testDropClassificationSeparatesFilingFromReorderingAndHandlesMultiDrop() {
        XCTAssertEqual(SidebarDropTarget.indicator(isCategoryDrag: false, over: .category(4)), .fileRing)
        XCTAssertEqual(SidebarDropTarget.indicator(isCategoryDrag: true, over: .category(4)), .reorderLine)
        XCTAssertEqual(SidebarDropTarget.indicator(isCategoryDrag: false, over: .history), .unfileRing)
        XCTAssertEqual(SidebarDropTarget.action(for: ["clip:21", "reorder:clip:22", "clip:21"], on: .category(4)), .fileClips([21, 22], into: 4))
        XCTAssertEqual(SidebarDropTarget.action(for: ["reorder:cat:7"], on: .trailing), .reorderCategory(id: 7, before: Int64.max))
        XCTAssertEqual(SidebarDropTarget.action(for: ["clip:21"], on: .history), .unfileClips([21]))
    }
    func testHistoryCountMatchesUnfiledClips() {
        XCTAssertEqual(SidebarCounts.displayedHistoryCount(clipIDs: [1, 2, 3, nil], membership: [1: [9], 2: [], 3: [10, 11]]), 2)
    }
    private func makeCategory(id: Int64, name: String, sortOrder: Int) -> Clippy.Category {
        Clippy.Category(id: id, name: name, colorHex: "#112233", iconKind: .symbol, iconValue: "folder", sortOrder: sortOrder, isStarter: false, createdAt: .distantPast)
    }
}

private final class CategoryUndoFakeBackend: CategoryUndoBackend {
    var order: [Int64]
    var memberships: [String] = []
    private var nextID: Int64 = 100
    init(order: [Int64]) { self.order = order }
    func recreate(_ category: Clippy.Category) -> Clippy.Category? {
        var restored = category
        restored.id = nextID
        nextID += 1
        order.append(restored.id!)
        return restored
    }
    func setMember(clipID: Int64, categoryID: Int64, isMember: Bool) {
        let membership = "\(clipID):\(categoryID)"
        if isMember { memberships.append(membership) } else { memberships.removeAll { $0 == membership } }
    }
    func move(categoryID: Int64, before targetID: Int64) {
        order.removeAll { $0 == categoryID }
        guard targetID != SidebarDropTarget.endSentinel, let index = order.firstIndex(of: targetID) else { order.append(categoryID); return }
        order.insert(categoryID, at: index)
    }
}
