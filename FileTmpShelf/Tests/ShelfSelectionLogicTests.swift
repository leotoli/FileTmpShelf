import XCTest
@testable import FileTmpShelf

/// V2-6：多选纯逻辑（ShelfSelection）与拖拽排序纯逻辑（ReorderLogic）。
final class ShelfSelectionLogicTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    // MARK: - ShelfSelection.toggle（⌘ 点击）

    func testToggleAddsNewID() {
        var selection = ShelfSelection()
        selection.toggle(a)
        XCTAssertEqual(selection.ids, [a])
        XCTAssertEqual(selection.anchor, a)
    }

    func testToggleRemovesExistingIDAndClearsAnchor() {
        var selection = ShelfSelection(ids: [a, b], anchor: a)
        selection.toggle(a)
        XCTAssertEqual(selection.ids, [b])
        XCTAssertNil(selection.anchor, "移除锚点自身后锚点应清空")
    }

    func testToggleKeepsOtherAnchor() {
        var selection = ShelfSelection(ids: [a, b], anchor: b)
        selection.toggle(a)
        XCTAssertEqual(selection.ids, [b])
        XCTAssertEqual(selection.anchor, b, "移除非锚点条目时锚点保留")
    }

    // MARK: - selectOnly（无修饰键点击）

    func testSelectOnlyReplacesWholeSelection() {
        var selection = ShelfSelection(ids: [a, b], anchor: b)
        selection.selectOnly(c)
        XCTAssertEqual(selection.ids, [c])
        XCTAssertEqual(selection.anchor, c)
    }

    // MARK: - shift（Shift 区间）

    func testShiftSelectsForwardRange() {
        var selection = ShelfSelection(ids: [a], anchor: a)
        selection.shift(c, order: [a, b, c, d])
        XCTAssertEqual(selection.ids, [a, b, c])
    }

    func testShiftSelectsBackwardRange() {
        var selection = ShelfSelection(ids: [c], anchor: c)
        selection.shift(a, order: [a, b, c, d])
        XCTAssertEqual(selection.ids, [a, b, c])
    }

    func testShiftSameAsAnchorKeepsAnchor() {
        var selection = ShelfSelection(ids: [a], anchor: a)
        selection.shift(a, order: [a, b, c, d])
        XCTAssertEqual(selection.ids, [a])
    }

    func testShiftWithoutAnchorFallsBackToSelectOnly() {
        var selection = ShelfSelection(ids: [a, b])
        selection.shift(c, order: [a, b, c, d])
        XCTAssertEqual(selection.ids, [c], "无锚点时 Shift 退化为单选")
    }

    func testShiftWithUnknownIDFallsBackToSelectOnly() {
        var selection = ShelfSelection(ids: [a], anchor: a)
        let unknown = UUID()
        selection.shift(unknown, order: [a, b, c, d])
        XCTAssertEqual(selection.ids, [unknown], "点击的 id 不在 order 中，退化为仅选中该条目")
        XCTAssertEqual(selection.anchor, unknown)
    }

    // MARK: - clear / remove

    func testClearEmptiesSelection() {
        var selection = ShelfSelection(ids: [a, b], anchor: a)
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    func testRemoveSubtractsAndClearsMatchingAnchor() {
        var selection = ShelfSelection(ids: [a, b, c], anchor: b)
        selection.remove([a, b])
        XCTAssertEqual(selection.ids, [c])
        XCTAssertNil(selection.anchor, "锚点被移除后应清空")
    }

    func testRemoveKeepsAnchorWhenNotRemoved() {
        var selection = ShelfSelection(ids: [a, b, c], anchor: a)
        selection.remove([b])
        XCTAssertEqual(selection.ids, [a, c])
        XCTAssertEqual(selection.anchor, a)
    }

    // MARK: - ReorderLogic.indexForX

    func testIndexForXMapsToSlot() {
        // 默认 itemWidth=150 spacing=10 leadingPadding=10 → 槽宽 160
        XCTAssertEqual(ReorderLogic.indexForX(0, count: 5), 0)
        XCTAssertEqual(ReorderLogic.indexForX(10, count: 5), 0)
        XCTAssertEqual(ReorderLogic.indexForX(90, count: 5), 1)   // (90-10)/160 = 0.5 → round = 1
        XCTAssertEqual(ReorderLogic.indexForX(170, count: 5), 1)
        XCTAssertEqual(ReorderLogic.indexForX(810, count: 5), 5)  // 末尾 → append
        XCTAssertEqual(ReorderLogic.indexForX(9999, count: 5), 5) // clamp
    }

    // MARK: - ReorderLogic.moving

    private func makeItems(_ names: [String]) -> [MockIdentifiable] {
        names.map { MockIdentifiable(id: $0) }
    }

    func testMovingMovesToTarget() {
        let items = makeItems(["a", "b", "c", "d", "e"])
        // 向下：a → 槽 3 → a 落在 d 之后、e 之前
        XCTAssertEqual(ReorderLogic.moving(items, id: "a", to: 3).map(\.id), ["b", "c", "d", "a", "e"])
        // 向上：e → 槽 1 → e 落在 a 之后、b 之前
        XCTAssertEqual(ReorderLogic.moving(items, id: "e", to: 1).map(\.id), ["a", "e", "b", "c", "d"])
        // 移到头部
        XCTAssertEqual(ReorderLogic.moving(items, id: "c", to: 0).map(\.id), ["c", "a", "b", "d", "e"])
        // 移到末尾
        XCTAssertEqual(ReorderLogic.moving(items, id: "a", to: 5).map(\.id), ["b", "c", "d", "e", "a"])
    }

    func testMovingUnknownOrSamePositionReturnsOriginal() {
        let items = makeItems(["a", "b", "c"])
        XCTAssertEqual(ReorderLogic.moving(items, id: "z", to: 1).map(\.id), ["a", "b", "c"])
        // 原地移动 → 返回原数组（无变化）
        XCTAssertEqual(ReorderLogic.moving(items, id: "b", to: 1).map(\.id), ["a", "b", "c"])
    }
}

private struct MockIdentifiable: Identifiable {
    let id: String
}
